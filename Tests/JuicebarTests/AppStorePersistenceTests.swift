import XCTest
import JuicebarCore
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
        XCTAssertTrue(store.storageError?.contains("Originaldaten") == true)
    }

    func testMissingAccountsUseDefaultsWithoutRecoveryError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-empty-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        XCTAssertEqual(store.accounts.map(\.id), ["default-codex", "default-claude"])
        XCTAssertFalse(store.hasRecoverableStorageError)
        XCTAssertNil(store.storageError)
    }
}
