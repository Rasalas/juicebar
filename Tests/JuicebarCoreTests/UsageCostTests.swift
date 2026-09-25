import XCTest
import CSQLite
@testable import JuicebarCore

final class UsageCostTests: XCTestCase {
    func testConfirmedPreviewAliasesUsePublishedPricesWithoutChangingLogs() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!
        let previewDate = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        let usage = TokenBreakdown(input: 1000, output: 200, cacheRead: 500)
        let original = ActivityEvent(id: "old-preview", source: .opencode, date: previewDate, model: "ox-alpha-free", provider: "opencode-go", tokens: 1700, usage: usage)
        let data = try PropertyListEncoder().encode(original)
        let cached = try PropertyListDecoder().decode(ActivityEvent.self, from: data)
        let report = ActivityReport(events: [cached, cached], now: now)
        XCTAssertEqual(report.days.first?.responses, 1)
        XCTAssertEqual(report.days.first?.pricedTokens, 1700)
        XCTAssertEqual(try XCTUnwrap(report.days.first?.apiCost), 0.000265, accuracy: 0.00000001)
        XCTAssertEqual(cached.model, "ox-alpha-free"); XCTAssertEqual(cached.id, "old-preview")
        XCTAssertTrue(report.notices.contains { $0.contains("ox-alpha-free → GLM-5.3-Flash") })
        XCTAssertNil(APICost.estimate(model: "ox-alpha-free", provider: "unrelated", usage: usage))
        XCTAssertNil(APICost.estimate(model: "next-alpha-free", provider: "opencode-go", usage: usage))
        XCTAssertEqual(try XCTUnwrap(APICost.estimate(model: "stealth/union-alpha", provider: "openrouter", usage: usage)), 0.004125, accuracy: 0.00000001)
        XCTAssertNil(APICost.estimate(model: "union-alpha", provider: "opencode-go", usage: TokenBreakdown(input: 1, output: 1, cacheWrite: 1)))
    }
    func testAliasCatalogHasUniqueScopedNamesAndResolvableTargets() {
        XCTAssertEqual(ModelAliases.entries.count, 2)
        var seen = Set<String>()
        for alias in ModelAliases.entries {
            XCTAssertEqual(alias.source.scheme, "https")
            XCTAssertNotNil(APICost.estimate(model: alias.canonicalModel, usage: TokenBreakdown(input: 1, output: 1)))
            for provider in alias.providers {
                for name in alias.names { XCTAssertTrue(seen.insert("\(provider)|\(name)").inserted) }
            }
        }
    }
    func testDisjointCodexCacheAndLongContextPricing() throws {
        let usage = try XCTUnwrap(TokenBreakdown.codex(["input_tokens": 300_000, "cached_input_tokens": 100_000, "cache_write_input_tokens": 50_000, "output_tokens": 10_000, "reasoning_output_tokens": 9_000]))
        XCTAssertEqual(usage.total, 310_000)
        XCTAssertEqual(try XCTUnwrap(APICost.estimate(model: "gpt-6-astra", usage: usage)), 5.2, accuracy: 0.000001)
        XCTAssertNil(TokenBreakdown.codex(["input_tokens": 2, "cached_input_tokens": 3, "output_tokens": 1]))
        XCTAssertNil(APICost.estimate(model: "future-model", usage: usage))
    }
    func testClaudeCacheHourAndDatedModel() throws {
        let usage = try XCTUnwrap(TokenBreakdown.claude(["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 40, "cache_creation": ["ephemeral_1h_input_tokens": 30]]))
        XCTAssertEqual(usage.total, 170)
        XCTAssertEqual(try XCTUnwrap(APICost.estimate(model: "claude-haiku-4-5-20251001", usage: usage)), 0.0001925, accuracy: 0.00000001)
    }
    func testCostDeduplicationAndUnknownCoverageRoundTrip() throws {
        let now = Date()
        let event = ActivityEvent(id: "a", source: .claude, date: now, model: "claude-opus-5", tokens: 120, usage: TokenBreakdown(input: 100, output: 20))
        let unknown = ActivityEvent(id: "b", source: .claude, date: now, model: "unknown", tokens: 80)
        let report = ActivityReport(events: [event, event, unknown], now: now)
        let restored = try JSONDecoder().decode(ActivityReport.self, from: JSONEncoder().encode(report))
        let day = try XCTUnwrap(restored.days.first)
        XCTAssertEqual(day.responses, 2); XCTAssertEqual(day.tokens, 200); XCTAssertEqual(day.pricedTokens, 120)
        XCTAssertEqual(day.apiCost, 0.001, accuracy: 0.000001); XCTAssertEqual(day.unpricedModels, ["unknown"])
    }
    func testClaudeArchiveFillsMissingDaysWithoutAddingToDetailedDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!
        let json: [String: Any] = ["dailyModelTokensVersion": 5,
            "dailyActivity": [["date": "2026-07-26", "messageCount": 13], ["date": "2026-09-25", "messageCount": 400]],
            "dailyModelTokens": [["date": "2026-07-26", "tokensByModel": ["claude-opus-4-8": 1234]], ["date": "2026-09-25", "tokensByModel": ["claude-opus-5": 9999]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("stats-cache.json"))
        var report = ActivityReport(events: [.init(id: "older", source: .claude, date: now.addingTimeInterval(-70 * 86400), model: "claude-opus-5", tokens: 5), .init(id: "a", source: .claude, date: now, model: "claude-opus-5", tokens: 100)], now: now, calendar: calendar)
        ClaudeHistory.supplement(&report, roots: [root, root], now: now, calendar: calendar)
        XCTAssertEqual(report.days.count, 3)
        XCTAssertEqual(report.days[1].archivedMessages, 13); XCTAssertEqual(report.days[1].tokens, 1234)
        XCTAssertEqual(report.days.first?.apiCost, 0); XCTAssertEqual(report.days.last?.tokens, 100)
    }
    func testImportRetainsUsageWhenDatabaseDisappears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("opencode.db"), now = Date()
        var db: OpaquePointer?; sqlite3_open(file.path, &db)
        let json = #"{"role":"assistant","modelID":"claude-opus-5","tokens":{"input":100,"output":10,"reasoning":10,"cache":{"read":20,"write":0}}}"#
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message(id TEXT,data TEXT,time_created INTEGER); INSERT INTO message VALUES('a','\(json)',\((now.timeIntervalSince1970 - 1) * 1000));", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let first = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: root, now: now)
        XCTAssertEqual(first.0.days.first?.tokens, 140); XCTAssertTrue(first.0.days.first?.apiCost ?? 0 > 0)
        try FileManager.default.removeItem(at: file)
        let second = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: root, now: now)
        XCTAssertEqual(second.0.days.first?.tokens, 140)
        XCTAssertEqual(second.0.days.first?.apiCost, first.0.days.first?.apiCost)
        XCTAssertTrue(second.0.warnings.contains { $0.contains(tr("OpenCode lokal")) })
    }
}
