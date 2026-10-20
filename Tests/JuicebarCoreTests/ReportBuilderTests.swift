import XCTest
@testable import JuicebarCore

/// The streaming builder must give the same report as aggregating the collected event list.
final class ReportBuilderTests: XCTestCase {
    /// The aggregation before the builder, without its day-interval memo: dedup over the full list, then fold the survivors.
    private func legacyReport(events: [ActivityEvent], notices: [String] = [], warnings: [String] = [], now: Date, calendar: Calendar = .current) -> ActivityReport {
        struct Key: Hashable { var source: ActivitySource; var id: String }
        var unique: [Key: ActivityEvent] = [:]
        for event in events where event.date <= now && event.tokens.isFinite && event.tokens > 0 {
            let key = Key(source: event.source, id: event.id)
            unique[key] = unique[key].map { ActivityEvent.preferred($0, event) } ?? event
        }
        struct DayKey: Hashable { var source: ActivitySource; var day: Date }
        struct ModelKey: Hashable { var model: String; var provider: String }
        struct ResolvedModel { var rate: CatalogDocument.Rate?; var alias: String? }
        let catalog = ModelCatalog.shared.snapshot
        var models: [ModelKey: ResolvedModel] = [:], groups: [DayKey: ActivityDay] = [:], hourMasks: [DayKey: Int] = [:]
        let hoursSince = now.addingTimeInterval(-Double(ActivityReport.hourHistoryDays) * 86400)
        for event in unique.values {
            let modelKey = ModelKey(model: event.model, provider: event.provider)
            let resolved = models[modelKey] ?? ResolvedModel(rate: APICost.rate(model: event.model, provider: event.provider, catalog: catalog),
                                                             alias: catalog.resolve(model: event.model, provider: event.provider).map { "\(event.model) → \($0.displayName)" })
            models[modelKey] = resolved
            let day = calendar.dateInterval(of: .day, for: event.date)?.start ?? calendar.startOfDay(for: event.date)
            let key = DayKey(source: event.source, day: day)
            var value = groups[key] ?? ActivityDay(day: day, source: event.source, tokens: 0, responses: 0)
            value.tokens += event.tokens; value.responses += event.responseCount ?? 1
            if let cost = event.reportedCost, cost.isFinite, cost >= 0 {
                value.apiCost += cost; value.pricedTokens += event.tokens
            } else if let usage = event.usage, abs(usage.total - event.tokens) < 0.5, let rate = resolved.rate,
                      let cost = APICost.estimate(rate: rate, usage: usage) {
                value.apiCost += cost; value.pricedTokens += event.tokens
            } else { value.unpricedModels.insert(event.model) }
            groups[key] = value
            if event.date >= hoursSince { hourMasks[key, default: 0] |= 1 << min(23, max(0, Int(event.date.timeIntervalSince(day) / 3600))) }
        }
        let resolved = Set(models.values.compactMap(\.alias)).sorted()
        let days = groups.values.sorted { $0.day == $1.day ? $0.source.rawValue < $1.source.rawValue : $0.day < $1.day }
        let hours: [ActivityHours] = hourMasks.map { ActivityHours(day: $0.key.day, source: $0.key.source, hours: $0.value) }
            .sorted { $0.day == $1.day ? $0.source.rawValue < $1.source.rawValue : $0.day < $1.day }
        let aliases: [String] = resolved.isEmpty ? [] : [tr("Veröffentlichte Modell-Aliase: ") + resolved.joined(separator: "; ") + tr(". Auch ältere Nutzung wird zum aktuellen API-Gegenwert bewertet; die damals kostenlose Preview bleibt in gemeldeten Kosten unverändert.")]
        return ActivityReport(days: days, activeHours: hours, notices: notices + aliases, warnings: warnings, observedAt: now)
    }

