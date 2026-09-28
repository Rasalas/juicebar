import XCTest
@testable import JuicebarCore

final class PiActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var usage: [String: Any] {
        ["input": 10, "output": 5, "cacheRead": 30, "cacheWrite": 20, "totalTokens": 65, "cost": ["total": 0.42]]
    }
    private func message(_ id: String, role: String = "assistant", provider: String = "openai-codex", model: String = "custom-model") -> [String: Any] {
        ["type": "message", "id": id, "timestamp": now.timeIntervalSince1970,
         "message": ["role": role, "timestamp": now.timeIntervalSince1970 * 1000, "provider": provider,
                     "model": model, "usage": usage, "content": "PRIVATE_CONTENT"]]
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func lines(_ records: [[String: Any]]) throws -> Data {
        try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
    }

    func testPiCountsEveryUsageKindWithoutCountingToolsAsResponses() throws {
        var parser = UsageLogParser(source: .pi, fileID: "file")
        parser.consume(message("answer"))
        parser.consume(message("tool", role: "toolResult"))
        parser.consume(message("user", role: "user"))
        for kind in ["compaction", "branch_summary", "usage"] {
            parser.consume(["type": kind, "id": kind, "timestamp": now.timeIntervalSince1970, "usage": usage,
                            "summary": "PRIVATE_CONTENT", "details": ["private": "PRIVATE_CONTENT"]])
        }
        XCTAssertEqual(parser.events.count, 5)
        XCTAssertEqual(parser.events.first?.provider, "openai-codex")
        XCTAssertEqual(parser.events.first?.date, now)
        XCTAssertEqual(parser.events.first?.usage?.total, 65)
        XCTAssertEqual(parser.events.last?.model, "custom-model")
        let day = try XCTUnwrap(ActivityReport(events: parser.events, now: now).days.first)
        XCTAssertEqual(day.tokens, 325)
        XCTAssertEqual(day.responses, 3)
        XCTAssertEqual(day.apiCost, 2.1, accuracy: 0.000001)
        XCTAssertEqual(day.pricedTokens, 325)
    }

    func testProvidersAndModelsFollowEachResponse() {
        var parser = UsageLogParser(source: .pi, fileID: "file")
        for provider in ["openai-codex", "anthropic", "openrouter", "new-provider"] {
            parser.consume(message(provider, provider: provider, model: provider + "-model"))
        }
        XCTAssertEqual(parser.events.map(\.provider), ["openai-codex", "anthropic", "openrouter", "new-provider"])
        XCTAssertEqual(parser.events.map(\.model), parser.events.map { $0.provider + "-model" })
    }

    func testForksPreferOriginalSessionRegardlessOfFileOrHostOrder() throws {
        func events(created: Double, cost: Double, file: String) -> [ActivityEvent] {
            var parser = UsageLogParser(source: .pi, fileID: file)
            parser.consume(["type": "session", "id": file, "timestamp": created, "cwd": "PRIVATE_PATH"])
            var record = message("copied-entry")
            var fields = record["message"] as! [String: Any]
            var tokens = usage; tokens["cost"] = ["total": cost]
            fields["usage"] = tokens; record["message"] = fields
            parser.consume(record)
            return parser.events
        }
        let original = events(created: now.timeIntervalSince1970 - 100, cost: 0.42, file: "original")
        let fork = events(created: now.timeIntervalSince1970 - 50, cost: 9, file: "fork")
        for input in [original + fork, fork + original, fork + original + original] {
            let day = try XCTUnwrap(ActivityReport(events: input, now: now).days.first)
            XCTAssertEqual(day.responses, 1)
            XCTAssertEqual(day.tokens, 65)
            XCTAssertEqual(day.apiCost, 0.42)
        }
        XCTAssertEqual(original.first?.id, fork.first?.id)
        XCTAssertNotEqual(original.first?.id, "copied-entry")
    }

    func testTimestampFallbackAndSameEntryIDAtDifferentTimes() throws {
        var parser = UsageLogParser(source: .pi, fileID: "file")
        parser.consume(message("same"))
        var second = message("same")
        var fields = second["message"] as! [String: Any]; fields.removeValue(forKey: "timestamp")
        second["message"] = fields; second["timestamp"] = "2027-01-15T07:59:59.000Z"
        parser.consume(second)
        XCTAssertEqual(parser.events.count, 2)
        XCTAssertNotEqual(parser.events[0].id, parser.events[1].id)
        XCTAssertEqual(parser.events[1].date, ISO8601DateFormatter().date(from: "2027-01-15T07:59:59Z"))
    }

    func testMissingCostUsesCatalogButExplicitZeroRemainsZero() throws {
        var parser = UsageLogParser(source: .pi, fileID: "file")
        for (id, cost) in [("absent", nil as Double?), ("zero", 0), ("negative", -3)] {
            var record = message(id, model: "claude-opus-5")
            var fields = record["message"] as! [String: Any]
            var tokens = usage; tokens["cost"] = cost.map { ["total": $0] }
            fields["usage"] = tokens; record["message"] = fields
            parser.consume(record)
        }
        XCTAssertNil(parser.events[0].reportedCost)
        XCTAssertEqual(parser.events[1].reportedCost, 0)
        XCTAssertNil(parser.events[2].reportedCost)
        let expected = try XCTUnwrap(APICost.estimate(model: "claude-opus-5", usage: parser.events[0].usage))
        let day = try XCTUnwrap(ActivityReport(events: parser.events, now: now).days.first)
        XCTAssertEqual(day.apiCost, expected * 2, accuracy: 0.000001)
        XCTAssertTrue(day.unpricedModels.isEmpty)
    }

    func testUnknownModelsWithoutCostStayUnpricedAndInvalidCountsAreNotPriced() throws {
        var parser = UsageLogParser(source: .pi, fileID: "file")
        var record = message("unknown")
        var fields = record["message"] as! [String: Any]
        fields["usage"] = ["input": 10, "output": 5, "totalTokens": 15]
        record["message"] = fields; parser.consume(record)
        fields["usage"] = ["input": -10, "output": 5, "totalTokens": 15]
        record["id"] = "invalid"; record["message"] = fields; parser.consume(record)
        XCTAssertNil(parser.events.last?.usage)
        let day = try XCTUnwrap(ActivityReport(events: parser.events, now: now).days.first)
        XCTAssertEqual(day.pricedTokens, 0)
        XCTAssertEqual(day.unpricedModels, ["custom-model"])
    }

    func testCacheRestartGrowthPrivacyAndUnfinishedLines() throws {
        let root = try temporaryDirectory(), logs = root.appendingPathComponent("logs/nested")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("session.jsonl")
        let header: [String: Any] = ["type": "session", "id": "PRIVATE_ID", "timestamp": now.timeIntervalSince1970 - 100, "cwd": "PRIVATE_PATH"]
        var contents = try lines([header, message("first")])
        contents.append(Data("{\"usage\":broken}\n".utf8))
        let last = try lines([message("second")])
        contents.append(last.dropLast()); try contents.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let roots = [ActivityLogs.Root(source: .pi, url: root.appendingPathComponent("logs"))]
        let first = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now)
        XCTAssertEqual(first.events.count, 1); XCTAssertEqual(first.notices.count, 1)
        XCTAssertEqual(first.events.first?.sessionStartedAt, now.addingTimeInterval(-100))
        let cachedURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        let cachedData = try Data(contentsOf: cachedURL)
        XCTAssertNil(cachedData.range(of: Data("PRIVATE_".utf8)))
        let reopened = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now)
        XCTAssertEqual(reopened.events.first?.reportedCost, 0.42)
        XCTAssertEqual(try Data(contentsOf: cachedURL), cachedData)
        contents.append(10); try contents.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 2)
        XCTAssertEqual(try Data(contentsOf: file), contents)
        try FileManager.default.removeItem(at: logs)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, 2)
        XCTAssertTrue(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now.addingTimeInterval(91 * 86400)).events.isEmpty)
    }

    func testRootsUseEnvironmentAndMergeManualFoldersWithAutomaticDiscovery() throws {
        let home = try temporaryDirectory()
        let standard = ActivityLogs.defaultRoots(accounts: [], home: home, environment: [:])
        XCTAssertEqual(standard.first { $0.source == .pi }?.url, home.appendingPathComponent(".pi/agent/sessions"))
        let custom = ActivityLogs.defaultRoots(accounts: [], home: home, environment: ["PI_CODING_AGENT_DIR": "~/custom"])
        XCTAssertEqual(custom.first { $0.source == .pi }?.url, home.appendingPathComponent("custom/sessions"))
        let session = home.appendingPathComponent("session-override")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: session)
        let manual = [ActivityLogs.Root(source: .pi, url: link), .init(source: .pi, url: session.appendingPathComponent("."))]
        let restored = try JSONDecoder().decode([ActivityLogs.Root].self, from: JSONEncoder().encode(manual))
        let merged = ActivityLogs.defaultRoots(accounts: [], additional: restored, home: home,
                                              environment: ["PI_CODING_AGENT_DIR": "~/ignored", "PI_CODING_AGENT_SESSION_DIR": session.path])
        XCTAssertEqual(merged.filter { $0.source == .pi }.count, 1)
        XCTAssertEqual(merged.first { $0.source == .pi }?.url.path, session.path)
    }

    func testOldCachedEventsStillDecodeAsOneResponse() throws {
        let event = ActivityEvent(id: "old", source: .claude, date: now, model: "unknown", tokens: 100)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ActivityEvent.self, from: data)
        XCTAssertNil(decoded.responseCount); XCTAssertNil(decoded.reportedCost)
        XCTAssertEqual(ActivityReport(events: [decoded], now: now).days.first?.responses, 1)
    }

    func testRemoteCollectorAndLocalReaderProduceTheSamePiEvents() throws {
        let root = try temporaryDirectory(), logs = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("session.jsonl")
        let records: [[String: Any]] = [
            ["type": "session", "id": "session", "timestamp": now.timeIntervalSince1970 - 100, "cwd": "PRIVATE_PATH"],
            message("answer"), message("tool", role: "toolResult"),
            ["type": "compaction", "id": "summary", "timestamp": now.timeIntervalSince1970, "usage": usage, "summary": "PRIVATE_CONTENT"],
            ["type": "usage", "id": "warm", "timestamp": now.timeIntervalSince1970, "usage": usage, "model": "other", "provider": "other"]
        ]
        try lines(records).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let local = try ActivityLogs.read(roots: [.init(source: .pi, url: logs)], cacheDirectory: nil, now: now).events
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [try XCTUnwrap(Bundle.module.url(forResource: "ssh-usage", withExtension: "py")).path]
        process.environment = ["HOME": root.path, "PI_CODING_AGENT_SESSION_DIR": logs.path,
                               "CODEX_HOME": root.appendingPathComponent("codex").path, "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path, "XDG_DATA_HOME": root.path]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(data.range(of: Data("PRIVATE_".utf8)))
        var remote = UsageLogParser(source: .pi, fileID: stableID(file.path))
        for line in data.split(separator: 10) {
            let row = try JSONSerialization.jsonObject(with: line) as! [String: Any]
            if let record = row["record"] as? [String: Any] { remote.consume(record) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(local), try encoder.encode(remote.events))
        XCTAssertEqual(ActivityReport(events: local + remote.events, now: now).days.first?.tokens, 260)
        XCTAssertEqual(ActivityReport(events: local + remote.events, now: now).days.first?.responses, 2)
    }
}
