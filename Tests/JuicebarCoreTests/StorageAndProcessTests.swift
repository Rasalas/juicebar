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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-cap-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let db = try HistoryDatabase(path: file.path)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<3 { try db.save(AccountSnapshot(configurationID: "quiet", identity: "q", observedAt: start.addingTimeInterval(Double(index)), source: "fixture")) }
        // Every poll changes, so thinning cannot help and only the row ceiling applies.
        let cap = HistoryRetention.maximumRows
        for index in 0..<(cap + 500) {
            try db.save(AccountSnapshot(configurationID: "busy", identity: "b", observedAt: start.addingTimeInterval(Double(1000 + index)), source: "fixture",
                                        windows: [QuotaWindow(id: "w", title: "W", usedPercent: Double(index % 100))]))
        }
        var connection: OpaquePointer?, count: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT count(*) FROM observations WHERE account='busy'", -1, &count, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(count), SQLITE_ROW)
        let stored = Int(sqlite3_column_int(count, 0)); sqlite3_finalize(count)
        XCTAssertGreaterThanOrEqual(stored, cap)
        XCTAssertLessThan(stored, cap + 100)
        let busy = try db.history(account: "busy", limit: cap)
        XCTAssertEqual(busy.count, cap)
        XCTAssertEqual(busy.last?.observedAt, start.addingTimeInterval(Double(1000 + cap + 499)))
        XCTAssertEqual(try db.history(account: "quiet").count, 3)
    }
    /// A light user at the default 300 s cadence: one 5 h session a day, the week moving 0.1 points per short point.
    private func lightUseHistory(days: Int, end: Date) -> [AccountSnapshot] {
        let origin = end.addingTimeInterval(-Double(days) * 86400)
        return stride(from: 0.0, to: Double(days) * 86400, by: 300).map { offset in
            let time = origin.addingTimeInterval(offset)
            let day = (offset / 86400).rounded(.down), sessionStart = day * 86400 + 9 * 3600
            let inSession = offset >= sessionStart && offset < sessionStart + 18000
            let today = offset < sessionStart ? 0 : min(80, ((offset - sessionStart) / 14400 * 80).rounded(.down))
            let short = inSession ? today : 0
            let week = (offset / 604800).rounded(.down), weekDay = day - week * 7
            let long = ((weekDay * 80 + today) * 0.1).rounded(.down)
            return AccountSnapshot(configurationID: "claude", identity: "login", observedAt: time, source: "fixture", windows: [
                QuotaWindow(id: "five_hour", title: "5 h", usedPercent: short, resetsAt: inSession ? origin.addingTimeInterval(sessionStart + 18000) : nil, duration: 18000),
                QuotaWindow(id: "seven_day", title: "Woche", usedPercent: long, resetsAt: origin.addingTimeInterval((week + 1) * 604800), duration: 604800)])
        }
    }
    func testRetentionKeepsWeeklyReachHistoryAndStaysSmall() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = lightUseHistory(days: 40, end: end)
        let db = try HistoryDatabase(path: ":memory:")
        for sample in samples { try db.save(sample) }
        let now = try XCTUnwrap(samples.last?.observedAt)
        let stored = try db.history(account: "claude", limit: HistoryRetention.maximumRows)
        let oldest = try XCTUnwrap(stored.first?.observedAt)
        XCTAssertGreaterThanOrEqual(oldest, now.addingTimeInterval(-HistoryRetention.storedSpan - 100 * 300), "older rows are dropped")
        XCTAssertLessThanOrEqual(oldest, now.addingTimeInterval(-28 * 86400), "a previous weekly cycle stays")
        XCTAssertLessThan(stored.count, samples.count / 4, "unchanged runs collapse")
        let lastDay = samples.filter { now.timeIntervalSince($0.observedAt) < HistoryRetention.completeSpan }
        XCTAssertEqual(Array(stored.suffix(lastDay.count)), lastDay)

        func ratio(_ history: [AccountSnapshot]) -> Double? {
            WeeklyReach.ratio(shortID: "five_hour", longID: "seven_day", history: history, now: now, minimumLongPoints: 3)
        }
        let expected = try XCTUnwrap(ratio(samples))
        XCTAssertEqual(expected, 0.1, accuracy: 0.01)
        let loaded = try db.history(account: "claude", since: now.addingTimeInterval(-HistoryRetention.loadedSpan), limit: HistoryRetention.maximumRows)
        XCTAssertEqual(ratio(loaded), expected)
        let inMemory = samples.reduce(into: [AccountSnapshot]()) { history, sample in history = HistoryRetention.appending(sample, to: history) }
        XCTAssertEqual(ratio(inMemory), expected)
        XCTAssertLessThan(inMemory.count, loaded.count + 100)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(inMemory.first?.observedAt), now.addingTimeInterval(-HistoryRetention.loadedSpan))
    }
    func testThinningKeepsRunEndsAndPeriodChanges() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ minute: Double, _ used: Double, reset: Double = 1, identity: String = "a") -> AccountSnapshot {
            AccountSnapshot(configurationID: "c", identity: identity, observedAt: start.addingTimeInterval(minute * 60), source: "fixture",
                            windows: [QuotaWindow(id: "w", title: "W", usedPercent: used, resetsAt: start.addingTimeInterval(reset * 86400), duration: 18000)])
        }
        let history = [sample(0, 5), sample(1, 5), sample(2, 5), sample(3, 5), sample(4, 6), sample(5, 6, reset: 2), sample(6, 6, reset: 2),
                        sample(7, 6, reset: 2, identity: "b"), sample(8, 6, reset: 2, identity: "b"), sample(9, 6, reset: 2, identity: "b")]
        XCTAssertEqual(HistoryRetention.redundant(history, before: start.addingTimeInterval(3600)), [1, 2, 8])
        XCTAssertEqual(HistoryRetention.redundant(history, before: start.addingTimeInterval(90)), [1])
        XCTAssertEqual(HistoryRetention.redundant(history, from: start.addingTimeInterval(120), before: start.addingTimeInterval(3600)), [2, 8])
        XCTAssertEqual(HistoryRetention.thinned(history, now: start.addingTimeInterval(86400 + 3600)).count, history.count - 3)
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
