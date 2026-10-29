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

@MainActor
final class AtomicAccountPersistenceTests: XCTestCase {
    private func fixture() throws -> (AppStore, HistoryDatabase, AccountConfiguration, URL, CredentialFake) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-atomic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        let account = AccountConfiguration(id: "fixture", provider: .opencodeGo, enabled: false)
        try database.write([account], key: "accounts")
        try database.save(AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture"))
        let credentials = CredentialFake()
        credentials.values[account.id] = "fixture-old-key"
        let store = AppStore(directory: directory, credentials: credentials)
        store.isPaused = true
        return (store, database, account, directory, credentials)
    }

    private func execute(_ sql: String, directory: URL) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
    }

    func testFailedSaveKeepsVisibleAccountAndHistory() throws {
        let (store, database, account, directory, credentials) = try fixture()
        let snapshot = store.snapshots[account.id], history = store.history[account.id]
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        var edited = account; edited.label = "Edited"; edited.profileDirectory = "/fixture/other-profile"
        XCTAssertThrowsError(try store.saveAccount(edited, secret: "fixture-new-key"))
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.snapshots[account.id], snapshot)
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(try database.history(account: account.id), history)
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testFailedNewAccountSaveDoesNotAppendOrCreateCredential() throws {
        let (store, database, account, directory, credentials) = try fixture()
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        let new = AccountConfiguration(id: "new-fixture", provider: .opencodeGo, enabled: false)
        XCTAssertThrowsError(try store.saveAccount(new, secret: "fixture-new-key"))
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertNil(credentials.values[new.id])
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testFailedRemovalKeepsVisibleAccountAndHistory() throws {
        let (store, database, account, directory, credentials) = try fixture()
        let snapshot = store.snapshots[account.id], history = store.history[account.id]
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        store.removeAccount(account)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.snapshots[account.id], snapshot)
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(try database.history(account: account.id), history)
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testFailedSecondPreferenceWriteRollsBackAccountRemovalAndResets() throws {
        let (store, database, account, directory, credentials) = try fixture()
        store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date().addingTimeInterval(100))
        let resetIDs = store.manualResets.map(\.id)
        store.failures[account.id] = "Previous failure"
        store.resetAccountsAwaitingRefresh.insert(account.id)
        try execute("CREATE TRIGGER fail_resets BEFORE INSERT ON preferences WHEN NEW.id='manual-resets' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        store.removeAccount(account)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(store.manualResets.map(\.id), resetIDs)
        XCTAssertEqual(try database.read([ManualReset].self, key: "manual-resets")?.map(\.id), resetIDs)
        XCTAssertEqual(store.failures[account.id], "Previous failure")
        XCTAssertTrue(store.resetAccountsAwaitingRefresh.contains(account.id))
        XCTAssertEqual(credentials.mutations, 0)
    }

    func testCredentialReadAndWriteFailuresLeaveSQLAndVisibleStateUnchanged() throws {
        let (store, database, account, _, credentials) = try fixture()
        var edited = account; edited.label = "Edited"
        let history = store.history[account.id]
        credentials.failRead = true
        XCTAssertThrowsError(try store.saveAccount(edited, secret: "fixture-new-key"))
        credentials.failRead = false; credentials.failSave = true
        XCTAssertThrowsError(try store.saveAccount(edited, secret: "fixture-new-key"))
        credentials.failSave = false; credentials.failRemove = true
        store.removeAccount(account)
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
        return { try? self.execute("DROP TRIGGER fail_commit; DROP TABLE fixture_child; DROP TABLE fixture_parent", directory: directory) }
    }

    func testFailedCommitRestoresReplacedAndNewCredentials() throws {
        for hadKey in [true, false] {
            let (store, database, account, directory, credentials) = try fixture()
            if !hadKey { credentials.values[account.id] = nil }
            let removeCommitFailure = try failCommit(directory: directory, credentials: credentials)
            defer { removeCommitFailure() }
            var edited = account; edited.label = "Edited"; edited.profileDirectory = "/fixture/new-profile"
            let history = store.history[account.id]
            XCTAssertThrowsError(try store.saveAccount(edited, secret: "fixture-new-key"))
            XCTAssertEqual(store.accounts, [account])
            XCTAssertEqual(store.history[account.id], history)
            XCTAssertEqual(try database.history(account: account.id), history)
            XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
            XCTAssertEqual(credentials.values[account.id], hadKey ? "fixture-old-key" : nil)
            XCTAssertEqual(credentials.mutations, 2)
        }
    }

    func testFailedCommitRestoresRemovedKeyAndRetainsAccount() throws {
        let (store, database, account, directory, credentials) = try fixture()
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials)
        defer { removeCommitFailure() }
        store.removeAccount(account)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(credentials.mutations, 2)
    }

    func testFailedCompensationRetainsBackupAndRetriesBeforeAnotherAccountAction() throws {
        let (store, database, account, directory, credentials) = try fixture()
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials, failCompensation: true)
        var edited = account; edited.label = "Edited"
        XCTAssertThrowsError(try store.saveAccount(edited, secret: "fixture-new-key"))
        removeCommitFailure()
        XCTAssertNotNil(store.failures[account.id])
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(credentials.values[account.id], "fixture-new-key")
        XCTAssertThrowsError(try store.saveAccount(edited, secret: ""))
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        credentials.failSave = false
        try store.saveAccount(edited, secret: "")
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertNil(store.failures[account.id])
        XCTAssertNil(store.storageError)
    }

    func testPresenceAndOrdinaryEditsDoNotReadSecretsAndKeyRemovalRetainsHistory() throws {
        let (store, database, account, _, credentials) = try fixture()
        let history = store.history[account.id], snapshot = store.snapshots[account.id]
        store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date().addingTimeInterval(100))
        let resets = store.manualResets.map(\.id)
        XCTAssertTrue(store.hasSavedKey(for: account))
        var edited = account; edited.label = "Edited"
        try store.saveAccount(edited, secret: "")
        XCTAssertEqual(credentials.reads, 0)
        store.failures[account.id] = "Old credential failure"
        store.resetAccountsAwaitingRefresh.insert(account.id)
        try store.removeSavedKey(for: edited)
        XCTAssertNil(credentials.values[account.id])
        XCTAssertFalse(store.hasSavedKey(for: edited))
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [edited])
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(store.snapshots[account.id], snapshot)
        XCTAssertEqual(try database.history(account: account.id), history)
        XCTAssertEqual(store.manualResets.map(\.id), resets)
        XCTAssertTrue(edited.useLocalCredentials)
        XCTAssertNil(store.failures[account.id])
        XCTAssertFalse(store.resetAccountsAwaitingRefresh.contains(account.id))
    }

    func testFailedSavedKeyRemovalPreservesKeyAndRefreshState() throws {
        let (store, database, account, directory, credentials) = try fixture()
        let history = store.history[account.id]
        store.failures[account.id] = "Previous failure"
        try execute("CREATE TRIGGER fail_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        XCTAssertThrowsError(try store.removeSavedKey(for: account))
        XCTAssertEqual(credentials.mutations, 0)
        XCTAssertEqual(store.failures[account.id], "Previous failure")
        try execute("DROP TRIGGER fail_accounts", directory: directory)
        credentials.failRemove = true
        XCTAssertThrowsError(try store.removeSavedKey(for: account))
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.history(account: account.id), history)
    }

    func testSavedKeyRemovalCommitFailureRestoresKeyAndPreservesHistory() throws {
        let (store, database, account, directory, credentials) = try fixture()
        let history = store.history[account.id]
        let removeCommitFailure = try failCommit(directory: directory, credentials: credentials)
        defer { removeCommitFailure() }
        XCTAssertThrowsError(try store.removeSavedKey(for: account))
        XCTAssertEqual(credentials.values[account.id], "fixture-old-key")
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.history[account.id], history)
        XCTAssertEqual(try database.history(account: account.id), history)
    }

    func testSuccessfulSaveAndRemovalCommitRelatedState() throws {
        let (store, database, account, _, credentials) = try fixture()
        store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date())
        var edited = account; edited.profileDirectory = "/fixture/new-profile"
        try store.saveAccount(edited, secret: "fixture-new-key")
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [edited])
        XCTAssertTrue(try database.history(account: account.id).isEmpty)
        XCTAssertNil(store.snapshots[account.id])
        XCTAssertEqual(credentials.values[account.id], "fixture-new-key")
        store.removeAccount(edited)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.manualResets.isEmpty)
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [])
        XCTAssertEqual(try database.read([ManualReset].self, key: "manual-resets")?.count, 0)
        XCTAssertNil(credentials.values[account.id])
    }

    func testUnreadableRelatedPreferencesRemainProtected() throws {
        let (_, database, account, directory, credentials) = try fixture()
        try database.write("incompatible", key: "manual-resets")
        try database.write("incompatible", key: "ssh-hosts")
        let store = AppStore(directory: directory, credentials: credentials)
        store.isPaused = true
        store.removeAccount(account)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(try database.read([AccountConfiguration].self, key: "accounts"), [account])
        XCTAssertEqual(credentials.reads, 0)
        store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date())
        XCTAssertTrue(store.manualResets.isEmpty)
        XCTAssertThrowsError(try store.addSSHHost("fixture-host"))
        XCTAssertTrue(store.sshHosts.isEmpty)
        XCTAssertEqual(try database.read(String.self, key: "manual-resets"), "incompatible")
        XCTAssertEqual(try database.read(String.self, key: "ssh-hosts"), "incompatible")
    }

    func testManualResetsSSHHostsAndSettingsRollBackOnWriteFailure() throws {
        let (store, database, account, directory, _) = try fixture()
        store.addReset(accountID: account.id, title: "Fixture", scope: "Fixture", expiry: Date().addingTimeInterval(100))
        store.settings.soundEnabled.toggle(); store.persistSettings()
        let resetIDs = store.manualResets.map(\.id), settings = store.settings
        try database.write(["fixture-host"], key: "ssh-hosts"); store.sshHosts = ["fixture-host"]
        try execute("CREATE TRIGGER fail_settings BEFORE INSERT ON preferences WHEN NEW.id IN ('manual-resets','ssh-hosts','settings') BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", directory: directory)
        store.addReset(accountID: account.id, title: "Another", scope: "Fixture", expiry: Date())
        store.removeReset(try XCTUnwrap(resetIDs.first))
        XCTAssertEqual(store.manualResets.map(\.id), resetIDs)
        XCTAssertEqual(try database.read([ManualReset].self, key: "manual-resets")?.map(\.id), resetIDs)
        XCTAssertThrowsError(try store.addSSHHost("another-fixture"))
        store.removeSSHHost("fixture-host")
        XCTAssertEqual(store.sshHosts, ["fixture-host"])
        XCTAssertEqual(try database.read([String].self, key: "ssh-hosts"), ["fixture-host"])
        store.settings.soundEnabled.toggle(); store.persistSettings()
        XCTAssertEqual(store.settings, settings)
        XCTAssertEqual(try database.read(MonitorSettings.self, key: "settings"), settings)
        XCTAssertNotNil(store.storageError)
    }
}
