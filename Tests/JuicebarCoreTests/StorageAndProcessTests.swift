import XCTest
import CSQLite
@testable import JuicebarCore

final class StorageAndProcessTests: XCTestCase {
    func testChildUsesExplicitDirectoryWithoutLauncherPWD() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar work \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import os,json; print(json.dumps({'directoryMatches':os.path.samefile(os.getcwd(),os.environ['EXPECTED_DIRECTORY']),'pwdMatches':os.path.samefile(os.getcwd(),os.environ['PWD'])}))"],
            environment: ["PWD": "/Volumes/unrelated-project", "EXPECTED_DIRECTORY": directory.path], workingDirectory: directory)
        defer { client.close() }
        let response = try client.receive { $0["directoryMatches"] != nil }
        XCTAssertEqual(response["directoryMatches"] as? Bool, true)
        XCTAssertEqual(response["pwdMatches"] as? Bool, true)
    }
    func testChildDoesNotInheritUnrelatedProjectDirectory() throws {
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                       arguments: ["-c", "import os,json; print(json.dumps({'cwd':os.getcwd(),'pwd':os.environ.get('PWD'),'oldpwd':os.environ.get('OLDPWD')}))"],
                                       environment: ["PWD": "/Volumes/unrelated-project", "OLDPWD": "/Volumes/another-project"])
        defer { client.close() }
        let response = try client.receive { $0["cwd"] != nil }
        XCTAssertEqual(response["pwd"] as? String, response["cwd"] as? String)
        XCTAssertTrue(response["oldpwd"] is NSNull)
    }
    func testStorageRoundTripIsolationAndWarningDedup() throws {
        let db = try HistoryDatabase(path: ":memory:")
        let snapshot = AccountSnapshot(configurationID: "a", identity: "i", source: "fixture")
        try db.save(snapshot)
        XCTAssertEqual(try db.history(account: "a"), [snapshot])
        XCTAssertTrue(try db.history(account: "b").isEmpty)
        let event = WarningEvent(id: "same", accountID: "a", kind: .threshold, title: "A", message: "50%", createdAt: Date())
        try db.saveWarning(event); try db.saveWarning(event)
        XCTAssertEqual(try db.warnings().count, 1)
        try db.write(MonitorSettings(), key: "settings")
        XCTAssertEqual(try db.read(MonitorSettings.self, key: "settings"), MonitorSettings())
        try db.removeAccount("a")
        XCTAssertTrue(try db.history(account: "a").isEmpty)
    }
    func testProcessTimeoutIsBounded() throws {
        let start = Date()
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.2)
        XCTAssertThrowsError(try client.receive { _ in true }) { XCTAssertEqual($0 as? ProviderFailure, .timedOut) }
        client.close()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testProcessSkipsNonMatchingJSONLines() throws {
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["noise\n{\"id\":1}\n{\"id\":2,\"ok\":true}\n"])
        defer { client.close() }
        let response = try client.receive { ($0["id"] as? Int) == 2 }
        XCTAssertEqual(response["ok"] as? Bool, true)
    }
    func testOpenCodeMigrationDeduplicatesAndNeverWritesDatabase() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-test-\(UUID()).db")
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?; sqlite3_open(file.path, &db)
        let time = Int(Date().timeIntervalSince1970 * 1000)
        let json = "{\"id\":\"m1\",\"role\":\"assistant\",\"providerID\":\"opencode-go\",\"modelID\":\"fixture\",\"tokens\":{\"input\":100,\"output\":20,\"cache\":{\"read\":30}},\"cost\":0.2}"
        for table in ["message", "session_message"] {
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE \(table)(id TEXT,data TEXT,time_created INTEGER); INSERT INTO \(table) VALUES('m1','\(json)',\(time));", nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(db)
        let original = try Data(contentsOf: file)
        let report = try OpenCodeHistory.read(path: file.path)
        XCTAssertEqual(report.messageCount, 1)
        XCTAssertEqual(report.days.first?.tokens, 150)
        XCTAssertEqual(report.models.first?.cost, 0.2)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
