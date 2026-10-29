import XCTest
@testable import JuicebarCore

final class NumericQuotaTests: XCTestCase {
    func testCodexDisplayPrefixDoesNotChangeOrdering() throws {
        let payload: [String: Any] = ["rateLimits": ["limitName": "Codex", "primary": ["usedPercent": 10, "windowDurationMins": 300],
                                                                  "secondary": ["usedPercent": 20, "windowDurationMins": 10080]]]
        let snapshot = try ProviderParsing.codex(payload, configuration: .init(provider: .codex))
        let month = QuotaWindow(id: "budget", title: "Budget", usedPercent: 1)
        XCTAssertEqual(QuotaOrder.windows([month] + snapshot.windows).map(\.id), ["codex.primary", "codex.secondary", "budget"])
        XCTAssertFalse(WeeklyReach.isScoped(snapshot.windows[1]))
    }

    func testRenamedAccountWeekRemainsUnscoped() {
        let week = QuotaWindow(id: "seven_day", title: "Compte · Semaine", usedPercent: 20, duration: 604800)
        XCTAssertFalse(WeeklyReach.isScoped(week))
    }

    func testCountRejectsMalformedAndOutOfRangeInventory() throws {
        for value: Any in [1e100, Double(Int.max), -1.0, 0.5, true, "3", Double.infinity, Double.nan] {
            XCTAssertThrowsError(try ProviderParsing.codex(["rateLimitResetCredits": ["availableCount": value]], configuration: .init(provider: .codex)))
        }
        for count in [0, 3, 1_000_000] {
            let snapshot = try ProviderParsing.codex(["rateLimitResetCredits": ["availableCount": count]], configuration: .init(provider: .codex))
            XCTAssertEqual(snapshot.benefitCount, count)
        }
        XCTAssertNil(try ProviderParsing.codex(["rateLimitResetCredits": [:]], configuration: .init(provider: .codex)).benefitCount)
        XCTAssertNil(try ProviderParsing.codex(["rateLimitResetCredits": ["availableCount": NSNull()]], configuration: .init(provider: .codex)).benefitCount)
    }

