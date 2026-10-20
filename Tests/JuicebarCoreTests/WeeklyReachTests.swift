import XCTest
@testable import JuicebarCore

final class WeeklyReachTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "UTC")!; return value }()
    private func snapshot(at time: Date, short: Double, shortReset: Date?, long: Double, longReset: Date?, identity: String = "login",
                          extra: [QuotaWindow] = []) -> AccountSnapshot {
        AccountSnapshot(configurationID: "claude", identity: identity, observedAt: time, source: "fixture",
                        windows: [QuotaWindow(id: "five_hour", title: "5 Stunden", usedPercent: short, resetsAt: shortReset, duration: 18000),
                                  QuotaWindow(id: "seven_day", title: "Woche", usedPercent: long, resetsAt: longReset, duration: 604800)] + extra)
    }
    /// One short window filling from 0 to `points` while the week moves `ratio` per point.
    private func history(points: Double = 80, ratio: Double = 0.1, longEnd: Double, longReset: Date, shortReset: Date) -> [AccountSnapshot] {
        (0...8).map { step in
            let used = points * Double(step) / 8
            return snapshot(at: now.addingTimeInterval(Double(step - 8) * 600), short: used, shortReset: shortReset,
                            long: longEnd - ratio * (points - used), longReset: longReset)
        }
    }
    private func assess(short: Double, shortIn: TimeInterval, long: Double, longIn: TimeInterval, hours: UsableHours = .all,
                        history customHistory: [AccountSnapshot]? = nil, age: TimeInterval = 0) -> [WeeklyReach] {
        let shortReset = now.addingTimeInterval(shortIn), longReset = now.addingTimeInterval(longIn)
        let current = snapshot(at: now.addingTimeInterval(-age), short: short, shortReset: shortReset, long: long, longReset: longReset)
        let samples = customHistory ?? history(longEnd: long, longReset: longReset, shortReset: shortReset)
        return WeeklyReach.assess(snapshot: current, history: samples, hours: hours, now: now, calendar: calendar)
    }

    func testReportedCaseExpiresWhatTheRemainingWindowCannotReach() throws {
        // 17 % weekly left in 3 h 19 min; 56 % of the 5 h window left for 4 h 49 min; one window ≈ 10 % of the week.
        let reach = try XCTUnwrap(assess(short: 44, shortIn: 4 * 3600 + 49 * 60, long: 83, longIn: 3 * 3600 + 19 * 60).first)
        XCTAssertEqual(reach.ratio, 0.1, accuracy: 1e-9)
        XCTAssertEqual(reach.windowsAvailable, 0.56, accuracy: 1e-9)
        XCTAssertEqual(reach.capacity, 5.6, accuracy: 1e-9)
        XCTAssertEqual(reach.expiring, 11.4, accuracy: 1e-9)
        XCTAssertEqual(reach.targetRemainingShort, 0)
        XCTAssertTrue(reach.isRelevant)
        XCTAssertEqual(WeeklyReach.shortTarget(in: [reach]), reach)
        XCTAssertEqual(WeeklyReach.relevant(for: "seven_day", in: [reach]), reach)
    }
    func testTightWeekSetsTargetOnTheShortWindow() throws {
        // 60 % left now plus windows at +1 h and +6 h, the second counting 3/5 until the reset at +9 h.
        let reach = try XCTUnwrap(assess(short: 40, shortIn: 3600, long: 80, longIn: 9 * 3600).first)
        XCTAssertEqual(reach.windowsAvailable, 2.2, accuracy: 1e-9)
        XCTAssertEqual(reach.capacity, 22, accuracy: 1e-9)
        XCTAssertEqual(reach.expiring, 0)
        XCTAssertEqual(reach.load, 20.0 / 22, accuracy: 1e-9)
        XCTAssertEqual(reach.windowsNeeded, 2, accuracy: 1e-9)
        XCTAssertEqual(reach.targetRemainingShort, 60 * (1 - 20.0 / 22), accuracy: 1e-9)
        XCTAssertTrue(reach.isRelevant)
    }
    func testComfortableWeekStaysQuiet() throws {
        let reach = try XCTUnwrap(assess(short: 40, shortIn: 3600, long: 50, longIn: 3 * 86400).first)
        XCTAssertFalse(reach.isRelevant)
        XCTAssertNil(WeeklyReach.shortTarget(in: [reach]))
        XCTAssertNil(WeeklyReach.relevant(for: "five_hour", in: [reach]))
    }
    func testFutureWindowsWaitForTheNextUsableHour() {
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: 20))!
        let end = start.addingTimeInterval(24 * 3600)
        let daytime = UsableHours(Set(8..<22))
        // 20:00 and 01:00 would follow back to back; 01:00 is quiet, so the next starts at 08:00, then 13:00 and 18:00 (2/5 until 20:00).
        XCTAssertEqual(WeeklyReach.futureWindows(from: start, until: end, duration: 18000, hours: daytime, calendar: calendar), 3.4, accuracy: 1e-9)
        XCTAssertEqual(WeeklyReach.futureWindows(from: start, until: end, duration: 18000, hours: .all, calendar: calendar), 4.8, accuracy: 1e-9)
        XCTAssertEqual(WeeklyReach.futureWindows(from: start, until: end, duration: 18000, hours: UsableHours([]), calendar: calendar), 0)
        XCTAssertEqual(WeeklyReach.futureWindows(from: end, until: start, duration: 18000, hours: .all, calendar: calendar), 0)
    }
    func testRatioNeedsEnoughSamePeriodHistory() {
        let shortReset = now.addingTimeInterval(3600), longReset = now.addingTimeInterval(86400)
        XCTAssertTrue(assess(short: 50, shortIn: 3600, long: 90, longIn: 86400,
                             history: history(points: 50, longEnd: 90, longReset: longReset, shortReset: shortReset)).isEmpty, "50 short points are not enough")
        func run(from start: TimeInterval, short: (Double, Double), long: (Double, Double), shortReset: Date) -> [AccountSnapshot] {
            (0...8).map { step in
                let share = Double(step) / 8
                return snapshot(at: now.addingTimeInterval(start + Double(step) * 600), short: short.0 + (short.1 - short.0) * share,
                                shortReset: shortReset, long: long.0 + (long.1 - long.0) * share, longReset: longReset)
            }
        }
        // The pair across the short reset (40 → 50 short, 86 → 91 long) belongs to two periods and must not count.
        let samples = run(from: -12000, short: (0, 40), long: (82, 86), shortReset: now.addingTimeInterval(-6600))
            + run(from: -4800, short: (50, 90), long: (91, 95), shortReset: shortReset)
        let reach = assess(short: 90, shortIn: 3600, long: 95, longIn: 86400, history: samples)
        XCTAssertEqual(reach.first?.ratio ?? 0, 0.1, accuracy: 1e-9)
        let otherLogin = history(longEnd: 90, longReset: longReset, shortReset: shortReset).map { var s = $0; s.identity = "other"; return s }
        XCTAssertTrue(assess(short: 80, shortIn: 3600, long: 90, longIn: 86400, history: otherLogin).isEmpty)
        let old = history(longEnd: 90, longReset: longReset, shortReset: shortReset).map { var s = $0; s.observedAt -= 15 * 86400; return s }
        XCTAssertTrue(assess(short: 80, shortIn: 3600, long: 90, longIn: 86400, history: old).isEmpty)
    }
    func testRoundedLongTicksWithoutShortChangeStillCount() {
        let samples = [(0.0, 50.0), (30, 52), (30, 53), (60, 55), (90, 58)].enumerated().map { index, values in
            snapshot(at: now.addingTimeInterval(Double(index - 4) * 600), short: values.0, shortReset: now.addingTimeInterval(3600),
                     long: values.1, longReset: now.addingTimeInterval(86400))
        }
        XCTAssertEqual(WeeklyReach.ratio(shortID: "five_hour", longID: "seven_day", history: samples, now: now, minimumLongPoints: 3) ?? 0, 8.0 / 90, accuracy: 1e-9)
    }
    func testScopedWeekNeedsMoreEvidence() {
        let shortReset = now.addingTimeInterval(3600), longReset = now.addingTimeInterval(86400)
        func samples(fablePoints: Double) -> [AccountSnapshot] {
            history(longEnd: 90, longReset: longReset, shortReset: shortReset).enumerated().map { index, sample in
                var value = sample
                value.windows.append(QuotaWindow(id: "model.Fable", title: "Fable · Woche", usedPercent: 80 + fablePoints * Double(index) / 8,
                                                 resetsAt: longReset, duration: 604800))
                return value
            }
        }
        for (points, expected) in [(6.0, 1), (12.0, 2)] {
            let history = samples(fablePoints: points)
            let reaches = WeeklyReach.assess(snapshot: history.last!, history: history, hours: .all, now: now, calendar: calendar)
            XCTAssertEqual(reaches.map(\.longWindowID), Array(["seven_day", "model.Fable"].prefix(expected)))
        }
    }
    func testUnusableDataHidesTheEstimate() {
        XCTAssertTrue(assess(short: 64, shortIn: 3600, long: 83, longIn: 3600, age: 3600).isEmpty, "stale")
        XCTAssertTrue(assess(short: 64, shortIn: 3600, long: 83, longIn: -60).isEmpty, "long reset passed")
        XCTAssertTrue(assess(short: 64, shortIn: -60, long: 83, longIn: 3600).isEmpty, "short reset passed")
        let current = snapshot(at: now, short: 100, shortReset: nil, long: 83, longReset: now.addingTimeInterval(3600))
        XCTAssertTrue(WeeklyReach.assess(snapshot: current, history: [], hours: .all, now: now).isEmpty, "exhausted without reset")
    }
    func testExhaustedShortWindowCountsOnlyFutureWindows() throws {
        let longReset = now.addingTimeInterval(7 * 3600), shortReset = now.addingTimeInterval(2 * 3600)
        let reach = try XCTUnwrap(assess(short: 100, shortIn: 2 * 3600, long: 85, longIn: 7 * 3600,
                                         history: history(points: 100, longEnd: 85, longReset: longReset, shortReset: shortReset)).first)
        XCTAssertEqual(reach.windowsAvailable, 1, accuracy: 1e-9)
        XCTAssertEqual(reach.expiring, 5, accuracy: 1e-9)
    }

    func testLearnedHoursNeedSevenActiveDaysAndTwentyPercentShare() {
        let start = calendar.startOfDay(for: now)
        func day(_ offset: Int, _ hours: [Int], source: ActivitySource = .claude) -> ActivityHours {
            ActivityHours(day: start.addingTimeInterval(Double(-offset) * 86400), source: source, hours: hours.reduce(0) { $0 | 1 << $1 })
        }
        // Ten active days: 9 h every day, 20 h on two (20 %), 23 h on one (10 %).
        var days = (0..<10).map { day($0, [9] + ($0 < 2 ? [20] : []) + ($0 == 5 ? [23] : [])) }
        days += [day(1, [3], source: .codex), day(40, [4])]
        XCTAssertEqual(UsableHours.learned(from: days, source: .claude, now: now), UsableHours([9, 20]))
        XCTAssertNil(UsableHours.learned(from: Array(days.prefix(6)), source: .claude, now: now))
        XCTAssertNil(UsableHours.learned(from: days, source: .codex, now: now))
    }
    func testQuietHoursFallback() {
        var settings = MonitorSettings()
        XCTAssertEqual(UsableHours.resolve(activity: nil, source: .claude, settings: settings, now: now), UsableHours(Set(8..<22)))
        settings.quietStart = 1; settings.quietEnd = 6
        XCTAssertEqual(UsableHours.outsideQuietHours(settings), UsableHours(Set([0] + Array(6..<24))))
        settings.quietEnabled = false
        XCTAssertEqual(UsableHours.resolve(activity: nil, source: .claude, settings: settings, now: now), .all)
    }
    func testActivityReportRecordsRecentHours() throws {
        let start = calendar.startOfDay(for: now)
        let events = [ActivityEvent(id: "a", source: .claude, date: start.addingTimeInterval(9.5 * 3600 - 86400), model: "m", tokens: 10),
                      ActivityEvent(id: "b", source: .claude, date: start.addingTimeInterval(14.2 * 3600 - 86400), model: "m", tokens: 10),
                      ActivityEvent(id: "c", source: .claude, date: start.addingTimeInterval(-40 * 86400), model: "m", tokens: 10)]
        let report = ActivityReport(events: events, now: now, calendar: calendar)
        let hours = try XCTUnwrap(report.activeHours)
        XCTAssertEqual(hours, [ActivityHours(day: start.addingTimeInterval(-86400), source: .claude, hours: 1 << 9 | 1 << 14)])
        XCTAssertEqual(report.days.count, 2)
    }
    func testDemoShowsAnExpiringAndATightWeek() {
        let snapshots = DemoData.snapshots(now: now), activity = DemoData.activity(now: now)
        let reaches = snapshots.map { snapshot in
            let source: ActivitySource? = snapshot.configurationID == "demo-codex" ? .codex : snapshot.configurationID == "demo-claude" ? .claude : nil
            let hours = UsableHours.resolve(activity: activity, source: source, settings: MonitorSettings(), now: now)
            return WeeklyReach.assess(snapshot: snapshot, history: DemoData.history(for: snapshot, now: now), hours: hours, now: now).first
        }
        XCTAssertGreaterThanOrEqual(reaches[0]?.expiring ?? 0, 10)
        XCTAssertEqual(reaches[1]?.expiring, 0)
        XCTAssertTrue(reaches[1]?.isRelevant ?? false)
        XCTAssertNil(reaches[2])
    }
}
