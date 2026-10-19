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
        XCTAssertEqual(store.storageError, tr("Zurückgesetzt: {0}. Die Originaldaten bleiben gesichert.", "accounts"))
    }

    func testMissingAccountsUseDefaultsWithoutRecoveryError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-empty-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        XCTAssertEqual(store.accounts.map(\.id), CLISetupHelp.detectedDefaultAccounts().map(\.id))
        XCTAssertFalse(store.hasRecoverableStorageError)
        XCTAssertNil(store.storageError)
    }

    func testFirstRunOnlyAddsInstalledCLIs() {
        XCTAssertEqual(CLISetupHelp.detectedDefaultAccounts { _ in true }.map(\.id), ["default-codex", "default-claude"])
        XCTAssertEqual(CLISetupHelp.detectedDefaultAccounts { $0 == "claude" }.map(\.id), ["default-claude"])
        XCTAssertTrue(CLISetupHelp.detectedDefaultAccounts { _ in false }.isEmpty)
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

    func testRelativeTimeOmitsZeroUnits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(relativeTime(now.addingTimeInterval(2 * 3600), now: now), tr("in {0} Std.", 2))
        XCTAssertEqual(relativeTime(now.addingTimeInterval(2 * 3600 + 300), now: now), tr("in {0} Std. {1} Min.", 2, 5))
        XCTAssertEqual(relativeTime(now.addingTimeInterval(3 * 86400), now: now), tr("in {0} T.", 3))
        XCTAssertEqual(relativeTime(now.addingTimeInterval(3 * 86400 + 7200), now: now), tr("in {0} T. {1} Std.", 3, 2))
    }
}
