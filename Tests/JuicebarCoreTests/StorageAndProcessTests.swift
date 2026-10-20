import XCTest
import CSQLite
@testable import JuicebarCore

final class StorageAndProcessTests: XCTestCase {
    func testUnreadablePreferenceCannotBeOverwrittenByFallback() throws {
        let db = try HistoryDatabase(path: ":memory:")
        try db.write("incompatible account data", key: "accounts")
        XCTAssertThrowsError(try db.read([AccountConfiguration].self, key: "accounts"))
        XCTAssertThrowsError(try db.write([AccountConfiguration](), key: "accounts"))
        XCTAssertEqual(try db.read(String.self, key: "accounts"), "incompatible account data")
        try db.write(MonitorSettings(), key: "settings")
        XCTAssertNotNil(try db.read(MonitorSettings.self, key: "settings"))
    }

    func testExplicitRecoveryBacksUpOriginalBytesAndOnlyResetsUnreadableKeys() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-recovery-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let db = try HistoryDatabase(path: file.path)
        try db.write("incompatible", key: "accounts")
        try db.write("healthy", key: "opencode-path")
        XCTAssertThrowsError(try db.read([AccountConfiguration].self, key: "accounts"))
        XCTAssertEqual(try db.recoverUnreadablePreferences(), ["accounts"])
        XCTAssertNil(try db.read([AccountConfiguration].self, key: "accounts"))
        XCTAssertEqual(try db.read(String.self, key: "opencode-path"), "healthy")
        try db.write([AccountConfiguration](), key: "accounts")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT payload FROM preference_recovery WHERE preference='accounts'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let payload = Data(bytes: sqlite3_column_blob(statement, 0)!, count: Int(sqlite3_column_bytes(statement, 0)))
        XCTAssertEqual(payload, try JSONEncoder().encode("incompatible"))
    }

    func testClaudePrefersNativeInstallationOverOlderPackageManagerCopy() throws {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let native = home.appendingPathComponent(".local/bin/claude").path
        let installed = [native, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let result = try ProcessClient.resolveExecutable("claude", homeDirectory: home, isExecutableFile: installed.contains)
        XCTAssertEqual(result.path, native)
    }

    func testExecutableFallbacksAndExplicitPaths() throws {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let installed = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/codex", "/Users/fixture/.local/bin/codex"]
        XCTAssertEqual(try ProcessClient.resolveExecutable("claude", homeDirectory: home, isExecutableFile: installed.contains).path,
                       "/opt/homebrew/bin/claude")
        XCTAssertEqual(try ProcessClient.resolveExecutable("claude", homeDirectory: home, isExecutableFile: { $0 == "/usr/local/bin/claude" }).path,
                       "/usr/local/bin/claude")
        XCTAssertEqual(try ProcessClient.resolveExecutable("codex", homeDirectory: home, isExecutableFile: installed.contains).path,
                       "/opt/homebrew/bin/codex")
        XCTAssertEqual(try ProcessClient.resolveExecutable("claude", custom: "/custom/claude", homeDirectory: home, isExecutableFile: { _ in true }).path,
                       "/custom/claude")
        XCTAssertThrowsError(try ProcessClient.resolveExecutable("claude", custom: "/missing/claude", homeDirectory: home, isExecutableFile: installed.contains))
        XCTAssertThrowsError(try ProcessClient.resolveExecutable("claude", homeDirectory: home, isExecutableFile: { _ in false }))
    }

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
    func testWriteToExitedChildThrowsInsteadOfRaisingSIGPIPE() throws {
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        defer { client.close() }
        XCTAssertThrowsError(try client.receive { _ in true })
        XCTAssertThrowsError(try client.sendInput(Data(repeating: 65, count: 128 * 1024)))
        XCTAssertThrowsError(try client.send(["type": "control_request"]))
    }
    func testCustomExecutableFindsInterpreterInItsOwnDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-bin-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let interpreter = directory.appendingPathComponent("fixture-node"), tool = directory.appendingPathComponent("fixture-cli")
        try "#!/bin/sh\necho '{\"interpreter\":true}'\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try "#!/usr/bin/env fixture-node\n".write(to: tool, atomically: true, encoding: .utf8)
        for file in [interpreter, tool] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let client = try ProcessClient(executable: tool, arguments: [])
        defer { client.close() }
        XCTAssertEqual(try client.receive { $0["interpreter"] != nil }["interpreter"] as? Bool, true)
    }
    func testCloseStopsGrandchildThatIgnoresTermination() throws {
        // The helper reports its pid only after it ignores SIGTERM, like a stubborn MCP server.
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "(trap '' TERM; exec sh -c 'echo \"{\\\"pid\\\":$$}\"; exec sleep 30') & wait"])
        let pid = try XCTUnwrap(client.receive { $0["pid"] != nil }["pid"] as? Int)
        client.close()
        let end = Date().addingTimeInterval(2)
        while kill(pid_t(pid), 0) == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        let survived = kill(pid_t(pid), 0) == 0
        if survived { kill(pid_t(pid), SIGKILL) }
        XCTAssertFalse(survived)
    }
    func testFailedReadDoesNotLockPreference() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-read-error-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let db = try HistoryDatabase(path: file.path)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &connection), SQLITE_OK)
        // Stepping this view fails like BUSY or IOERR would: the row is never decoded.
        XCTAssertEqual(sqlite3_exec(connection, "DROP TABLE preferences; CREATE VIEW preferences AS SELECT 'opencode-path' AS id, abs(-9223372036854775807 - 1) AS payload;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        XCTAssertThrowsError(try db.read(String.self, key: "opencode-path"))
        XCTAssertTrue(db.unreadablePreferenceKeys.isEmpty)
        XCTAssertNoThrow(try db.requireWritablePreference("opencode-path"))
    }
    func testOutdatedCacheIsDiscardedWithoutLockingWrites() throws {
        let db = try HistoryDatabase(path: ":memory:")
        try db.write("old format", key: "local-usage-v2")
        XCTAssertNil(try db.readCache(LocalUsageReport.self, key: "local-usage-v2"))
        XCTAssertTrue(db.unreadablePreferenceKeys.isEmpty)
        try db.write(MonitorSettings(), key: "local-usage-v2")
        XCTAssertEqual(try db.readCache(MonitorSettings.self, key: "local-usage-v2"), MonitorSettings())
    }
    func testHistoryIsCappedPerAccount() throws {
        let db = try HistoryDatabase(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<3 { try db.save(AccountSnapshot(configurationID: "quiet", identity: "q", observedAt: start.addingTimeInterval(Double(index)), source: "fixture")) }
        for index in 0..<1500 { try db.save(AccountSnapshot(configurationID: "busy", identity: "b", observedAt: start.addingTimeInterval(Double(1000 + index)), source: "fixture")) }
        let busy = try db.history(account: "busy", limit: 12000)
        XCTAssertGreaterThanOrEqual(busy.count, HistoryDatabase.observationsPerAccount)
        XCTAssertLessThan(busy.count, HistoryDatabase.observationsPerAccount + 100)
        XCTAssertEqual(busy.last?.observedAt, start.addingTimeInterval(2499))
        XCTAssertEqual(try db.history(account: "quiet").count, 3)
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
