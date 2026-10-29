import XCTest
import JuicebarCore
@testable import Juicebar

final class UsageInspectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ source: ActivitySource = .codex, tokens: Double = 100, cost: Double? = 0.123456, responses: Int = 7) throws -> ActivityDay {
        // Exercise the public persisted shape, including coverage and archive metadata.
        let object: [String: Any] = ["day": now.timeIntervalSinceReferenceDate, "source": source.rawValue,
                                   "tokens": tokens, "responses": responses, "apiCost": cost ?? 0,
                                   "pricedTokens": cost == nil ? 0 : tokens, "unpricedModels": cost == nil ? ["unpriced-model"] : [],
                                   "archivedMessages": 0, "archivedTokens": 0]
        return try JSONDecoder().decode(ActivityDay.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testDaySelectionSurvivesMetricAndSourceChangesAndClampsToNewRange() throws {
        let dates = UsageSelection.days(ending: now, count: 90)
        let selected = dates[10]
        let values = [try day(), try day(.claude, cost: nil)]
        for metric in ActivityMetric.allCases {
            for source in ActivitySource.allCases {
                _ = ActivityMetricDetails(values.filter { $0.source == source }).label(metric)
                XCTAssertEqual(UsageSelection.nearest(selected, in: dates), selected)
            }
        }
        let shorter = UsageSelection.days(ending: now, count: 30)
        XCTAssertEqual(UsageSelection.nearest(selected, in: shorter), shorter.first)
        XCTAssertEqual(UsageSelection.move(shorter.first, by: -7, in: shorter), shorter.first)
        XCTAssertEqual(UsageSelection.move(shorter.last, by: 7, in: shorter), shorter.last)
        XCTAssertEqual(UsageSelection.move(nil, by: -1, in: []), nil)
        XCTAssertEqual(UsageSelection.nearest(nil, in: [now]), now)
    }
    func testDayNavigationUsesLocalCalendarAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15)))
        let dates = UsageSelection.days(ending: end, count: 3, calendar: calendar)
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(dates[2].timeIntervalSince(dates[1]), 25 * 3600)
        XCTAssertEqual(UsageSelection.move(dates[0], by: 1, in: dates), dates[1])
    }
    func testMetricDetailsHaveExactTokensAndResponsesAndPartialCostCoverage() throws {
        let known = try day(tokens: 1234567)
        let unknown = try day(.claude, tokens: 1234567, cost: nil, responses: 3)
        let details = ActivityMetricDetails([known, unknown])
        XCTAssertTrue(details.valueLabel(.tokens).contains((2469134.0).formatted(.number.locale(Localization.locale))))
        XCTAssertEqual(details.valueLabel(.responses), tr("{0} Modellantworten", 10.formatted(.number.locale(Localization.locale))))
        XCTAssertTrue(details.valueLabel(.cost).hasPrefix("≥ "))
        XCTAssertTrue(details.valueLabel(.cost).contains(tr("API-Gegenwert")))
        XCTAssertTrue(details.coverage(.cost).contains(tr("{0} % der Tokens bepreist", "50")))
        XCTAssertTrue(details.coverage(.cost).contains("unpriced-model"))
        XCTAssertFalse(details.label(.tokens).contains(tr("Modellantworten")))
        XCTAssertNil(ActivityMetric.cost.plottedValue(unknown))
        XCTAssertEqual(ActivityMetric.tokens.plottedValue(unknown), unknown.tokens)
        let zero = try day(cost: 0)
        XCTAssertEqual(ActivityMetric.cost.plottedValue(zero), 0)
        XCTAssertFalse(ActivityMetricDetails([zero]).isPartialCost)
    }
    func testArchiveOnlyDaysStayUnknownForCostAndResponses() throws {
        var archived = try day(.claude, tokens: 0, cost: nil, responses: 0)
        archived.archivedMessages = 42
        archived.unpricedModels = []
        let details = ActivityMetricDetails([archived])
        XCTAssertEqual(details.valueLabel(.cost), tr("Kosten unbekannt"))
        XCTAssertEqual(details.valueLabel(.responses), tr("Antworten unbekannt"))
        XCTAssertEqual(details.valueLabel(.tokens), tr("Tokens unbekannt"))
        XCTAssertTrue(details.coverage(.cost).contains(tr("Claude-Kosten nicht rekonstruierbar")))
        XCTAssertTrue(details.coverage(.responses).contains(tr("Archivierte Nachrichten sind keine Modellantworten.")))
        for metric in ActivityMetric.allCases { XCTAssertNil(metric.plottedValue(archived)) }
        archived.tokens = 1400; archived.archivedTokens = 1400
        XCTAssertEqual(ActivityMetric.tokens.plottedValue(archived), 1400)
        XCTAssertEqual(ActivityMetric.cost.plottedValue(archived), nil)
        let mixed = ActivityMetricDetails([try day(), archived])
        XCTAssertTrue(mixed.valueLabel(.cost).hasPrefix("≥ "))
        XCTAssertEqual(ActivityMetricDetails([]).valueLabel(.cost), tr("Keine protokollierte Aktivität"))
    }
    func testQuotaNavigationKeepsPeriodIdentityAndUsesNearestTimestamp() {
        let a = QuotaPoint(date: now, value: 100.125, label: "Same label", series: "account|period-a")
        let b = QuotaPoint(date: now.addingTimeInterval(60), value: 25, label: a.label, series: a.series)
        let c = QuotaPoint(date: now.addingTimeInterval(120), value: 20, label: a.label, series: "account|period-b")
        let points = [c, b, a]
        XCTAssertEqual(QuotaSelection.resolve(a.id, in: points), a)
        XCTAssertEqual(QuotaSelection.move(a.id, by: 1, in: points), b.id)
        XCTAssertEqual(QuotaSelection.move(b.id, by: 1, in: points), b.id)
        XCTAssertEqual(QuotaSelection.resolve(a.id, in: [b, c]), b)
        XCTAssertEqual(QuotaSelection.resolve(a.id, in: [c]), c)
        XCTAssertEqual(QuotaSelection.changeSeries(b.id, by: 1, in: points), c.id)
        XCTAssertEqual(QuotaSelection.changeSeries(c.id, by: -1, in: points), b.id)
        var changedMetric = a; changedMetric.value = 0
        XCTAssertEqual(QuotaSelection.resolve(a.id, in: [changedMetric])?.value, 0)
        XCTAssertTrue(QuotaSelection.detail(a, displayLabel: "used").contains((100.125).formatted(.number.locale(Localization.locale))))
        XCTAssertEqual(QuotaSelection.move(nil, by: 1, in: [a]), a.id)
        XCTAssertNil(QuotaSelection.resolve(a.id, in: []))
        XCTAssertNil(QuotaSelection.changeSeries(nil, by: 1, in: []))
    }
    @MainActor func testDayDetailIncludesEachSourceAndSelectedMetric() throws {
        let values = [try day(), try day(.claude, cost: nil)]
        let label = ActivityDayDetail.label(date: now, days: values, metric: .cost)
        XCTAssertTrue(label.contains("Codex:"))
        XCTAssertTrue(label.contains("Claude:"))
        XCTAssertTrue(label.contains(tr("Kosten unbekannt")))
        XCTAssertFalse(label.contains(tr("{0} Modellantworten", 7)))
    }
}
