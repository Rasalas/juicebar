import XCTest
@testable import JuicebarCore

@MainActor
final class AccountRefreshSchedulerTests: XCTestCase {
    func testSlowAccountDoesNotBlockAnotherAndConcurrencyIsBounded() async {
        let scheduler = AccountRefreshScheduler(maxConcurrent: 2)
        var continuations: [String: CheckedContinuation<Void, Never>] = [:]
        var started: Set<String> = []
        let firstStarted = expectation(description: "First two accounts started")
        firstStarted.expectedFulfillmentCount = 2
        let queuedStarted = expectation(description: "Queued account started")
        for id in ["slow", "fast", "queued"] {
            scheduler.enqueue(id: id) { _ in
                started.insert(id)
                if id == "queued" { queuedStarted.fulfill() } else { firstStarted.fulfill() }
                await withCheckedContinuation { continuations[id] = $0 }
            }
        }
        await fulfillment(of: [firstStarted], timeout: 10)
        XCTAssertEqual(started, ["slow", "fast"])
        continuations.removeValue(forKey: "fast")?.resume()
        await fulfillment(of: [queuedStarted], timeout: 10)
        XCTAssertTrue(started.contains("queued"))
        continuations.removeValue(forKey: "slow")?.resume()
        continuations.removeValue(forKey: "queued")?.resume()
        await scheduler.waitUntilIdle()
        XCTAssertTrue(scheduler.activeIDs.isEmpty)
    }

    func testRemovedOrEditedAccountRejectsLateFailureAndRunsReplacement() async {
        let scheduler = AccountRefreshScheduler(maxConcurrent: 1)
        var continuation: CheckedContinuation<Void, Never>?
        let oldStarted = expectation(description: "Old request started")
        var acceptedOldFailure = false
        var replacementRan = false
        scheduler.enqueue(id: "account") { generation in
            await withCheckedContinuation { continuation = $0; oldStarted.fulfill() }
            acceptedOldFailure = scheduler.isCurrent(id: "account", generation: generation)
        }
        await fulfillment(of: [oldStarted], timeout: 10)
        scheduler.invalidate(id: "account")
        XCTAssertFalse(scheduler.activeIDs.contains("account"))
        scheduler.enqueue(id: "account") { generation in
            replacementRan = scheduler.isCurrent(id: "account", generation: generation)
        }
        continuation?.resume()
        await scheduler.waitUntilIdle()
        XCTAssertFalse(acceptedOldFailure)
        XCTAssertTrue(replacementRan)
    }

    func testManualRequestReplacesQueuedAutomaticRequestWithoutDuplication() async {
        let scheduler = AccountRefreshScheduler(maxConcurrent: 1)
        var continuation: CheckedContinuation<Void, Never>?
        var operations: [String] = []
        let slowStarted = expectation(description: "Slow request started")
        scheduler.enqueue(id: "slow") { _ in await withCheckedContinuation { continuation = $0; slowStarted.fulfill() } }
        scheduler.enqueue(id: "queued") { _ in operations.append("automatic") }
        scheduler.enqueue(id: "queued", replacingPending: true) { _ in operations.append("manual") }
        scheduler.enqueue(id: "queued") { _ in operations.append("later timer") }
        await fulfillment(of: [slowStarted], timeout: 10)
        continuation?.resume()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(operations, ["manual"])
    }

    func testCancellationDropsQueuedJobs() async {
        let scheduler = AccountRefreshScheduler(maxConcurrent: 1)
        var continuation: CheckedContinuation<Void, Never>?
        var queuedRan = false
        let runningStarted = expectation(description: "Running request started")
        scheduler.enqueue(id: "running") { _ in await withCheckedContinuation { continuation = $0; runningStarted.fulfill() } }
        scheduler.enqueue(id: "queued") { _ in queuedRan = true }
        await fulfillment(of: [runningStarted], timeout: 10)
        scheduler.cancelAll()
        continuation?.resume()
        await scheduler.waitUntilIdle()
        XCTAssertFalse(queuedRan)
        XCTAssertTrue(scheduler.activeIDs.isEmpty)
    }
}

