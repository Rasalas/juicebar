import XCTest
import CSQLite
@testable import JuicebarCore

final class SQLiteReadFailureTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-sql-errors-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func execute(_ sql: String, file: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    func testHistoryAndWarningsThrowOnStepErrorInsteadOfReturningEmpty() throws {
        let file = try directory().appendingPathComponent("history.sqlite")
        let database = try HistoryDatabase(path: file.path)
        let snapshot = AccountSnapshot(configurationID: "fixture", identity: "fixture", source: "fixture")
        try database.save(snapshot)
        try database.saveWarning(WarningEvent(id: "fixture", accountID: "fixture", kind: .threshold, title: "Fixture", message: "Fixture", createdAt: Date()))
        // These prepare successfully but fail while stepping, like an I/O failure during a scan.
        try execute("ALTER TABLE observations RENAME TO stored_observations; CREATE VIEW observations AS SELECT id,account,time,json('invalid') AS payload FROM stored_observations; ALTER TABLE warnings RENAME TO stored_warnings; CREATE VIEW warnings AS SELECT id,time,json('invalid') AS payload FROM stored_warnings", file: file)
        XCTAssertThrowsError(try database.history(account: "fixture"))
        XCTAssertThrowsError(try database.warnings())
        try execute("DROP VIEW observations; ALTER TABLE stored_observations RENAME TO observations; DROP VIEW warnings; ALTER TABLE stored_warnings RENAME TO warnings", file: file)
        XCTAssertEqual(try database.history(account: "fixture"), [snapshot])
        XCTAssertEqual(try database.warnings().count, 1)
    }
    func testThinningDoesNotDeletePartialScanAndRetriesAfterStepError() throws {
        let file = try directory().appendingPathComponent("history.sqlite")
        let database = try HistoryDatabase(path: file.path), now = Date()
        for offset in 0..<5 {
            let snapshot = AccountSnapshot(configurationID: "fixture", identity: "fixture", observedAt: now.addingTimeInterval(-172800 + Double(offset)), source: "fixture")
            let payload = try JSONEncoder().encode(snapshot).map { String(format: "%02x", $0) }.joined()
            try execute("INSERT INTO observations(account,time,payload) VALUES('fixture',\(snapshot.observedAt.timeIntervalSince1970),X'\(payload)')", file: file)
        }
        // The index yields four valid rows before the final row raises an SQLite expression error.
        try execute("ALTER TABLE observations RENAME TO stored_observations; CREATE VIEW observations AS SELECT id,account,time,CASE WHEN id=5 THEN json('invalid') ELSE payload END AS payload FROM stored_observations; CREATE TRIGGER insert_observation INSTEAD OF INSERT ON observations BEGIN INSERT INTO stored_observations(account,time,payload) VALUES(NEW.account,NEW.time,NEW.payload); END; CREATE TRIGGER delete_observation INSTEAD OF DELETE ON observations BEGIN DELETE FROM stored_observations WHERE id=OLD.id; END", file: file)
        try database.save(AccountSnapshot(configurationID: "fixture", identity: "fixture", observedAt: now, source: "fixture"))
        try execute("DROP VIEW observations; ALTER TABLE stored_observations RENAME TO observations", file: file)
        XCTAssertEqual(try database.history(account: "fixture").count, 6, "A failed thinning scan must leave every old row intact")
        try database.save(AccountSnapshot(configurationID: "fixture", identity: "fixture", observedAt: now.addingTimeInterval(1), source: "fixture"))
        XCTAssertEqual(try database.history(account: "fixture").count, 4, "The next save retries thinning instead of treating a partial scan as complete")
    }

    func testOpenCodeStepErrorDoesNotPublishOrCachePartialTablesAndImportKeepsOldValues() throws {
        let directory = try directory(), file = directory.appendingPathComponent("opencode.db")
        let now = Date(), time = Int(now.timeIntervalSince1970 * 1000)
        let record = #"{"role":"assistant","modelID":"fixture","cost":0.2,"tokens":{"input":1}}"#
        try execute("CREATE TABLE message(id TEXT,data TEXT,time_created INTEGER); INSERT INTO message VALUES('original','\(record)',\(time))", file: file)
        let archive = directory.appendingPathComponent("archive")
        let original = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: archive, now: now)
        XCTAssertEqual(original.0.days.reduce(0) { $0 + $1.responses }, 1)
        let summary = try XCTUnwrap(original.1)
        // The legacy table can be scanned completely before the second table fails in sqlite3_step.
        try execute("INSERT INTO message VALUES('new','\(record)',\(time)); CREATE VIEW session_message AS SELECT 'broken' AS id,json('invalid') AS data,\(time) AS time_created", file: file)
        XCTAssertThrowsError(try OpenCodeHistory.read(path: file.path, now: now))
        XCTAssertThrowsError(try OpenCodeHistory.read(path: file.path, now: now))
        let retained = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: archive, now: now.addingTimeInterval(60))
        XCTAssertEqual(retained.0.days.reduce(0) { $0 + $1.responses }, 1)
        XCTAssertFalse(retained.0.warnings.isEmpty)
        XCTAssertEqual(retained.1?.observedAt, summary.observedAt)
        XCTAssertEqual(retained.1?.messageCount, summary.messageCount)
        XCTAssertEqual(retained.1?.models.map(\.model), summary.models.map(\.model))
        let cold = directory.appendingPathComponent("cold-archive")
        try FileManager.default.copyItem(at: archive, to: cold)
        let restarted = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: cold, now: now.addingTimeInterval(120))
        XCTAssertEqual(restarted.1?.observedAt, summary.observedAt)
        XCTAssertEqual(restarted.1?.messageCount, summary.messageCount)
        try execute("DROP VIEW session_message", file: file)
        XCTAssertEqual(try OpenCodeHistory.read(path: file.path, now: now).messageCount, 2)
    }
}
