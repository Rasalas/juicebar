import XCTest
@testable import JuicebarCore

final class ActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func record(_ text: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }
    func testModernCodexDoesNotDoubleCountLegacyCacheOrReasoning() throws {
        var parser = UsageLogParser(source: .codex, fileID: "file")
        parser.consume(try record(#"{"timestamp":"2026-09-25T12:00:00Z","type":"token_usage_record","payload":{"response_id":"response-a","usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":10}}}"#))
        parser.consume(try record(#"{"timestamp":"2026-09-25T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#))
        XCTAssertEqual(parser.events.count, 1)
        XCTAssertEqual(parser.events.first?.tokens, 120)
        XCTAssertNotEqual(parser.events.first?.id, "response-a")
    }
    func testLegacyCodexUsesCumulativeDeltasAndKeepsIdenticalRealRequests() throws {
        var parser = UsageLogParser(source: .codex, fileID: "file")
        for (index, total) in [120, 120, 240, 360].enumerated() {
            parser.consume(["timestamp": now.addingTimeInterval(Double(index)).timeIntervalSince1970, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["input_tokens": 100, "output_tokens": 20]]]])
        }
        XCTAssertEqual(parser.events.count, 3)
        XCTAssertEqual(parser.events.reduce(0) { $0 + $1.tokens }, 360)
    }
    func testClaudeBlocksAndCopiedResponsesDeduplicate() throws {
        var parser = UsageLogParser(source: .claude, fileID: "file")
        for output in [10, 20, 20] {
            parser.consume(["type": "assistant", "timestamp": now.timeIntervalSince1970, "requestId": "request", "message": ["id": "message", "model": "claude", "usage": ["input_tokens": 2, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 40, "output_tokens": output, "output_tokens_details": ["thinking_tokens": 10]]]])
        }
        let report = ActivityReport(events: parser.events + parser.events, now: now)
        XCTAssertEqual(report.days.first?.responses, 1)
        XCTAssertEqual(report.days.first?.tokens, 162)
    }
    func testForkBurstDoesNotCountParentUsage() {
        var parser = UsageLogParser(source: .codex, fileID: "fork")
        parser.consume(["type": "session_meta", "timestamp": now.timeIntervalSince1970, "payload": ["id": "child", "forked_from_id": "parent"]])
        for (offset, total) in [(0.1, 1000), (0.2, 2000), (8.0, 2100)] {
            parser.consume(["type": "event_msg", "timestamp": now.addingTimeInterval(offset).timeIntervalSince1970, "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["input_tokens": 90, "output_tokens": 10]]]])
        }
        XCTAssertEqual(parser.events.count, 1)
        XCTAssertEqual(parser.events.first?.tokens, 100)
    }
    func testCalendarUsesLocalDaysAndKeepsSourcesSeparate() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 7200)!
        let date = ISO8601DateFormatter().date(from: "2026-09-25T23:00:00Z")!
        let events = ActivitySource.allCases.map { ActivityEvent(id: "same-id", source: $0, date: date, model: "m", tokens: 100) }
        let report = ActivityReport(events: events, now: date, calendar: calendar)
        XCTAssertEqual(report.days.count, 3)
        XCTAssertEqual(report.days.map(\.tokens).reduce(0, +), 300)
        XCTAssertEqual(calendar.component(.day, from: report.days[0].day), 26)
    }
    func testCacheInvalidatesChangedFilesWithoutCopyingContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = logs.appendingPathComponent("test.jsonl")
        func line(_ id: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "timestamp": Date().timeIntervalSince1970, "message": ["id": id, "content": "PRIVATE_TRANSCRIPT_SENTINEL", "model": "m", "usage": ["input_tokens": 10, "output_tokens": 5]]])
            data.append(10); return data
        }
        let first = try line("a"); try first.write(to: file)
        let roots = [ActivityLogs.Root(source: .claude, url: logs)]
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache).events.count, 1)
        let cacheFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        let cached = try Data(contentsOf: cacheFile)
        XCTAssertNil(cached.range(of: Data("PRIVATE_TRANSCRIPT_SENTINEL".utf8)))
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache).events.count, 1)
        XCTAssertEqual(try Data(contentsOf: cacheFile), cached)
        let updated = try first + line("b")
        try updated.write(to: file)
        XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache).events.count, 2)
        XCTAssertEqual(try Data(contentsOf: file), updated)
    }
    func testLargeTranscriptDoesNotHideUsageOrCreateFalseWarnings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = String(repeating: "x", count: 5 * 1024 * 1024)
        var data = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": content]])
        data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: ["type": "assistant", "timestamp": Date().timeIntervalSince1970, "message": ["id": "large-response", "model": "claude-opus-5", "content": content, "usage": ["input_tokens": 10, "output_tokens": 5]]]))
        data.append(10)
        try data.write(to: root.appendingPathComponent("large.jsonl"))
        let result = try ActivityLogs.read(roots: [.init(source: .claude, url: root)], cacheDirectory: nil)
        XCTAssertEqual(result.events.count, 1, "An oversized transcript must not discard its usage")
        XCTAssertTrue(result.notices.isEmpty, "Valid chat content is not damaged usage")
    }

    func testSSHRejectsShellSyntaxAndOptions() {
        for host in ["workstation", "user@host.example", "my-server_2"] { XCTAssertTrue(SSHActivity.isValidHost(host)) }
        for host in ["", "-oProxyCommand=bad", "workstation;echo x", "$(id)", "workstation\nother", "workstation host"] { XCTAssertFalse(SSHActivity.isValidHost(host)) }
    }
    func testOldSettingsKeepWarningsAndDefaultToRemainingAndAllAccounts() throws {
        var settings = MonitorSettings(); settings.threshold = 73; settings.soundEnabled = false
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json.removeValue(forKey: "quotaDisplay"); json.removeValue(forKey: "trayStyle")
        let decoded = try JSONDecoder().decode(MonitorSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.threshold, 73); XCTAssertFalse(decoded.soundEnabled)
        XCTAssertEqual(decoded.displayMode, .remaining); XCTAssertEqual(decoded.menuStyle, .lines)
        XCTAssertEqual(decoded.displayMode.value(used: 20), 80)
    }
    func testMenuShowsEveryLimitInStableAccountOrder() {
        let accounts = [AccountConfiguration(id: "a", provider: .codex), AccountConfiguration(id: "b", provider: .claude)]
        let snapshots = ["a": AccountSnapshot(configurationID: "a", identity: "a", observedAt: now, source: "test", windows: [QuotaWindow(id: "w", title: "Woche", usedPercent: 20, duration: 604800)]),
                         "b": AccountSnapshot(configurationID: "b", identity: "b", observedAt: now, source: "test", windows: [QuotaWindow(id: "s", title: "5 Stunden", usedPercent: 27, duration: 18000), QuotaWindow(id: "w", title: "Woche", usedPercent: 36, duration: 604800)])]
        var settings = MonitorSettings()
        let meters = TraySelection.meters(accounts: accounts, snapshots: snapshots, failures: [], settings: settings, now: now)
        XCTAssertEqual(meters.map(\.account.id), ["a", "b", "b"])
        XCTAssertEqual(meters.map(\.windowLabel), ["W", "5h", "W"])
        XCTAssertEqual(meters.map { $0.window?.usedPercent }, [20, 27, 36])
        settings.trayStyle = .focused; settings.selectedTrayAccount = "b"
        XCTAssertEqual(TraySelection.meters(accounts: accounts, snapshots: snapshots, failures: [], settings: settings, now: now).first?.window?.id, "w")
        settings.selectedTrayWindow = "s"
        XCTAssertEqual(TraySelection.meters(accounts: accounts, snapshots: snapshots, failures: ["b"], settings: settings, now: now).first?.fresh, false)
        settings.selectedTrayWindow = "removed"
        XCTAssertNil(TraySelection.meters(accounts: accounts, snapshots: snapshots, failures: [], settings: settings, now: now).first?.window)
    }
    func testLegacyTrayStylesMigrateWithoutChangingWarningPreferences() throws {
        for legacy in ["all", "glasses"] {
            var original = MonitorSettings(); original.threshold = 72; original.soundEnabled = false
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            json["trayStyle"] = legacy
            let decoded = try JSONDecoder().decode(MonitorSettings.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.menuStyle, .lines)
            XCTAssertEqual(decoded.threshold, 72)
            XCTAssertFalse(decoded.soundEnabled)
        }
    }
    func testLineSlotsKeepModelLimitsAndExpiredWindowsWithoutReorderingByUsage() {
        let codex = AccountConfiguration(id: "cx", provider: .codex)
        let claude = AccountConfiguration(id: "cl", provider: .claude)
        let go = AccountConfiguration(id: "go", provider: .opencodeGo)
        let disabled = AccountConfiguration(id: "off", provider: .codex, enabled: false)
        let windows = [QuotaWindow(id: "nimbus_quill", title: "Nimbus Quill", usedPercent: 0),
                       QuotaWindow(id: "model.fable", title: "Fable · Woche", usedPercent: 95, duration: 604800),
                       QuotaWindow(id: "week", title: "Woche", usedPercent: 12, resetsAt: now.addingTimeInterval(-1), duration: 604800),
                       QuotaWindow(id: "short", title: "5 Stunden", usedPercent: 65, duration: 18000)]
        let snapshot = AccountSnapshot(configurationID: "cl", identity: "cl", observedAt: now, source: "test", windows: windows)
        let meters = TraySelection.meters(accounts: [go, claude, disabled, codex], snapshots: ["cl": snapshot], failures: ["cl"], settings: MonitorSettings(), now: now)
        XCTAssertEqual(meters.map(\.account.id), ["cx", "cl", "cl", "cl", "go"])
        XCTAssertEqual(meters.compactMap { $0.window?.id }, ["short", "week", "model.fable"])
        XCTAssertTrue(meters[2].expired)
        XCTAssertFalse(meters[1].fresh)
        XCTAssertNil(meters.last?.window)
        XCTAssertEqual(Set(meters.map(\.id)).count, meters.count)
    }

    func testTrayVisibilityPersistsPerAccountAndOnlyChangesFutureDefaults() throws {
        let a = AccountConfiguration(id: "a", provider: .claude)
        let b = AccountConfiguration(id: "b", provider: .claude)
        let windows = [QuotaWindow(id: "five_hour", title: "5 Stunden", usedPercent: 22),
                       QuotaWindow(id: "nimbus_quill", title: "Nimbus Quill", usedPercent: 0)]
        let snapshot = AccountSnapshot(configurationID: "a", identity: "a", observedAt: now, source: "test", windows: windows)
        var settings = MonitorSettings()
        settings.setNewTrayLimitsVisible(false, accounts: [a], snapshots: ["a": snapshot])
        XCTAssertTrue(settings.showsTrayLimit(account: a, windowID: "five_hour"))
        XCTAssertFalse(settings.showsTrayLimit(account: a, windowID: "SUPERHYPERMEGA"))
        settings.setTrayLimit(accountID: a.id, windowID: "nimbus_quill", visible: true)
        settings = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(settings.showsTrayLimit(account: a, windowID: "nimbus_quill"))
        XCTAssertFalse(settings.showsTrayLimit(account: b, windowID: "nimbus_quill"))
        settings.setTrayLimit(accountID: a.id, windowID: "five_hour", visible: false)
        settings.setTrayLimit(accountID: a.id, windowID: "nimbus_quill", visible: false)
        XCTAssertTrue(TraySelection.meters(accounts: [a], snapshots: ["a": snapshot], failures: [], settings: settings, now: now).isEmpty)
        XCTAssertEqual(snapshot.windows.count, 2)
        settings.trayStyle = .focused; settings.selectedTrayAccount = a.id; settings.selectedTrayWindow = "nimbus_quill"
        XCTAssertNil(TraySelection.meters(accounts: [a], snapshots: ["a": snapshot], failures: [], settings: settings, now: now).first?.window)
    }

}
