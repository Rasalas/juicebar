import XCTest
import CryptoKit
import CSQLite
@testable import JuicebarCore

final class IncrementalImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func lines(_ records: [[String: Any]]) throws -> Data {
        try records.reduce(into: Data()) { data, record in data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
    }
    /// Legacy Codex counters: each event is the difference of running totals, so a resume must keep the total.
    private func codex(_ rows: Range<Int>, header: Bool = false, tokens: Int = 100) throws -> Data {
        var records: [[String: Any]] = []
        if header {
            records += [["type": "session_meta", "timestamp": now.timeIntervalSince1970 - 1000, "payload": ["id": "session", "cwd": "PRIVATE_PATH"]],
                        ["type": "turn_context", "timestamp": now.timeIntervalSince1970 - 1000, "payload": ["model": "gpt-test"]]]
        }
        for row in rows {
            records.append(["type": "event_msg", "timestamp": now.timeIntervalSince1970 - 900 + Double(row),
                            "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": (row + 1) * 300],
                                                                         "last_token_usage": ["input_tokens": tokens, "output_tokens": 20]]]])
            records.append(["type": "response_item", "timestamp": now.timeIntervalSince1970, "payload": ["content": "PRIVATE_CONTENT " + String(repeating: "x", count: 300)]])
        }
        return try lines(records)
    }
    private func ordered(_ events: [ActivityEvent]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(events.sorted { $0.id < $1.id })
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
    }
    private func assertMatchesFullParse(_ roots: [ActivityLogs.Root], cache: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let incremental = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events
        let full = try ActivityLogs.read(roots: roots, cacheDirectory: nil, now: now).events
        XCTAssertFalse(full.isEmpty, file: file, line: line)
        XCTAssertEqual(try ordered(incremental), try ordered(full), file: file, line: line)
    }

    func testStableIDKeepsPersistedHexOutput() {
        XCTAssertEqual(stableID(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(stableID("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for value in ["v2|claude|/tmp/ä ö/session.jsonl", "msg_01|req_01", String(repeating: "🙂", count: 100)] {
            let reference = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(stableID(value), reference)
        }
    }

    func testCompactEventsRoundTripEveryField() throws {
        let events = [
            ActivityEvent(id: stableID("a"), source: .claude, date: now.addingTimeInterval(-0.123), model: "claude-test", tokens: 4_000_123,
                          usage: TokenBreakdown(input: 3, output: 200, cacheRead: 4_000_000, cacheWrite: 900, cacheWriteHour: 20)),
            ActivityEvent(id: "not-a-digest", source: .gemini, date: now, model: "gemini", provider: "google", tokens: 12.5,
                          usage: TokenBreakdown(input: 0.5, output: 12)),
            ActivityEvent(id: stableID("b").uppercased(), source: .codex, date: now, model: "gpt", tokens: 5_000_000_000),
            ActivityEvent(id: stableID("c"), source: .pi, date: now, model: "pi", provider: "openai-codex", tokens: 65, responseCount: 0,
                          reportedCost: 0.42, sessionStartedAt: now.addingTimeInterval(-100))]
        XCTAssertEqual(try ordered(CompactEvents(events).events()), try ordered(events))
        XCTAssertEqual(CompactEvents(events).events(since: now.addingTimeInterval(-0.01), through: now).count, 3)
    }

    func testAppendedLogResumesWithParserStateAndMatchesFullParse() throws {
        let root = try directory(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout.jsonl"), roots = [ActivityLogs.Root(source: .codex, url: logs)]
        try codex(0..<20, header: true).write(to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 20)
        let cached = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        XCTAssertNil(try Data(contentsOf: cached).range(of: Data("PRIVATE_".utf8)))
        // Changing an early line in place proves the next read starts at the stored offset.
        var contents = try Data(contentsOf: file)
        let marker = try XCTUnwrap(contents.range(of: Data("\"input_tokens\":100".utf8)))
        contents.replaceSubrange(marker, with: Data("\"input_tokens\":999".utf8))
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: contents); try handle.close()
        try append(codex(20..<30), to: file)
        let resumed = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events
        // Only the first counter lacks a previous total. A lost total or a full re-parse would change these values.
        XCTAssertEqual(resumed.map(\.tokens).sorted(), [120] + Array(repeating: 300, count: 29))
        // A second process starts from the disk cache and resumes the same way.
        try append(codex(30..<35), to: file)
        let other = root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: cache, to: other)
        XCTAssertEqual(try ordered(ActivityLogs.read(roots: roots, cacheDirectory: other, now: now).events),
                       try ordered(ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events))
    }

    func testPlainAppendsMatchFullParse() throws {
        let root = try directory(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout.jsonl"), roots = [ActivityLogs.Root(source: .codex, url: logs)]
        try codex(0..<5, header: true).write(to: file)
        try assertMatchesFullParse(roots, cache: cache)
        for round in 1...3 {
            try append(codex((round * 5)..<(round * 5 + 5)), to: file)
            try assertMatchesFullParse(roots, cache: cache)
        }
    }

    func testPartialLastLineIsReadOnceComplete() throws {
        let root = try directory(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout.jsonl"), roots = [ActivityLogs.Root(source: .codex, url: logs)]
        let rows = try codex(3..<4)
        let next = rows[..<(try XCTUnwrap(rows.firstIndex(of: 10)) + 1)]
        let split = try XCTUnwrap(next.range(of: Data("token_count".utf8))).upperBound
        try (codex(0..<3, header: true) + next[..<split]).write(to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 3)
        try append(Data(next[split...].dropLast(1)), to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 3, "Still no newline")
        try append(Data([10]), to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 4)
        XCTAssertTrue(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).notices.isEmpty)
        try assertMatchesFullParse(roots, cache: cache)
    }

    func testTruncatedReplacedAndRewrittenLogsAreParsedFromTheStart() throws {
        let root = try directory(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout.jsonl"), roots = [ActivityLogs.Root(source: .codex, url: logs)]
        try codex(0..<10, header: true).write(to: file)
        _ = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now)
        // Truncated in place.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(try codex(0..<4, header: true).count)); try handle.close()
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 4)
        try assertMatchesFullParse(roots, cache: cache)
        // Replaced by a new file that is longer and differs before the old end.
        try (codex(0..<4, header: true, tokens: 50) + codex(4..<12)).write(to: file, options: .atomic)
        let replaced = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events
        XCTAssertEqual(replaced.count, 12); XCTAssertTrue(replaced.contains { $0.usage?.input == 50 })
        try assertMatchesFullParse(roots, cache: cache)
        // Rewritten in place: same identity and longer, but the bytes before the resume point changed.
        let rewrite = try codex(0..<12, header: true, tokens: 70) + codex(12..<14)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: rewrite); try writer.close()
        let rewritten = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events
        XCTAssertEqual(rewritten.count, 14); XCTAssertTrue(rewritten.contains { $0.usage?.input == 70 })
        try assertMatchesFullParse(roots, cache: cache)
    }

    func testUnchangedLogsUseMemoryAndVersionTwoCachesStayValid() throws {
        let root = try directory(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("rollout.jsonl"), roots = [ActivityLogs.Root(source: .codex, url: logs)]
        try codex(0..<3, header: true).write(to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 3)
        let cached = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        try Data("damaged".utf8).write(to: cached)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 3, "Unchanged logs must not read their cache file")
        XCTAssertEqual(try Data(contentsOf: cached), Data("damaged".utf8))

        // A cold process accepts an unchanged log's v2 entry instead of parsing it again.
        struct Legacy: Codable { var version = 2; var size: Int; var modified: Date; var events: [ActivityEvent]; var skipped = 0 }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let marker = ActivityEvent(id: "from-v2", source: .codex, date: now.addingTimeInterval(-60), model: "gpt-test", tokens: 1)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try encoder.encode(Legacy(size: try XCTUnwrap(values.fileSize), modified: try XCTUnwrap(values.contentModificationDate), events: [marker]))
            .write(to: legacy.appendingPathComponent(cached.lastPathComponent))
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: legacy, now: now).events.map(\.id), ["from-v2"])
        try append(codex(3..<4), to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: legacy, now: now).events.count, 4, "A grown log replaces its v2 entry")
    }

    func testVanishedLogsKeepUsageFromMemoryUntilItExpires() throws {
        let root = try directory(), logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let roots = [ActivityLogs.Root(source: .codex, url: logs)]
        try codex(0..<3, header: true).write(to: logs.appendingPathComponent("a.jsonl"))
        try codex(0..<2, header: true).write(to: logs.appendingPathComponent("archived.jsonl"))
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 5)
        try FileManager.default.removeItem(at: logs.appendingPathComponent("archived.jsonl"))
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 5)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 2)
        XCTAssertTrue(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now.addingTimeInterval(91 * 86400)).events.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    func testClaudeOnlyParsesAssistantLines() throws {
        let root = try directory()
        let answer: [String: Any] = ["type": "assistant", "timestamp": now.timeIntervalSince1970, "requestId": "r",
                                     "message": ["id": "m", "model": "claude-test", "usage": ["input_tokens": 10, "output_tokens": 5]]]
        // A tool result may carry a nested usage object; it is never parsed, so even a damaged one is not reported.
        let tool = Data(#"{"type":"user","toolUseResult":{"usage":{"input_tokens":5}"#.utf8) + Data([10])
        try (tool + lines([answer])).write(to: root.appendingPathComponent("session.jsonl"))
        let result = try ActivityLogs.read(roots: [.init(source: .claude, url: root)], cacheDirectory: nil, now: now)
        XCTAssertEqual(result.events.count, 1); XCTAssertTrue(result.notices.isEmpty)
    }

    func testUnchangedOpenCodeDatabaseKeepsArchiveAndSummary() throws {
        let root = try directory(), file = root.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let record = #"{"role":"assistant","modelID":"custom","providerID":"custom","cost":0.2,"tokens":{"input":10,"output":20}}"#
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE message (id TEXT, data TEXT, time_created INTEGER); INSERT INTO message VALUES ('a', '\(record)', \(Int(now.timeIntervalSince1970 * 1000) - 60000))", nil, nil, nil), SQLITE_OK)
        let state = root.appendingPathComponent("state")
        let first = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: state, now: now)
        XCTAssertEqual(first.1?.messageCount, 1)
        let archive = state.appendingPathComponent("activity-sources/\(stableID("opencode|\(file.path)")).plist")
        let written = try Data(contentsOf: archive), date = try archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        for offset in [1.0, 7200] {
            let next = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: state, now: now.addingTimeInterval(offset))
            XCTAssertEqual(next.1?.messageCount, 1, "The local summary must survive a skipped read")
            XCTAssertEqual(next.0.days.reduce(0) { $0 + $1.responses }, 1)
        }
        XCTAssertEqual(try Data(contentsOf: archive), written)
        XCTAssertEqual(try archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES ('b', '\(record)', \(Int(now.timeIntervalSince1970 * 1000) - 30000))", nil, nil, nil), SQLITE_OK)
        let grown = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: state, now: now.addingTimeInterval(7201))
        XCTAssertEqual(grown.1?.messageCount, 2); XCTAssertEqual(grown.0.days.reduce(0) { $0 + $1.responses }, 2)
        XCTAssertNotEqual(try Data(contentsOf: archive), written)
    }

    /// Runs the bundled collector locally, as SSH would, with the state prefix the app sends.
    private func collect(home: URL, state: inout SSHActivity.State) throws {
        let collector = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "ssh-usage", withExtension: "py")))
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = ["-"]
        process.environment = ["HOME": home.path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: SSHActivity.script(state, collector: collector)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(data.range(of: Data("PRIVATE_".utf8))); XCTAssertNil(data.range(of: Data(home.path.utf8)))
        var rows = try data.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }.makeIterator()
        try SSHActivity.consume(host: "test", state: &state, now: now) { try XCTUnwrap(rows.next()) }
    }

    func testRemoteCollectorSkipsUnchangedFilesAndResumesGrownOnes() throws {
        let home = try directory(), logs = home.appendingPathComponent(".claude/projects/project")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        func answers(_ ids: Range<Int>) throws -> Data {
            try lines(ids.map { ["type": "assistant", "timestamp": now.timeIntervalSince1970 - 60, "requestId": "r\($0)", "cwd": "PRIVATE_PATH",
                                 "message": ["id": "m\($0)", "model": "claude-test", "content": "PRIVATE_CONTENT", "usage": ["input_tokens": 10, "output_tokens": $0 + 1]]] })
        }
        let file = logs.appendingPathComponent("session.jsonl")
        try answers(0..<3).write(to: file)
        var state = SSHActivity.State()
        try collect(home: home, state: &state)
        XCTAssertEqual(state.events(since: .distantPast, now: now).count, 3); XCTAssertTrue(state.complete)
        let revision = state.revision
        try collect(home: home, state: &state)
        XCTAssertEqual(state.revision, revision, "Unchanged files are not transferred again")
        let next = try answers(3..<5), partial = try answers(5..<6)
        try append(next + partial.dropLast(5), to: file)
        try collect(home: home, state: &state)
        let entry = try XCTUnwrap(state.files.values.first)
        XCTAssertEqual(entry.offset, Int64(try answers(0..<5).count), "The unfinished line is read next time")
        let local = try ActivityLogs.read(roots: [.init(source: .claude, url: home.appendingPathComponent(".claude/projects"))], cacheDirectory: nil, now: now).events
        XCTAssertEqual(local.count, 5)
        XCTAssertEqual(try ordered(state.events(since: .distantPast, now: now)), try ordered(local))
    }

    func testInterruptedRemoteImportKeepsCheckpointsAndOldResults() throws {
        var state = SSHActivity.State(), parser = UsageLogParser(source: .claude, fileID: "old")
        parser.consume(["type": "assistant", "timestamp": now.timeIntervalSince1970, "message": ["id": "kept", "usage": ["input_tokens": 1]]])
        state.files["known"] = .init(size: 10, modified: 1, inode: 1, offset: 10, tail: "t", parser: parser)
        state.observedAt = now; state.complete = true
        let record: [String: Any] = ["type": "assistant", "timestamp": now.timeIntervalSince1970, "message": ["id": "new", "usage": ["input_tokens": 1]]]
        var rows: [[String: Any]] = [["file": "f", "source": "claude", "key": "first", "size": 100, "mtime": 2, "ino": 2, "resume": false], ["record": record],
                                     ["checkpoint": 50, "tail": "a"], ["record": record],
                                     ["file": "g", "source": "claude", "key": "known", "size": 20, "mtime": 2, "ino": 1, "resume": false], ["checkpoint": 15, "tail": "b"]]
        rows.reverse()
        XCTAssertThrowsError(try SSHActivity.consume(host: "test", state: &state, now: now) {
            guard let row = rows.popLast() else { throw ProviderFailure.timedOut }
            return row
        })
        XCTAssertFalse(state.complete)
        XCTAssertEqual(state.files["first"]?.offset, 50); XCTAssertEqual(state.files["first"]?.size, -1)
        XCTAssertEqual(state.files["known"]?.offset, 10, "A full re-read keeps the previous result until it finishes")
        XCTAssertEqual(Set(state.events(since: .distantPast, now: now).map(\.id)), [stableID("kept|"), stableID("new|")])
    }

    func testRemoteHostsAreReadEveryThirtyMinutesUnlessForcedOrUnfinished() {
        var state = SSHActivity.State()
        XCTAssertTrue(state.isDue(now: now, force: false))
        state.observedAt = now; state.complete = true
        XCTAssertFalse(state.isDue(now: now.addingTimeInterval(600), force: false))
        XCTAssertTrue(state.isDue(now: now.addingTimeInterval(600), force: true))
        XCTAssertTrue(state.isDue(now: now.addingTimeInterval(ActivityImport.remoteInterval), force: false))
        XCTAssertTrue(state.isDue(now: now.addingTimeInterval(-60), force: false), "A clock change must not postpone imports")
        state.complete = false
        XCTAssertTrue(state.isDue(now: now.addingTimeInterval(60), force: false))
    }
}