    private func assertSame(_ actual: ActivityReport, _ expected: ActivityReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.days.count, expected.days.count, file: file, line: line)
        for (a, b) in zip(actual.days, expected.days) {
            XCTAssertEqual(a.day, b.day, file: file, line: line); XCTAssertEqual(a.source, b.source, file: file, line: line)
            XCTAssertEqual(a.tokens, b.tokens, file: file, line: line); XCTAssertEqual(a.responses, b.responses, file: file, line: line)
            XCTAssertEqual(a.pricedTokens, b.pricedTokens, file: file, line: line); XCTAssertEqual(a.unpricedModels, b.unpricedModels, file: file, line: line)
            XCTAssertEqual(a.archivedMessages, b.archivedMessages, file: file, line: line); XCTAssertEqual(a.archivedTokens, b.archivedTokens, file: file, line: line)
            // The legacy sum runs in hash order, so only the last bits of a cost may differ.
            XCTAssertEqual(a.apiCost, b.apiCost, accuracy: max(1e-12, abs(b.apiCost) * 1e-12), file: file, line: line)
        }
        XCTAssertEqual(actual.activeHours, expected.activeHours, file: file, line: line)
        XCTAssertEqual(actual.notices, expected.notices, file: file, line: line); XCTAssertEqual(actual.warnings, expected.warnings, file: file, line: line)
        XCTAssertEqual(actual.observedAt, expected.observedAt, file: file, line: line)
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Repeated IDs across sources, ties, Pi forks, priced, unpriced, reported and invalid costs, aliases, future and invalid events.
    private func fixture(seed: UInt64, count: Int, now: Date) -> [ActivityEvent] {
        var random = Generator(state: seed)
        let models: [(String, String)] = [("claude-opus-5", ""), ("claude-sonnet-4-5-20250929", "anthropic"), ("gpt-6-astra", "openai"), ("ox-alpha-free", "opencode-go"),
                                          ("union-alpha", "openrouter"), ("ox-alpha-free", "unrelated"), ("local-model", ""), ("gemini-3.1-pro-preview", "google")]
        let ids = (0..<(count / 3)).map { $0 % 4 == 0 ? "plain-\($0)" : $0 % 9 == 0 ? stableID("\($0)").uppercased() : stableID("\($0)") }
        let tokens: [Double] = [130, 130, 170, 1, 12.5, 4_000_000_123, 0, -5, .infinity, .nan]
        return (0..<count).map { _ in
            let model = models.randomElement(using: &random)!, amount = tokens.randomElement(using: &random)!
            let usage: TokenBreakdown? = switch Int.random(in: 0..<5, using: &random) {
            case 0: nil
            case 1: TokenBreakdown(input: 100, output: 20, cacheRead: 10)
            case 2: TokenBreakdown(input: 40, output: 30, cacheRead: 60)
            case 3: TokenBreakdown(input: 1, output: 0, cacheWrite: 1)
            default: TokenBreakdown(input: amount.isFinite ? max(0, amount - 30) : 1, output: 30)
            }
            let reported: Double? = [nil, nil, nil, 0.25, 0, -1, .nan, 1e-7].randomElement(using: &random)!
            let session: Date? = [nil, now.addingTimeInterval(-500), now.addingTimeInterval(-900)].randomElement(using: &random)!
            // Dates cover the 90-day window, the 28-day hour history, the future and fractional seconds.
            let date = now.addingTimeInterval(-Double.random(in: -3600...(95 * 86400), using: &random).rounded() / (Bool.random(using: &random) ? 1 : 7))
            return ActivityEvent(id: ids.randomElement(using: &random)!, source: ActivitySource.allCases.randomElement(using: &random)!, date: date,
                                 model: model.0, provider: model.1, tokens: amount, usage: usage,
                                 responseCount: [nil, nil, 0, 3].randomElement(using: &random)!, reportedCost: reported, sessionStartedAt: session)
        }
    }

