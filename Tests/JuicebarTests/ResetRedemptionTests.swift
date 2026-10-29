import XCTest
import JuicebarCore
@testable import Juicebar

actor ResetFake: CodexResetRedeeming {
    private var failFirst: Bool
    private let hold: Bool
    private let includesFreshLimits: Bool
    private var release: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var keys: [String] = []
    init(failFirst: Bool = false, hold: Bool = false, includesFreshLimits: Bool = true) {
        self.failFirst = failFirst; self.hold = hold; self.includesFreshLimits = includesFreshLimits
    }
    func redeem(configuration: AccountConfiguration, expectedSnapshot: AccountSnapshot,
                creditID: String, idempotencyKey: String) async throws -> CodexResetResult {
        keys.append(idempotencyKey)
        if failFirst { failFirst = false; throw ProviderFailure.timedOut }
        if hold {
            await withCheckedContinuation { continuation in
                release = continuation
                waiters.forEach { $0.resume() }; waiters = []
            }
        }
        var snapshot = expectedSnapshot
        snapshot.observedAt = Date(); snapshot.benefitCount = 0; snapshot.benefits = []
        snapshot.windows[0].usedPercent = 0
        return CodexResetResult(outcome: .reset, snapshot: includesFreshLimits ? snapshot : nil)
    }
    func waitUntilCalled() async {
        if release != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() { release?.resume(); release = nil }
}

@MainActor
final class ResetRedemptionTests: XCTestCase {
    private func fixture(_ fake: ResetFake, corruptKeys: Bool = false) throws -> (AppStore, AccountConfiguration, ResetBenefit, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-reset-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let account = AccountConfiguration(id: UUID().uuidString, provider: .codex, executablePath: "/fixture/no-live-cli")
        let benefit = ResetBenefit(id: "fixture-credit", title: "Fixture", scope: "Codex", expiresAt: Date().addingTimeInterval(3600))
        let snapshot = AccountSnapshot(configurationID: account.id, identity: "known-fixture-login", source: "fixture",
                                       windows: [QuotaWindow(id: "codex.primary", title: "5h", usedPercent: 90, resetsAt: Date().addingTimeInterval(3600), duration: 18000)],
                                       benefits: [benefit], benefitCount: 1, benefitsChecked: true)
        let database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        try database.write([account], key: "accounts"); try database.save(snapshot)
        if corruptKeys { try database.write("incompatible", key: "reset-redemptions") }
        return (AppStore(directory: directory, resetRedeemer: fake), account, benefit, directory)
    }
    func testUnconfirmedAttemptReusesPersistedKeyAfterRestartAndStoresFreshLimits() async throws {
        let fake = ResetFake(failFirst: true)
        let (store, account, benefit, directory) = try fixture(fake)
        let identity = try XCTUnwrap(store.snapshots[account.id]?.identity)
        do { _ = try await store.redeemReset(benefit, for: account, expectedIdentity: identity); XCTFail("First response is deliberately lost") }
        catch {}
        XCTAssertFalse(store.redeemingResetAccounts.contains(account.id))
        let database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        XCTAssertEqual(try database.read([String: String].self, key: "reset-redemptions")?.count, 1)
        let restarted = AppStore(directory: directory, resetRedeemer: fake)
        let result = try await restarted.redeemReset(benefit, for: account, expectedIdentity: identity)
        XCTAssertEqual(result.outcome, .reset)
        let keys = await fake.keys
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys[0], keys[1])
        XCTAssertEqual(try database.read([String: String].self, key: "reset-redemptions"), [:])
        XCTAssertEqual(restarted.snapshots[account.id]?.benefitCount, 0)
        XCTAssertEqual(restarted.snapshots[account.id]?.windows.first?.usedPercent, 0)
        XCTAssertEqual(try database.history(account: account.id).last?.benefitCount, 0)
    }
    func testManualExpiredStaleAndChangedLoginsNeverReachTheService() async throws {
        let fake = ResetFake()
        let (store, account, benefit, _) = try fixture(fake)
        let original = try XCTUnwrap(store.snapshots[account.id])
        var stale = original; stale.observedAt = .distantPast
        var unknown = original; unknown.identity = AccountIdentity.fallback(for: account)
        var expired = original; expired.benefits[0].expiresAt = .distantPast
        var manual = benefit; manual.isManual = true
        for (snapshot, selected, expected) in [(stale, benefit, original.identity), (unknown, benefit, unknown.identity),
                                             (expired, benefit, original.identity), (original, manual, original.identity),
                                             (original, benefit, "other-login")] {
            store.snapshots[account.id] = snapshot
            do { _ = try await store.redeemReset(selected, for: account, expectedIdentity: expected); XCTFail("Unsafe request must be rejected") }
            catch {}
        }
        let calls = await fake.keys
        XCTAssertTrue(calls.isEmpty)
    }
    func testBusyAccountRejectsAnotherCreditAndRemovedAccountDoesNotReappear() async throws {
        let fake = ResetFake(hold: true)
        let (store, account, benefit, _) = try fixture(fake)
        let identity = try XCTUnwrap(store.snapshots[account.id]?.identity)
        let first = Task { try await store.redeemReset(benefit, for: account, expectedIdentity: identity) }
        await fake.waitUntilCalled()
        XCTAssertTrue(store.redeemingResetAccounts.contains(account.id))
        do { _ = try await store.redeemReset(benefit, for: account, expectedIdentity: identity); XCTFail("Concurrent redemption must be blocked") }
        catch {}
        store.accounts = []; store.snapshots = [:]
        await fake.finish()
        _ = try await first.value
        XCTAssertNil(store.snapshots[account.id])
        XCTAssertFalse(store.redeemingResetAccounts.contains(account.id))
        let calls = await fake.keys
        XCTAssertEqual(calls.count, 1)
    }
    func testUnreadableAttemptStorageCannotLoseAnIdempotencyKeyOrMutateTheAccount() async throws {
        let fake = ResetFake()
        let (store, account, benefit, _) = try fixture(fake, corruptKeys: true)
        let identity = try XCTUnwrap(store.snapshots[account.id]?.identity)
        do { _ = try await store.redeemReset(benefit, for: account, expectedIdentity: identity); XCTFail("Persisting the key must succeed before sending") }
        catch {}
        let calls = await fake.keys
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.snapshots[account.id]?.benefitCount, 1)
    }
    func testConfirmedResetWithoutFreshLimitsWaitsForRefreshRatherThanOfferingAnotherRedemption() async throws {
        let fake = ResetFake(includesFreshLimits: false)
        let (store, account, benefit, _) = try fixture(fake)
        let identity = try XCTUnwrap(store.snapshots[account.id]?.identity)
        let result = try await store.redeemReset(benefit, for: account, expectedIdentity: identity)
        XCTAssertEqual(result.outcome, .reset)
        XCTAssertNil(result.snapshot)
        XCTAssertTrue(store.resetAccountsAwaitingRefresh.contains(account.id))
        XCTAssertFalse(store.canRedeemReset(benefit, for: account))
        do { _ = try await store.redeemReset(benefit, for: account, expectedIdentity: identity); XCTFail("Fresh limits are required first") }
        catch {}
        let calls = await fake.keys
        XCTAssertEqual(calls.count, 1)
    }
    func testDemoRedemptionWorksWithoutAnExecutable() async throws {
        let store = AppStore(demo: true)
        let index = try XCTUnwrap(store.accounts.firstIndex { $0.provider == .codex })
        store.accounts[index].executablePath = "/fixture/no-live-cli"
        let account = store.accounts[index]
        let snapshot = try XCTUnwrap(store.snapshots[account.id])
        let benefit = try XCTUnwrap(snapshot.benefits.first)
        let result = try await store.redeemReset(benefit, for: account, expectedIdentity: snapshot.identity)
        XCTAssertEqual(result.outcome, .reset)
        XCTAssertEqual(store.snapshots[account.id]?.benefitCount, 0)
    }
}
