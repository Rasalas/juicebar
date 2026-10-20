import XCTest
import JuicebarCore
import CSQLite
@testable import Juicebar

@MainActor
final class AppStorePersistenceTests: XCTestCase {
    func testCorruptAccountsStayEmptyAndCannotOverwriteOriginalUntilExplicitRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        try database.write("incompatible", key: "accounts")
        let store = AppStore(directory: directory)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.hasRecoverableStorageError)
        XCTAssertTrue(store.storageError?.contains("accounts") == true)
        XCTAssertThrowsError(try store.saveAccount(AccountConfiguration(id: "new", provider: .codex), secret: ""))
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(try database.read(String.self, key: "accounts"), "incompatible")
        store.recoverStoredConfiguration()
        XCTAssertFalse(store.hasRecoverableStorageError)
        XCTAssertEqual(store.accounts.map(\.id), ["default-codex", "default-claude"])
        XCTAssertNil(try database.read(String.self, key: "accounts"))
        XCTAssertEqual(store.storageError, tr("Zurückgesetzt: {0}. Die Originaldaten bleiben gesichert.", "accounts"))
    }

    func testMissingAccountsUseDefaultsWithoutRecoveryError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-empty-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        XCTAssertEqual(store.accounts.map(\.id), ["default-codex", "default-claude"])
        XCTAssertFalse(store.hasRecoverableStorageError)
        XCTAssertNil(store.storageError)
    }

    func testClockTickOnlyPublishesNewMinutes() {
        let store = AppStore(demo: true)
        let minute = (store.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        store.now = Date(timeIntervalSinceReferenceDate: minute)
        store.tick(at: Date(timeIntervalSinceReferenceDate: minute + 59))
        XCTAssertEqual(store.now, Date(timeIntervalSinceReferenceDate: minute))
        store.tick(at: Date(timeIntervalSinceReferenceDate: minute + 60))
        XCTAssertEqual(store.now, Date(timeIntervalSinceReferenceDate: minute + 60))
    }

    func testQuotaHistoryCacheFollowsHistoryChanges() throws {
        let store = AppStore(demo: true)
        let id = try XCTUnwrap(store.history.keys.sorted().first)
        let count = store.quotaHistory(for: id).count
        XCTAssertEqual(count, store.history[id]?.count)
        var next = try XCTUnwrap(store.history[id]?.last); next.observedAt = next.observedAt.addingTimeInterval(60)
        store.history[id]?.append(next)
        XCTAssertEqual(store.quotaHistory(for: id).count, count + 1)
    }

    func testOutdatedCachesAreDiscardedWithoutErrorAndKeepOpenCodePath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-cache-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        try database.write("old format", key: "activity-report-v2")
        try database.write("old format", key: "local-usage-v2")
        try database.write("/fixture/opencode.db", key: "opencode-path")
        let store = AppStore(directory: directory)
        XCTAssertNil(store.activity)
        XCTAssertNil(store.localUsage)
        XCTAssertNil(store.storageError)
        XCTAssertFalse(store.hasRecoverableStorageError)
        XCTAssertEqual(store.localDatabasePath, "/fixture/opencode.db")
    }

    func testDeliveredWarningCountsAsSentWhenSavingFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-warning-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "DROP TABLE warnings", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        let event = WarningEvent(id: "fixture-warning", accountID: "a", kind: .threshold, title: "A", message: "50 %", createdAt: Date())
        store.recordDelivered([event])
        XCTAssertEqual(store.warnings.map(\.id), ["fixture-warning"])
        XCTAssertNotNil(store.storageError)
    }
}
