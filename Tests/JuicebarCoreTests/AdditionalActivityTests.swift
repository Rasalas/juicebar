import XCTest
import CSQLite
@testable import JuicebarCore

final class AdditionalActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    private var stamp: String { ISO8601DateFormatter().string(from: now) }
    private var gemini: [String: Any] {
        ["type": "gemini", "id": "g", "timestamp": stamp, "model": "gemini-3.1-pro-preview", "content": "PRIVATE_CONTENT",
         "tokens": ["input": 100, "output": 20, "cached": 60, "thoughts": 15, "tool": 5, "total": 140]]
    }
    private var cline: [String: Any] {
        ["id": "c", "role": "assistant", "ts": now.timeIntervalSince1970 * 1000, "content": "PRIVATE_CONTENT",
         "modelInfo": ["id": "custom", "provider": "custom"],
         "metrics": ["inputTokens": 100, "outputTokens": 20, "cacheReadTokens": 60, "cacheWriteTokens": 10, "cost": 0.3]]
    }
    private var roo: [String: Any] {
        ["type": "say", "say": "api_req_started", "ts": now.timeIntervalSince1970 * 1000,
         "text": #"{"tokensIn":100,"tokensOut":20,"cacheReads":60,"cacheWrites":10,"cost":0.4,"request":"PRIVATE_CONTENT"}"#]
    }
    private var qwen: [String: Any] {
        ["type": "assistant", "uuid": "q", "timestamp": stamp, "model": "gpt-6-sol", "message": "PRIVATE_CONTENT",
         "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 20, "cachedContentTokenCount": 60, "thoughtsTokenCount": 15]]
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ value: Any, to file: URL, jsonl: Bool = false) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: value)
        if jsonl { data.append(10) }
        try data.write(to: file)
    }

    func testGeminiDeduplicatesUpdatesCheckpointsAndLegacyMigrationWithoutUndoingBilledUsage() throws {
        var parser = UsageLogParser(source: .gemini, fileID: "file")
        var incomplete = gemini; incomplete.removeValue(forKey: "tokens")
        parser.consume(incomplete); parser.consume(gemini)
        parser.consume(["$set": ["messages": [gemini]]])
        parser.consume(["$rewindTo": "g"])
        try parser.consumeDocument(["sessionId": "s", "messages": [gemini]])
        let day = try XCTUnwrap(ActivityReport(events: parser.events, now: now).days.first)
        XCTAssertEqual(day.responses, 1); XCTAssertEqual(day.tokens, 140)
        let usage = try XCTUnwrap(parser.events.first?.usage)
        XCTAssertEqual(usage.input, 45); XCTAssertEqual(usage.output, 35); XCTAssertEqual(usage.cacheRead, 60)
        XCTAssertEqual(usage.total, 140)
        XCTAssertGreaterThan(day.apiCost, 0)
    }

    func testQwenDoesNotAddReasoningTwice() throws {
        var parser = UsageLogParser(source: .qwen, fileID: "file"); parser.consume(qwen)
        let event = try XCTUnwrap(parser.events.first)
        XCTAssertEqual(event.tokens, 120); XCTAssertEqual(event.usage?.output, 20)
        XCTAssertEqual(event.usage?.input, 40); XCTAssertEqual(event.usage?.cacheRead, 60)
        XCTAssertEqual(event.usage?.total, 120)
    }

    func testClineVersionedContractCountsOnlyTerminalTurnMetrics() throws {
        var parser = UsageLogParser(source: .cline, fileID: "file")
        var unmetered = cline; unmetered.removeValue(forKey: "metrics")
        var user = cline; user["role"] = "user"
        try parser.consumeDocument(["version": 1, "messages": [unmetered, user, cline, cline]])
        let event = try XCTUnwrap(parser.events.first)
        XCTAssertEqual(event.tokens, 120); XCTAssertEqual(event.usage?.input, 30)
        XCTAssertEqual(event.usage?.total, 120); XCTAssertEqual(event.provider, "custom")
        let day = try XCTUnwrap(ActivityReport(events: parser.events, now: now).days.first)
        XCTAssertEqual(day.responses, 1); XCTAssertEqual(day.apiCost, 0.3)
        XCTAssertThrowsError(try parser.consumeDocument(["version": 2, "messages": [cline]]))
        XCTAssertThrowsError(try parser.consumeDocument(["version": true, "messages": [cline]]))
    }

    func testRooIncludesCacheInInputAndKeepsTasksSeparate() throws {
        var a = UsageLogParser(source: .roo, fileID: "task-a"), b = UsageLogParser(source: .roo, fileID: "task-b")
        try a.consumeDocument([roo]); try b.consumeDocument([roo])
        XCTAssertEqual(a.events.first?.tokens, 120); XCTAssertEqual(a.events.first?.usage?.input, 30)
        XCTAssertEqual(a.events.first?.model, tr("Unbekannt"))
        let report = ActivityReport(events: a.events + a.events + b.events, now: now)
        XCTAssertEqual(report.days.first?.responses, 2); XCTAssertEqual(report.days.first?.apiCost, 0.8)
        var partial = roo; partial["text"] = #"{"request":"PRIVATE_CONTENT"}"#
        a.consume(partial); XCTAssertEqual(a.events.count, 1)
    }

    func testDocumentCacheKeepsLastGoodValuesDuringPartialRewriteAndDropsConversationContent() throws {
        let root = try directory(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        let file = logs.appendingPathComponent("task/task.messages.json")
        try write(["version": 1, "messages": [cline], "system_prompt": "PRIVATE_CONTENT"], to: file)
        let roots = [ActivityLogs.Root(source: .cline, url: logs)]
        let first = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now)
        XCTAssertEqual(first.events.count, 1)
        let cached = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        XCTAssertNil(try Data(contentsOf: cached).range(of: Data("PRIVATE_".utf8)))
        try Data("{\"version\":1,".utf8).write(to: file)
        let interrupted = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now)
        XCTAssertEqual(interrupted.events.count, 1); XCTAssertEqual(interrupted.notices.count, 1)
        var second = cline; second["id"] = "c2"
        try write(["version": 1, "messages": [cline, second]], to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 2)
    }

    func testDiscoveryRespectsOverridesAndMergesAdditionalFolders() throws {
        let root = try directory()
        let roots = ActivityLogs.defaultRoots(accounts: [], home: root, environment: [
            "GEMINI_CLI_HOME": root.appendingPathComponent("custom-home").path,
            "QWEN_HOME": root.appendingPathComponent("ignored").path,
            "QWEN_RUNTIME_DIR": root.appendingPathComponent("runtime").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path, "KILO_DB": "custom.db"])
        XCTAssertTrue(roots.contains { $0.source == .gemini && $0.url.path.hasSuffix("custom-home/.gemini/tmp") })
        XCTAssertTrue(roots.contains { $0.source == .gemini && $0.url.path.hasSuffix("custom-home/.cache/.gemini/tmp") })
        XCTAssertTrue(roots.contains { $0.source == .qwen && $0.url.path.hasSuffix("runtime/projects") })
        XCTAssertTrue(roots.contains { $0.source == .kilo && $0.url.path.hasSuffix("data/kilo/custom.db") })
        for source in [ActivitySource.gemini, .cline, .roo, .qwen, .kilo] { XCTAssertTrue(ActivitySource.logFormats.contains(source)) }
        let defaults = ActivityLogs.defaultRoots(accounts: [], home: root, environment: [:])
        let merged = ActivityLogs.defaultRoots(accounts: [], additional: defaults, home: root, environment: [:])
        XCTAssertEqual(defaults.map(\.id), merged.map(\.id))
    }

    func testAllNewDocumentAndJSONLFormatsMatchTheRemoteCollector() throws {
        let root = try directory()
        let files: [(ActivitySource, String, Any, Bool)] = [
            (.gemini, ".gemini/tmp/project/chats/session-legacy.json", ["sessionId": "s", "messages": [gemini]], false),
            (.gemini, ".gemini/tmp/project/chats/session-current.jsonl", gemini, true),
            (.cline, ".cline/data/sessions/task/task.messages.json", ["version": 1, "messages": [cline]], false),
            (.roo, "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/task/ui_messages.json", [roo], false),
            (.qwen, ".qwen/projects/project/chats/session.jsonl", qwen, true)]
        for (_, path, value, jsonl) in files { try write(value, to: root.appendingPathComponent(path), jsonl: jsonl) }
        let local = try ActivityLogs.read(roots: ActivityLogs.defaultRoots(accounts: [], home: root, environment: [:]), cacheDirectory: nil, now: now).events
        let rows = try collectRemote(root: root)
        var parser: UsageLogParser?, remote: [ActivityEvent] = []
        for row in rows {
            if let file = row["file"] as? String, let name = row["source"] as? String, let source = ActivitySource(rawValue: name) {
                parser = UsageLogParser(source: source, fileID: file)
            } else if let record = row["record"] as? [String: Any] { parser?.consume(record) }
            else if row["endFile"] as? Bool == true { remote += parser?.events ?? []; parser = nil }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func ordered(_ events: [ActivityEvent]) -> [ActivityEvent] { events.sorted { $0.source.rawValue + $0.id < $1.source.rawValue + $1.id } }
        XCTAssertEqual(try encoder.encode(ordered(local)), try encoder.encode(ordered(remote)))
        XCTAssertEqual(local.count, 5)
        XCTAssertEqual(ActivityReport(events: local + remote, now: now).days.reduce(0) { $0 + $1.responses }, 4)
    }

    private func collectRemote(root: URL) throws -> [[String: Any]] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [try XCTUnwrap(Bundle.module.url(forResource: "ssh-usage", withExtension: "py")).path]
        process.environment = ["HOME": root.path, "XDG_DATA_HOME": root.appendingPathComponent(".local/share").path]
        process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(data.range(of: Data("PRIVATE_".utf8)))
        return try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
    }

    func testKiloReusesSQLiteSchemaReadsWALUpdatesAndMatchesRemoteSource() throws {
        let root = try directory(), directory = root.appendingPathComponent(".local/share/kilo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("kilo.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        func sql(_ query: String) throws {
            guard sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        }
        try sql("PRAGMA journal_mode=WAL; CREATE TABLE message (id TEXT, data TEXT, time_created INTEGER)")
        let record = #"{"role":"assistant","modelID":"custom","providerID":"custom","cost":0.2,"tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":60,"write":5}},"content":"PRIVATE_CONTENT"}"#
        try sql("INSERT INTO message VALUES ('a', '\(record)', \(Int(now.timeIntervalSince1970 * 1000)))")
        let archive = root.appendingPathComponent("archive")
        let roots = [ActivityLogs.Root(source: .kilo, url: directory)]
        let first = try ActivityImport.read(roots: roots, databasePath: root.appendingPathComponent("absent.db").path, hosts: [], directory: archive, now: now).0
        XCTAssertEqual(first.days.first?.source, .kilo); XCTAssertEqual(first.days.first?.tokens, 100)
        XCTAssertEqual(first.days.first?.apiCost, 0.2)
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: archive.appendingPathComponent("activity-sources"), includingPropertiesForKeys: nil)
        let cache = try XCTUnwrap(cacheFiles.first { $0.lastPathComponent == stableID("kilo|\(directory.path)") + ".plist" })
        let cached = try Data(contentsOf: cache)
        _ = try ActivityImport.read(roots: roots, databasePath: root.appendingPathComponent("absent.db").path, hosts: [], directory: archive, now: now.addingTimeInterval(1))
        XCTAssertEqual(try Data(contentsOf: cache), cached, "Unchanged database and WAL must not rewrite the archive")
        let before = try KiloHistory.fingerprint(root: directory)
        try sql("INSERT INTO message VALUES ('b', '\(record)', \(Int(now.timeIntervalSince1970 * 1000)))")
        XCTAssertNotEqual(try KiloHistory.fingerprint(root: directory), before)
        let second = try ActivityImport.read(roots: roots, databasePath: root.appendingPathComponent("absent.db").path, hosts: [], directory: archive, now: now).0
        XCTAssertEqual(second.days.first?.responses, 2)
        let remote = try collectRemote(root: root).compactMap { $0["event"] as? [String: Any] }
        XCTAssertEqual(remote.count, 2); XCTAssertTrue(remote.allSatisfy { $0["source"] as? String == "kilo" })
        XCTAssertTrue(remote.allSatisfy { JSONValue.number($0["reportedCost"]) == 0.2 })
    }
}
