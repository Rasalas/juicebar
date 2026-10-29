import XCTest
import CSQLite
import JuicebarCore
@testable import Juicebar

private final class CredentialFake: CredentialStore {
    var values: [String: String] = [:]
    var reads = 0, mutations = 0
    var failRead = false, failSave = false, failRemove = false
    var onMutation: (() -> Void)?
    func read(account: String) throws -> String? {
        reads += 1
        if failRead { throw ProviderFailure.unavailable("Fixture read failure") }
        return values[account]
    }
    func contains(account: String) -> Bool { values[account] != nil }
    func save(_ secret: String, account: String) throws {
        if failSave { throw ProviderFailure.unavailable("Fixture save failure") }
        values[account] = secret; mutations += 1
        let hook = onMutation; onMutation = nil; hook?()
    }
    func remove(account: String) throws {
        if failRemove { throw ProviderFailure.unavailable("Fixture removal failure") }
        values[account] = nil; mutations += 1
        let hook = onMutation; onMutation = nil; hook?()
    }
}

private struct UsageFake: UsageProvider {
    let snapshot: AccountSnapshot
    func read(configuration: AccountConfiguration, includeHistory: Bool) async throws -> AccountSnapshot {
        var value = snapshot; value.observedAt = Date(); return value
    }
}

@MainActor
final class AtomicAccountPersistenceTests: XCTestCase {
    private func fixture(provider: ProviderKind = .opencodeGo, enabled: Bool = false, paused: Bool = true,
                         registry: ProviderRegistry = ProviderRegistry(), resetRedeemer: (any CodexResetRedeeming)? = nil) async throws -> (AppStore, HistoryDatabase, AccountConfiguration, URL, CredentialFake) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-atomic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        let account = AccountConfiguration(id: "fixture", provider: provider, enabled: enabled)
        try database.write([account], key: "accounts")
        try database.save(AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture"))
        let credentials = CredentialFake()
        credentials.values[account.id] = "fixture-old-key"
        let store = AppStore(directory: directory, resetRedeemer: resetRedeemer, credentials: credentials, registry: registry)
        await store.waitUntilReady()
        if paused { store.isPaused = true }
        return (store, database, account, directory, credentials)
    }