    func testBuilderMatchesListAggregationOnVariedEvents() {
        let now = Date(timeIntervalSince1970: 1_790_000_000.25)
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        for (seed, calendar) in [(1, berlin), (2, Calendar.current), (3, berlin)] as [(UInt64, Calendar)] {
            let events = fixture(seed: seed, count: 6000, now: now)
            let expected = legacyReport(events: events, notices: ["n"], warnings: ["w"], now: now, calendar: calendar)
            XCTAssertGreaterThan(expected.days.count, 100)
            XCTAssertTrue(expected.notices.count == 2, "The fixture must reach the alias notice")
            assertSame(ActivityReport(events: events, notices: ["n"], warnings: ["w"], now: now, calendar: calendar), expected)
            assertSame(ActivityReport(events: events.reversed(), notices: ["n"], warnings: ["w"], now: now, calendar: calendar),
                       legacyReport(events: events.reversed(), notices: ["n"], warnings: ["w"], now: now, calendar: calendar))
        }
    }

    func testTiesKeepTheLaterEventAndOnlyWinnersReportAliases() {
        let now = Date()
        let alias = ActivityEvent(id: "x", source: .opencode, date: now, model: "ox-alpha-free", provider: "opencode-go", tokens: 10)
        let larger = ActivityEvent(id: "x", source: .opencode, date: now.addingTimeInterval(-86400), model: "local", tokens: 20)
        let tie = ActivityEvent(id: "x", source: .opencode, date: now.addingTimeInterval(-2 * 86400), model: "other", tokens: 20)
        for events in [[alias, larger, tie], [tie, larger, alias], [larger, alias]] {
            assertSame(ActivityReport(events: events, now: now), legacyReport(events: events, now: now))
        }
        XCTAssertEqual(ActivityReport(events: [alias, larger, tie], now: now).days.map(\.unpricedModels), [["other"]])
        XCTAssertEqual(ActivityReport(events: [alias, larger, tie], now: now).notices, [])
    }

    func testImportMatchesAggregationOfCollectedEvents() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), gemini = root.appendingPathComponent("gemini")
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        // Resumed Claude sessions repeat messages in a later file; the second copy has a larger output count.
        func claudeLine(_ id: Int, output: Int, model: String, age: Double) -> [String: Any] {
            ["type": "assistant", "timestamp": now.timeIntervalSince1970 - age, "requestId": "r\(id)",
             "message": ["id": "m\(id)", "model": model, "usage": ["input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": 100]]]
        }
        func write(_ records: [[String: Any]], to file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try records.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }.write(to: file)
        }
        try write((0..<40).map { claudeLine($0, output: 5, model: "claude-opus-5", age: Double($0) * 7200) }, to: claude.appendingPathComponent("a/one.jsonl"))
        let resumed: [[String: Any]] = (30..<60).map { id in
            let model = id % 2 == 0 ? "claude-sonnet-4-5" : "local"
            return claudeLine(id, output: id < 40 ? 9 : 5, model: model, age: Double(id) * 3600)
        }
        try write(resumed, to: claude.appendingPathComponent("b/two.jsonl"))
        func geminiLine(_ index: Int) -> [String: Any] {
            let tokens: [String: Any] = ["input": 100, "output": 20 + index, "cached": 60, "total": 120 + index]
            return ["type": "gemini", "id": "g\(index % 15)", "timestamp": now.timeIntervalSince1970 - Double(index) * 86400, "model": "gemini-3.1-pro-preview", "tokens": tokens]
        }
        try write((0..<20).map(geminiLine), to: gemini.appendingPathComponent("session.jsonl"))
        let roots = [ActivityLogs.Root(source: .claude, url: claude), ActivityLogs.Root(source: .gemini, url: gemini)]
        let state = root.appendingPathComponent("state"), absent = root.appendingPathComponent("absent.db").path
        let expected = legacyReport(events: try ActivityLogs.read(roots: roots, cacheDirectory: nil, now: now).events, now: now)
        XCTAssertEqual(expected.days.reduce(0) { $0 + $1.responses }, 60 + 15)
        // Cold, then served from the in-memory results.
        for _ in 0..<2 {
            let report = try ActivityImport.read(roots: roots, databasePath: absent, hosts: [], directory: state, now: now).0
            var reference = expected
            reference.warnings = report.warnings
            assertSame(report, reference)
        }
    }
}