final class AccountRefreshPolicyTests: XCTestCase {
    func testManualRefreshRespectsRateLimitAndRemovalClearsAllCadence() {
        var policy = AccountRefreshPolicy()
        let now = Date(timeIntervalSince1970: 1000)
        let account = AccountConfiguration(id: "a", provider: .codex)
        policy.succeeded(account: account, refreshSeconds: 60, includedHistory: true, now: now)
        XCTAssertFalse(policy.isDue(id: "a", force: false, now: now))
        XCTAssertTrue(policy.isDue(id: "a", force: true, now: now))
        XCTAssertFalse(policy.includesHistory(id: "a", now: now))
        policy.failed(id: "a", error: ProviderFailure.rateLimited(120), refreshSeconds: 60, now: now)
        XCTAssertFalse(policy.isDue(id: "a", force: true, now: now.addingTimeInterval(119)))
        XCTAssertTrue(policy.isDue(id: "b", force: false, now: now))
        XCTAssertTrue(policy.isDue(id: "a", force: true, now: now.addingTimeInterval(120)))
        policy.remove(id: "a")
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: now))
        XCTAssertTrue(policy.includesHistory(id: "a", now: now))
    }
    func testProviderMinimumBackoffAndSetupManualRecovery() {
        var policy = AccountRefreshPolicy()
        let now = Date(timeIntervalSince1970: 1000)
        let account = AccountConfiguration(id: "a", provider: .openaiAPI)
        policy.succeeded(account: account, refreshSeconds: 30, includedHistory: false, now: now)
        XCTAssertFalse(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(299)))
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(300)))
        policy.failed(id: "a", error: ProviderFailure.authentication, refreshSeconds: 60, now: now)
        policy.failed(id: "a", error: ProviderFailure.authentication, refreshSeconds: 60, now: now)
        XCTAssertFalse(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(119)))
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(120)))
        policy.failed(id: "a", error: ProviderFailure.needsSetup("fixture"), refreshSeconds: 60, now: now)
        XCTAssertFalse(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(86400)))
        XCTAssertTrue(policy.isDue(id: "a", force: true, now: now))
    }
    func testUnchangedQuotaBacksOffAndChangeResetsInterval() {
        var policy = AccountRefreshPolicy()
        let account = AccountConfiguration(id: "a", provider: .claude)
        var now = Date(timeIntervalSince1970: 1000)
        var delays: [TimeInterval] = []
        for unchanged in [false, true, true, true, true, true, false] {
            policy.succeeded(account: account, refreshSeconds: 300, includedHistory: false, unchanged: unchanged, now: now)
            let delay = stride(from: 0.0, through: 3600, by: 30).first { policy.isDue(id: "a", force: false, now: now.addingTimeInterval($0)) }!
            delays.append(delay); now = now.addingTimeInterval(delay)
        }
        XCTAssertEqual(delays, [300, 450, 600, 750, 900, 900, 300])
        policy.succeeded(account: account, refreshSeconds: 60, includedHistory: false, unchanged: true, now: now)
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(90)))
    }
    func testLowPowerModeStretchesIntervalUpToMaximum() {
        var policy = AccountRefreshPolicy()
        policy.lowPowerMode = true
        let account = AccountConfiguration(id: "a", provider: .codex)
        let now = Date(timeIntervalSince1970: 1000)
        policy.succeeded(account: account, refreshSeconds: 300, includedHistory: false, now: now)
        XCTAssertFalse(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(599)))
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(600)))
        policy.succeeded(account: account, refreshSeconds: 300, includedHistory: false, unchanged: true, now: now)
        XCTAssertFalse(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(899)))
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: now.addingTimeInterval(900)))
    }
    func testClockMovedBackwardsDoesNotPostponeBeyondOneInterval() {
        var policy = AccountRefreshPolicy()
        let account = AccountConfiguration(id: "a", provider: .codex)
        let now = Date(timeIntervalSince1970: 100_000)
        policy.succeeded(account: account, refreshSeconds: 300, includedHistory: true, now: now)
        policy.failed(id: "b", error: ProviderFailure.rateLimited(120), refreshSeconds: 300, now: now)
        policy.failed(id: "c", error: ProviderFailure.needsSetup("fixture"), refreshSeconds: 300, now: now)
        let earlier = now.addingTimeInterval(-7200)
        policy.clamp(now: earlier)
        XCTAssertFalse(policy.isDue(id: "a", force: false, now: earlier.addingTimeInterval(299)))
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: earlier.addingTimeInterval(300)))
        XCTAssertFalse(policy.isDue(id: "b", force: true, now: earlier.addingTimeInterval(119)))
        XCTAssertTrue(policy.isDue(id: "b", force: true, now: earlier.addingTimeInterval(120)))
        XCTAssertFalse(policy.isDue(id: "c", force: false, now: earlier.addingTimeInterval(86400)))
        XCTAssertFalse(policy.includesHistory(id: "a", now: earlier.addingTimeInterval(1800)))
        XCTAssertTrue(policy.includesHistory(id: "a", now: earlier.addingTimeInterval(1801)))
        policy.clamp(now: now)
        XCTAssertTrue(policy.isDue(id: "a", force: false, now: now))
    }
    func testQuotaComparisonIgnoresResetDrift() {
        let reset = Date(timeIntervalSince1970: 50_000)
        let old = AccountSnapshot(configurationID: "a", identity: "fixture", source: "test",
                                  windows: [QuotaWindow(id: "five_hour", title: "5h", usedPercent: 20, resetsAt: reset)])
        var drifted = old; drifted.windows[0].resetsAt = reset.addingTimeInterval(1); drifted.observedAt = old.observedAt.addingTimeInterval(300)
        XCTAssertTrue(AccountRefreshPolicy.quotaUnchanged(from: old, to: drifted))
        var used = drifted; used.windows[0].usedPercent = 21
        XCTAssertFalse(AccountRefreshPolicy.quotaUnchanged(from: old, to: used))
        var other = drifted; other.identity = "other"
        XCTAssertFalse(AccountRefreshPolicy.quotaUnchanged(from: old, to: other))
        XCTAssertFalse(AccountRefreshPolicy.quotaUnchanged(from: nil, to: old))
    }
    func testLegacyDefaultIntervalMigratesAndExplicitChoiceStays() throws {
        var legacy = MonitorSettings(); legacy.refreshSeconds = 90
        var decoded = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(legacy))
        decoded.migrateLegacyRefreshDefault()
        XCTAssertEqual(decoded.refreshSeconds, 300)
        var chosen = MonitorSettings(); chosen.refreshSeconds = 60
        chosen.migrateLegacyRefreshDefault()
        XCTAssertEqual(chosen.refreshSeconds, 60)
    }
}