    private func execute(_ sql: String, directory: URL) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
    }

    func testFailedSaveKeepsVisibleAccountAndHistory() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        let snapshot = store.snapshots[account.id], history = store.history[account.id]
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        var edited = account; edited.label = "Edited"; edited.profileDirectory = "/fixture/other-profile"
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: "fixture-new-key"))
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.snapshots[account.id], snapshot)
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(try database.history(account: account.id), history)
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testFailedNewAccountSaveDoesNotAppendOrCreateCredential() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        let new = AccountConfiguration(id: "new-fixture", provider: .opencodeGo, enabled: false)
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(new, secret: "fixture-new-key"))
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertNil(credentials.values[new.id])
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testFailedRemovalKeepsVisibleAccountAndHistory() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        let snapshot = store.snapshots[account.id], history = store.history[account.id]
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        await store.removeAccount(account)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.snapshots[account.id], snapshot)
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(try database.history(account: account.id), history)
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testFailedSecondPreferenceWriteRollsBackAccountRemovalAndResets() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        await store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date().addingTimeInterval(100))
        let resetIDs = store.manualResets.map(\.id)
        store.failures[account.id] = "Previous failure"
        store.resetAccountsAwaitingRefresh.insert(account.id)
        try execute("CREATE TRIGGER fail_resets BEFORE INSERT ON preferences WHEN NEW.id='manual-resets' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        await store.removeAccount(account)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(store.manualResets.map(\.id), resetIDs)
        XCTAssertEqual(try database.read([ManualReset].self, key: "manual-resets")?.map(\.id), resetIDs)
        XCTAssertEqual(store.failures[account.id], "Previous failure")
        XCTAssertTrue(store.resetAccountsAwaitingRefresh.contains(account.id))
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testCredentialReadAndWriteFailuresLeaveSQLAndVisibleStateUnchanged() async throws {
        let (store, database, account, _, credentials) = try await fixture()
        var edited = account; edited.label = "Edited"
        let history = store.history[account.id]
        credentials.failRead = true
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: "fixture-new-key"))
        credentials.failRead = false; credentials.failSave = true
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: "fixture-new-key"))
        credentials.failSave = false; credentials.failRemove = true
        await store.removeAccount(account)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.history(account: account.id), history)
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
    }

    /// Deferred constraints fail at COMMIT, after the credential mutation has succeeded.
    private func failCommit(directory: URL, credentials: CredentialFake, failCompensation: Bool = false) throws -> () -> Void {
        try execute("CREATE TABLE fixture_parent(id INTEGER PRIMARY KEY); CREATE TABLE fixture_child(parent INTEGER REFERENCES fixture_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER INSERT ON preferences WHEN NEW.id='accounts' BEGIN INSERT INTO fixture_child VALUES(1); END", directory: directory)
        if failCompensation { credentials.onMutation = { credentials.failSave = true } }
        return { try? self.execute("DROP TRIGGER IF EXISTS fail_commit; DROP TABLE IF EXISTS fixture_child; DROP TABLE IF EXISTS fixture_parent", directory: directory) }
    }

    func testFailedCommitRestoresReplacedAndNewCredentials() async throws {
        for hadKey in [true, false] {
            let (store, database, account, directory, credentials) = try await fixture()
            if !hadKey { credentials.values[account.id] = nil }
            let removeCommitFailure = try failCommit(directory: directory, credentials: credentials)
            defer { removeCommitFailure() }
            var edited = account; edited.label = "Edited"; edited.profileDirectory = "/fixture/new-profile"
            let history = store.history[account.id]
            await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: "fixture-new-key"))
            XCTAssertEqual(store.accounts, [account])
            XCTAssertEqual(store.history[account.id], history)
            XCTAssertEqual(try database.history(account: account.id), history)
            XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
            XCTAssertEqual(credentials.values[account.id], hadKey ? "fixture-old-key" : nil)
            XCTAssertEqual(credentials.mutations, 2)
        }
    }

    func testFailedCommitRestoresRemovedKeyAndRetainsAccount() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials)
        defer { removeCommitFailure() }
        await store.removeAccount(account)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(credentials.mutations, 2)
    }

    func testFailedCompensationRetainsBackupAndRetriesBeforeAnotherAccountAction() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials, failCompensation: true)
        var edited = account; edited.label = "Edited"
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: "fixture-new-key"))
        removeCommitFailure()
        XCTAssertNotNil(store.failures[account.id])
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(credentials.values[account.id], "fixture-new-key")
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: ""))
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        credentials.failSave = false
        try await store.saveAccount(edited, secret: "")
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertNil(store.failures[account.id])
        XCTAssertNil(store.storageError)
    }

    func testPresenceAndOrdinaryEditsDoNotReadSecretsAndKeyRemovalRetainsHistory() async throws {
        let (store, database, account, _, credentials) = try await fixture()
        let history = store.history[account.id], snapshot = store.snapshots[account.id]
        await store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date().addingTimeInterval(100))
        let resets = store.manualResets.map(\.id)
        let savedKey = await store.hasSavedKey(for: account)
        XCTAssertTrue(savedKey)
        var edited = account; edited.label = "Edited"
        try await store.saveAccount(edited, secret: "")
        XCTAssertEqual(credentials.reads, 0)
        store.failures[account.id] = "Old credential failure"
        store.resetAccountsAwaitingRefresh.insert(account.id)
        try await store.removeSavedKey(for: edited)
        XCTAssertNil(credentials.values[account.id])
        let savedKeyAfter = await store.hasSavedKey(for: edited)
        XCTAssertFalse(savedKeyAfter)
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [edited])
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(store.snapshots[account.id], snapshot)
        XCTAssertEqual(try database.history(account: account.id), history)
        XCTAssertEqual(store.manualResets.map(\.id), resets)
        XCTAssertTrue(edited.useLocalCredentials)
        XCTAssertNil(store.failures[account.id])
        XCTAssertTrue(store.resetAccountsAwaitingRefresh.contains(account.id), "Editing credentials cannot replace a required fresh observation")
    }

    func testFailedSavedKeyRemovalPreservesKeyAndRefreshState() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        let history = store.history[account.id]
        store.failures[account.id] = "Previous failure"
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        await XCTAssertThrowsErrorAsync(try await store.removeSavedKey(for: account))
        XCTAssertEqual(credentials.mutations, 0)
        XCTAssertEqual(store.failures[account.id], "Previous failure")
        try execute("DROP TRIGGER fail_accounts", directory: directory)
        credentials.failRemove = true
        await XCTAssertThrowsErrorAsync(try await store.removeSavedKey(for: account))
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.history(account: account.id), history)
    }

    func testKeyRemovalRefreshPreservesHistoryFromPreviousLoginAcrossRestart() async throws {
        let next = AccountSnapshot(configurationID: "fixture", identity: "fixture-local-key", source: "fixture")
        let registry = ProviderRegistry(overrides: [.opencodeGo: UsageFake(snapshot: next)])
        let (store, database, account, directory, credentials) = try await fixture(enabled: true, paused: false, registry: registry)
        let original = try XCTUnwrap(store.snapshots[account.id])
        try await store.removeSavedKey(for: account)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.snapshots[account.id]?.identity != next.identity && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await store.shutDown()
        XCTAssertEqual(store.snapshots[account.id]?.identity, next.identity)
        XCTAssertNil(credentials.values[account.id])
        XCTAssertEqual(store.history[account.id]?.map(\.identity), [original.identity, next.identity])
        XCTAssertEqual(try database.history(account: account.id).map(\.identity), [original.identity, next.identity])
        let restarted = AppStore(directory: directory, credentials: credentials, registry: registry)
        await restarted.waitUntilReady()
        XCTAssertEqual(restarted.quotaHistory(for: account.id).map(\.identity), [original.identity, next.identity])
        let window = QuotaWindow(id: "weekly", title: "Week", usedPercent: 10, duration: 604800)
        XCTAssertNotEqual(QuotaPeriod.key(window: window, snapshot: original), QuotaPeriod.key(window: window, snapshot: next),
                          "The chart must not join measurements from different logins")
    }

    func testSavingKeyRemovalCommitsOtherEditsTogetherAndKeepsHistory() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        let history = store.history[account.id]
        var edited = account; edited.label = "Edited"; edited.useLocalCredentials = false
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials)
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: "", removeSavedKey: true))
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        removeCommitFailure()
        try await store.saveAccount(edited, secret: "", removeSavedKey: true)
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [edited])
        XCTAssertNil(credentials.values[account.id])
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.history(account: account.id), history)
    }

    func testInFlightResetCannotClearCredentialRecoveryFailure() async throws {
        let fake = ResetFake(hold: true)
        let (store, _, account, directory, credentials) = try await fixture(provider: .codex, enabled: true, resetRedeemer: fake)
        let benefit = ResetBenefit(id: "fixture-credit", title: "Fixture", scope: "Codex")
        let snapshot = AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture",
                                       windows: [.init(id: "primary", title: "5h", usedPercent: 90, duration: 18000)], benefits: [benefit])
        store.snapshots[account.id] = snapshot
        let pending = Task { try await store.redeemReset(benefit, for: account, expectedIdentity: snapshot.identity) }
        await fake.waitUntilCalled()
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials, failCompensation: true)
        defer { removeCommitFailure() }
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(account, secret: "fixture-new-key"))
        let failure = try XCTUnwrap(store.failures[account.id])
        await fake.finish()
        _ = try await pending.value
        XCTAssertEqual(store.failures[account.id], failure)
        XCTAssertEqual(store.snapshots[account.id], snapshot)
        // Eligibility must also inspect recovery state if another callback clears display errors.
        store.failures[account.id] = nil; store.snapshots[account.id] = snapshot
        store.resetAccountsAwaitingRefresh.remove(account.id)
        XCTAssertFalse(store.canRedeemReset(benefit, for: account))
        store.resetAccountsAwaitingRefresh.insert(account.id)
        removeCommitFailure(); credentials.failSave = false
        try await store.saveAccount(account, secret: "")
        XCTAssertNil(store.failures[account.id])
        XCTAssertTrue(store.resetAccountsAwaitingRefresh.contains(account.id))
        XCTAssertFalse(store.canRedeemReset(benefit, for: account), "Restoring credentials must not reoffer a confirmed credit before refresh")
    }

    func testSavedKeyRemovalCommitFailureRestoresKeyAndPreservesHistory() async throws {
        let (store, database, account, directory, credentials) = try await fixture()
        let history = store.history[account.id]
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials)
        defer { removeCommitFailure() }
        await XCTAssertThrowsErrorAsync(try await store.removeSavedKey(for: account))
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.history(account: account.id), history)
    }

    func testSuccessfulSaveAndRemovalCommitRelatedState() async throws {
        let (store, database, account, _, credentials) = try await fixture()
        await store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date())
        var edited = account; edited.profileDirectory = "/fixture/new-profile"
        try await store.saveAccount(edited, secret: "fixture-new-key")
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [edited])
        XCTAssertTrue(try database.history(account: account.id).isEmpty)
        XCTAssertNil(store.snapshots[account.id])
        XCTAssertEqual(credentials.values[account.id], "fixture-new-key")
        await store.removeAccount(edited)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.manualResets.isEmpty)
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [])
        XCTAssertEqual(try database.read([ManualReset].self, key: "manual-resets")?.count, 0)
        XCTAssertNil(credentials.values[account.id])
    }

    func testUnreadableRelatedPreferencesRemainProtected() async throws {
        let (_, database, account, directory, credentials) = try await fixture()
        try database.write("incompatible", key: "manual-resets")
        try database.write("incompatible", key: "ssh-hosts")
        let store = AppStore(directory: directory, credentials: credentials)
        await store.waitUntilReady()
        store.isPaused = true
        await store.removeAccount(account)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(credentials.reads, 0)
        await store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date())
        XCTAssertTrue(store.manualResets.isEmpty)
        await XCTAssertThrowsErrorAsync(try await store.addSSHHost("fixture-host"))
        XCTAssertTrue(store.sshHosts.isEmpty)
        XCTAssertEqual(try database.read(String.self, key: "manual-resets"), "incompatible")
        XCTAssertEqual(try database.read(String.self, key: "ssh-hosts"), "incompatible")
    }

    func testManualResetsSSHHostsAndSettingsRollBackOnWriteFailure() async throws {
        let (store, database, account, directory, _) = try await fixture()
        await store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date().addingTimeInterval(100))
        store.editSettings { $0.soundEnabled.toggle() }; await store.persistSettings()
        let resetIDs = store.manualResets.map(\.id), settings = store.settings
        try database.write(["fixture-host"], key: "ssh-hosts"); store.sshHosts = ["fixture-host"]
        try execute("CREATE TRIGGER fail_settings BEFORE INSERT ON preferences WHEN NEW.id IN ('manual-resets','ssh-hosts','settings') BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        await store.addReset(accountID: account.id, title: "Another", scope: "Fixture", expiry: Date())
        await store.removeReset(try XCTUnwrap(resetIDs.first))
        XCTAssertEqual(store.manualResets.map(\.id), resetIDs)
        XCTAssertEqual(try database.read([ManualReset].self, key: "manual-resets")?.map(\.id), resetIDs)
        await XCTAssertThrowsErrorAsync(try await store.addSSHHost("another-fixture"))
        await store.removeSSHHost("fixture-host")
        XCTAssertEqual(store.sshHosts, ["fixture-host"])
        XCTAssertEqual(try database.read([String].self, key: "ssh-hosts"), ["fixture-host"])
        store.editSettings { $0.soundEnabled.toggle() }; await store.persistSettings()
        XCTAssertEqual(store.settings, settings)
        XCTAssertEqual(try database.read(MonitorSettings.self, key: "settings"), settings)
        XCTAssertNotNil(store.storageError)
    }
}