    func testInvalidTimeMetadataBecomesUnknown() throws {
        for value in [-1.0, 0, Double.leastNonzeroMagnitude, 1e100, Double.greatestFiniteMagnitude, Double.infinity, Double.nan] {
            let snapshot = try ProviderParsing.codex(["rateLimits": ["primary": ["usedPercent": 10, "windowDurationMins": value, "resetsAt": value]]], configuration: .init(provider: .codex))
            let window = try XCTUnwrap(snapshot.windows.first)
            XCTAssertNil(window.duration)
            XCTAssertNil(window.resetsAt)
            XCTAssertNil(window.idealPercent(at: Date()))
            XCTAssertEqual(window.kind, .unknown)
        }
        XCTAssertNil(JSONValue.date("10000-01-01T00:00:00Z"))
        XCTAssertEqual(JSONValue.title(duration: 1e100, fallback: "Unknown window"), "Unknown window")
        XCTAssertEqual(JSONValue.title(duration: 18000, fallback: "?"), tr("{0} Stunden", 5))
        XCTAssertEqual(JSONValue.date(1_900_000_000), Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testUnsafeFormattingNeverNarrowsToInt() {
        for value in [Double.infinity, -.infinity, .nan, -1, 1e100, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(durationText(value), tr("unbekannt"))
        }
        XCTAssertEqual(durationText(0), tr("{0} Min.", 1))
        XCTAssertEqual(durationText(7200), tr("{0} Std.", 2))
        XCTAssertEqual(QuotaNumbers.integerText(.nan), tr("unbekannt"))
        XCTAssertEqual(QuotaNumbers.integerText(150), "150")
        XCTAssertEqual(QuotaNumbers.integerText(1e100), "1e+100")
        XCTAssertEqual(QuotaNumbers.integerText(Double(Int.max)), "9.22e+18")
    }

    func testOverrunsSurviveParsingCachingAndWarnings() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for percent in [150.0, 1e100, Double.greatestFiniteMagnitude] {
            let snapshot = try ProviderParsing.codex(["rateLimits": ["primary": ["usedPercent": percent]]], configuration: .init(provider: .codex), now: now)
            let cached = try JSONDecoder().decode(AccountSnapshot.self, from: JSONEncoder().encode(snapshot))
            let window = try XCTUnwrap(cached.windows.first)
            XCTAssertEqual(window.usedPercent, percent)
            XCTAssertEqual(QuotaDisplay.used.value(used: percent), percent)
            XCTAssertEqual(QuotaDisplay.remaining.value(used: percent), 0)
            let events = WarningEngine.events(snapshot: cached, accountName: "Fixture", history: [], settings: MonitorSettings(), sent: [], now: now)
            XCTAssertEqual(events.count, 1)
            XCTAssertTrue(events[0].message.contains(QuotaNumbers.integerText(percent)))
        }
    }

    func testBudgetArithmeticRejectsOverflowWithoutCappingOverruns() throws {
        XCTAssertEqual(try QuotaNumbers.budgetPercent(spend: 15, budget: 10), 150)
        XCTAssertEqual(try QuotaNumbers.budgetPercent(spend: 1e308, budget: 1e307), 1000, accuracy: 1e-10)
        XCTAssertGreaterThan(try QuotaNumbers.budgetPercent(spend: 1, budget: 1e-100), 100)
        XCTAssertEqual(try QuotaNumbers.budgetPercent(spend: 0, budget: .leastNonzeroMagnitude), 0)
        XCTAssertThrowsError(try QuotaNumbers.budgetPercent(spend: 1, budget: .leastNonzeroMagnitude))
        for budget in [0.0, -1, Double.infinity, .nan] {
            XCTAssertThrowsError(try QuotaNumbers.budgetPercent(spend: 10, budget: budget))
        }
        for spend in [-1.0, Double.infinity, .nan] {
            XCTAssertThrowsError(try QuotaNumbers.budgetPercent(spend: spend, budget: 10))
        }
    }

    func testCostAggregationRejectsNegativeValuesAndOverflow() {
        for value in [-1.0, -Double.leastNonzeroMagnitude] {
            XCTAssertThrowsError(try ProviderParsing.costBucket(["results": [["amount": value, "currency": "USD"]]], provider: .anthropicAPI))
            XCTAssertThrowsError(try ProviderParsing.costBucket(["results": [["amount": ["value": value, "currency": "usd"]]]], provider: .openaiAPI))
        }
        let row: [String: Any] = ["amount": ["value": 1e308, "currency": "usd"]]
        XCTAssertThrowsError(try ProviderParsing.costBucket(["results": [row, row]], provider: .openaiAPI))
        XCTAssertThrowsError(try ProviderParsing.addingCost(1e308, to: 1e308))
    }

    func testOldCacheUsesStableIDsAndDurationWithoutReadingLabels() throws {
        func decode(id: String, title: String, duration: Double? = nil) throws -> QuotaWindow {
            var raw: [String: Any] = ["id": id, "title": title, "usedPercent": 20, "supportsPace": true]
            raw["duration"] = duration
            return try JSONDecoder().decode(QuotaWindow.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        let week = try decode(id: "codex.secondary", title: "Codex · Semaine", duration: 604800)
        XCTAssertEqual(week.kind, .weekly)
        XCTAssertEqual(week.scope, .account)
        XCTAssertFalse(WeeklyReach.isScoped(week))
        for (id, scope): (String, QuotaScope) in [("seven_day_opus", .model), ("seven_day_sonnet", .model), ("seven_day_oauth_apps", .app), ("model.Fable", .model)] {
            let window = try decode(id: id, title: "Semaine")
            XCTAssertEqual(window.scope, scope)
            XCTAssertTrue(WeeklyReach.isScoped(window))
        }
        let unknown = try decode(id: "undocumented", title: "Woche · All models")
        XCTAssertEqual(unknown.scope, .unknown)
        XCTAssertEqual(unknown.kind, .unknown)
        let encoded = try JSONEncoder().encode(week)
        XCTAssertEqual(try JSONDecoder().decode(QuotaWindow.self, from: encoded), week)
    }

    func testExplicitSemanticsSurviveRenameAndRoundTrip() throws {
        let windows = [QuotaWindow(id: "c", title: "Monat", usedPercent: 0, kind: .monthly, scope: .account),
                       QuotaWindow(id: "b", title: "Semaine", usedPercent: 0, kind: .weekly, scope: .account),
                       QuotaWindow(id: "a", title: "Account · 5 heures", usedPercent: 0, kind: .short, scope: .account),
                       QuotaWindow(id: "d", title: "Week", usedPercent: 0, kind: .weekly, scope: .model)]
        let cached = try JSONDecoder().decode([QuotaWindow].self, from: JSONEncoder().encode(windows))
        XCTAssertEqual(QuotaOrder.windows(cached).map(\.id), ["a", "b", "c", "d"])
        XCTAssertFalse(WeeklyReach.isScoped(cached[2]))
        XCTAssertTrue(WeeklyReach.isScoped(cached[3]))
    }

    func testCacheCannotBypassNumericValidation() throws {
        let raw = #"{"id":"budget","title":"Budget","usedPercent":-1,"duration":1e100,"resetsAt":1e100,"periodAnchor":1e100,"supportsPace":true}"#
        XCTAssertThrowsError(try JSONDecoder().decode(QuotaWindow.self, from: Data(raw.utf8)))
        let window = try JSONDecoder().decode(QuotaWindow.self, from: Data(raw.replacingOccurrences(of: "-1", with: "150").utf8))
        XCTAssertEqual(window.usedPercent, 150)
        XCTAssertNil(window.duration)
        XCTAssertNil(window.resetsAt)
        XCTAssertNil(window.periodAnchor)
        let decoder = JSONDecoder(); decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        for value in ["Inf", "-Inf", "NaN"] {
            let invalid = raw.replacingOccurrences(of: "-1", with: "\"\(value)\"")
            XCTAssertThrowsError(try decoder.decode(QuotaWindow.self, from: Data(invalid.utf8)))
        }
    }

    func testWeeklyConfidenceUsesScopeEvenAfterRenaming() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shortReset = now.addingTimeInterval(3600), weekReset = now.addingTimeInterval(86400)
        let history: [AccountSnapshot] = try (0...8).map { step in
            let primary: [String: Any] = ["usedPercent": Double(step) * 10, "windowDurationMins": 300, "resetsAt": shortReset.timeIntervalSince1970]
            let secondary: [String: Any] = ["usedPercent": 50 + step, "windowDurationMins": 10080, "resetsAt": weekReset.timeIntervalSince1970]
            let payload: [String: Any] = ["rateLimits": ["limitName": "Codex", "primary": primary, "secondary": secondary]]
            return try ProviderParsing.codex(payload, configuration: .init(id: "fixture", provider: .codex), now: now.addingTimeInterval(Double(step - 8) * 600))
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for scope: QuotaScope in [.account, .model, .app, .unknown] {
            let renamed = history.map { sample in
                var sample = sample
                sample.windows[1].scope = scope
                sample.windows[1].title = scope == .account ? "Compte · Semaine" : "Week"
                return sample
            }
            let current = try XCTUnwrap(renamed.last)
            let reaches = WeeklyReach.assess(snapshot: current, history: renamed, hours: .all, now: now, calendar: calendar)
            let plans = WorkPlanTarget.assess(snapshot: current, history: renamed, schedule: .init(isEnabled: true), now: now, calendar: calendar)
            XCTAssertEqual(reaches.count, scope == .account ? 1 : 0)
            XCTAssertEqual(plans.count, scope == .account ? 1 : 0)
        }
    }

    func testProviderNormalizationKeepsKnownScopesAndUnknownGoWindows() throws {
        let claude = try ProviderParsing.claude(["rate_limits": ["seven_day": ["utilization": 12, "resets_at": NSNull()],
                                                                       "seven_day_oauth_apps": ["utilization": 12, "resets_at": NSNull()],
                                                                       "seven_day_opus": ["utilization": 12, "resets_at": NSNull()]]], configuration: .init(provider: .claude))
        XCTAssertEqual(claude.windows.map(\.kind), [.weekly, .weekly, .weekly])
        XCTAssertEqual(claude.windows.map(\.scope), [.account, .app, .model])
        let go = try ProviderParsing.openCodeGo(["usage": ["rolling": ["percent": 150], "weekly": ["percent": 1e100], "monthly": ["percent": 12], "future": ["percent": 1]]], configuration: .init(provider: .opencodeGo), identity: "fixture")
        let rolling = try XCTUnwrap(go.windows.first { $0.id == "rolling" })
        XCTAssertEqual(rolling.kind, .short)
        XCTAssertEqual(TrayMeter(account: .init(provider: .opencodeGo), window: rolling, fresh: true).windowLabel, "5h")
        XCTAssertEqual(go.windows.first { $0.id == "weekly" }?.kind, .weekly)
        XCTAssertEqual(go.windows.first { $0.id == "monthly" }?.kind, .monthly)
        XCTAssertEqual(go.windows.first { $0.id == "future" }?.kind, .unknown)
        XCTAssertEqual(go.windows.first { $0.id == "future" }?.scope, .unknown)
        for invalid in [-1.0, Double.infinity, .nan] {
            XCTAssertThrowsError(try ProviderParsing.claude(["rate_limits": ["seven_day": ["utilization": invalid, "resets_at": NSNull()]]], configuration: .init(provider: .claude)))
            XCTAssertThrowsError(try ProviderParsing.openCodeGo(["usage": ["weekly": ["percent": invalid]]], configuration: .init(provider: .opencodeGo), identity: "fixture"))
        }
    }

    func testOverflowingHistoryDoesNotInventWeeklyEstimates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(age: Double, short: Double, long: Double) -> AccountSnapshot {
            AccountSnapshot(configurationID: "fixture", identity: "fixture", observedAt: now.addingTimeInterval(-age), source: "fixture", windows: [
                QuotaWindow(id: "five_hour", title: "Short", usedPercent: short, resetsAt: now.addingTimeInterval(18000), duration: 18000),
                QuotaWindow(id: "seven_day", title: "Week", usedPercent: long, resetsAt: now.addingTimeInterval(604800), duration: 604800)
            ])
        }
        let history = [sample(age: 1200, short: 0, long: 0), sample(age: 600, short: 60, long: 1e308)]
        let current = sample(age: 0, short: 80, long: 90)
        XCTAssertTrue(WeeklyReach.assess(snapshot: current, history: history, hours: .all, now: now).isEmpty)
        XCTAssertTrue(WorkPlanTarget.assess(snapshot: current, history: history, schedule: .init(isEnabled: true), now: now).isEmpty)
        let repeated = history + [sample(age: 300, short: 0, long: 0), sample(age: 0, short: 60, long: 1e308)]
        XCTAssertNil(WeeklyReach.ratio(shortID: "five_hour", longID: "seven_day", history: repeated, now: now, minimumLongPoints: 3))
    }

    func testInvalidInMemoryModelsProduceNoWarningsOrProjections() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for percent in [-1.0, Double.infinity, .nan] {
            let window = QuotaWindow(id: "five_hour", title: "Fixture", usedPercent: percent, resetsAt: now.addingTimeInterval(1800), duration: 18000)
            let snapshot = AccountSnapshot(configurationID: "fixture", identity: "fixture", observedAt: now, source: "fixture", windows: [window])
            XCTAssertEqual(QuotaStatus.assess(window: window, snapshot: snapshot, history: [], now: now), .unavailable)
            XCTAssertTrue(WarningEngine.events(snapshot: snapshot, accountName: "Fixture", history: [], settings: MonitorSettings(), sent: [], now: now).isEmpty)
            XCTAssertTrue(QuotaDisplay.used.value(used: percent).isNaN)
            XCTAssertNil(window.idealPercent(at: now))
        }
    }
}
