import XCTest
@testable import JuicebarCore

final class WorkScheduleTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let schedule = WorkSchedule(isEnabled: true)
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var reset: Date { date("2026-11-04T13:00:00Z") }
    private func snapshot(_ time: Date, short: Double = 0, shortReset: Date? = nil, week: Double,
                          weekReset: Date? = nil, identity: String = "login") -> AccountSnapshot {
        AccountSnapshot(configurationID: "team", identity: identity, observedAt: time, source: "fixture", windows: [
            QuotaWindow(id: "five_hour", title: "5 Stunden", usedPercent: short, resetsAt: shortReset, duration: 18000),
            QuotaWindow(id: "seven_day", title: "Woche", usedPercent: week, resetsAt: weekReset ?? reset, duration: 604800)
        ])
    }
    private var training: [AccountSnapshot] {
        let shortReset = date("2026-10-27T14:00:00Z"), weekReset = date("2026-10-28T13:00:00Z")
        return [snapshot(date("2026-10-27T09:00:00Z"), short: 0, shortReset: shortReset, week: 30, weekReset: weekReset),
                snapshot(date("2026-10-27T10:00:00Z"), short: 100, shortReset: shortReset, week: 40, weekReset: weekReset)]
    }
    private func target(_ current: AccountSnapshot, history: [AccountSnapshot] = [], schedule: WorkSchedule? = nil) throws -> WorkPlanTarget {
        try XCTUnwrap(WorkPlanTarget.assess(snapshot: current, history: training + history, schedule: schedule ?? self.schedule,
                                          now: current.observedAt, calendar: calendar).first)
    }

    func testWorkdayTargetAndAdditionalUseMatchRemainingActualStarts() throws {
        let baseline = snapshot(date("2026-10-29T07:59:00Z"), week: 10)
        let current = snapshot(date("2026-10-29T11:00:00Z"), short: 80, shortReset: date("2026-10-29T13:00:00Z"), week: 18)
        let result = try target(current, history: [baseline, current])
        XCTAssertTrue(result.isWorkday)
        XCTAssertEqual(result.targetRemainingLong, 70, accuracy: 1e-9)
        XCTAssertEqual(result.todayRemaining, 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.targetRemainingShort), 0)
        XCTAssertEqual(try XCTUnwrap(result.additionalWindows), 1, accuracy: 1e-9)
    }
    func testDailyMarkerStopsAskingAfterTodaysAllocationWasConsumed() throws {
        let baseline = snapshot(date("2026-10-29T07:59:00Z"), week: 10)
        let current = snapshot(date("2026-10-29T13:10:00Z"), short: 100, shortReset: date("2026-10-29T18:00:00Z"), week: 30)
        let first = try target(snapshot(date("2026-10-29T11:00:00Z"), short: 80, shortReset: date("2026-10-29T13:00:00Z"), week: 18), history: [baseline])
        let done = try target(current, history: [baseline, current])
        XCTAssertEqual(done.targetRemainingLong, first.targetRemainingLong)
        XCTAssertEqual(done.todayRemaining, 0)
        let exceeded = try target(snapshot(current.observedAt.addingTimeInterval(60), short: 100, shortReset: current.windows[0].resetsAt, week: 35), history: [baseline, current])
        XCTAssertEqual(exceeded.targetRemainingLong, 70, accuracy: 1e-9)
        XCTAssertEqual(exceeded.todayRemaining, 0)
    }
    func testFreeWednesdayReservesFourRegularWorkdays() throws {
        let current = snapshot(date("2026-10-28T14:00:00Z"), week: 0)
        let result = try target(current)
        XCTAssertFalse(result.isWorkday)
        XCTAssertEqual(result.targetRemainingLong, 80, accuracy: 1e-9)
        XCTAssertEqual(result.todayRemaining, 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.targetRemainingShort), 0)
        XCTAssertEqual(try XCTUnwrap(result.additionalWindows), 2, accuracy: 1e-9)
    }
    func testFullShortWindowCanStillHaveNoDiscretionaryWeeklyBudget() throws {
        let current = snapshot(date("2026-10-28T23:00:00Z"), week: 20)
        let result = try target(current)
        XCTAssertFalse(result.isWorkday)
        XCTAssertEqual(result.targetRemainingLong, 80, accuracy: 1e-9)
        XCTAssertEqual(result.todayRemaining, 0)
        XCTAssertEqual(try XCTUnwrap(result.targetRemainingShort), 100)
        XCTAssertEqual(try XCTUnwrap(result.additionalWindows), 0)
    }
    func testPartlyUsedShortWindowDoesNotLookOnTargetWhenWeeklyReserveWasExceeded() throws {
        let current = snapshot(date("2026-10-30T19:55:00Z"), short: 50,
                               shortReset: date("2026-10-30T23:09:00Z"), week: 79)
        let result = try target(current)
        XCTAssertFalse(result.isWorkday)
        XCTAssertGreaterThan(result.targetRemainingLong, result.remainingLong)
        XCTAssertEqual(result.todayRemaining, 0)
        // The weekly reserve allows no use of this window, even though it is already half spent.
        XCTAssertEqual(try XCTUnwrap(result.targetRemainingShort), 100)
    }
    func testShortMarkerKeepsTheSameAllowanceWhenUsageCrossesTheWeeklyReserve() throws {
        let shortReset = date("2026-10-30T23:09:00Z")
        let before = try target(snapshot(date("2026-10-30T19:54:00Z"), short: 0, shortReset: shortReset, week: 56))
        let after = try target(snapshot(date("2026-10-30T19:55:00Z"), short: 50, shortReset: shortReset, week: 61))
        XCTAssertEqual(before.targetRemainingLong, after.targetRemainingLong)
        XCTAssertEqual(try XCTUnwrap(before.targetRemainingShort), 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(after.targetRemainingShort), 60, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(after.targetRemainingShort), 50)
    }
    func testRemainingWeekNeedsNoAdditionalTimeAfterEarlierUsage() throws {
        let current = snapshot(date("2026-10-29T19:00:00Z"), week: 52)
        let result = try target(current)
        XCTAssertFalse(result.isWorkday)
        XCTAssertEqual(result.targetRemainingLong, 60, accuracy: 1e-9)
        XCTAssertEqual(result.todayRemaining, 0)
        XCTAssertEqual(try XCTUnwrap(result.additionalWindows), 0)
    }
    func testShortResetDelaysTheNextRegularStartAndProviderResetWinsOverClockAssumptions() throws {
        let current = snapshot(date("2026-10-29T08:00:00Z"), short: 100, shortReset: date("2026-10-29T11:00:00Z"), week: 0)
        let result = try target(current, history: [current])
        // One Thursday start at 11, then two on Friday/Monday/Tuesday. The next 16:00 start is outside working hours.
        XCTAssertEqual(try XCTUnwrap(result.additionalWindows), 3, accuracy: 1e-9)
    }
    func testWeeklyOnlyQuotaUsesWorkingTimeWithoutInventingShortCapacity() throws {
        var baseline = snapshot(date("2026-10-29T07:59:00Z"), week: 40)
        baseline.windows.removeFirst()
        var current = snapshot(date("2026-10-29T10:00:00Z"), week: 45)
        current.windows.removeFirst()
        let result = try target(current, history: [baseline, current])
        XCTAssertEqual(result.targetRemainingLong, 45, accuracy: 1e-9)
        XCTAssertEqual(result.todayRemaining, 10, accuracy: 1e-9)
        XCTAssertNil(result.shortWindowID)
        XCTAssertNil(result.targetRemainingShort)
        XCTAssertNil(result.additionalWindows)
    }
    func testDisabledInvalidStaleAndDifferentLoginsDoNotInventAPlanOrRatio() throws {
        let now = date("2026-10-29T11:00:00Z"), current = snapshot(now, week: 40)
        XCTAssertTrue(WorkPlanTarget.assess(snapshot: current, history: training, schedule: WorkSchedule(), now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(WorkPlanTarget.assess(snapshot: current, history: training, schedule: WorkSchedule(isEnabled: true, weekdays: []), now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(WorkPlanTarget.assess(snapshot: current, history: training, schedule: schedule, now: now.addingTimeInterval(7200), calendar: calendar).isEmpty)
        let otherLogin = training.map { var s = $0; s.identity = "different"; return s }
        let fallback = try XCTUnwrap(WorkPlanTarget.assess(snapshot: current, history: otherLogin, schedule: schedule, now: now, calendar: calendar).first)
        XCTAssertNil(fallback.targetRemainingShort)
        XCTAssertNil(fallback.additionalWindows)
    }
    func testWorkingHoursSkipDaysAndKeepWallClockTimeAcrossDST() throws {
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let fridayEvening = date("2026-10-23T18:00:00Z"), end = date("2026-10-28T13:00:00Z")
        XCTAssertEqual(schedule.nextStart(from: fridayEvening, before: end, calendar: berlin), date("2026-10-26T07:00:00Z"))
        XCTAssertEqual(schedule.nextStart(from: date("2026-10-26T12:30:00Z"), before: end, calendar: berlin), date("2026-10-27T07:00:00Z"))
        let tuesday = try XCTUnwrap(schedule.interval(on: date("2026-10-27T12:00:00Z"), calendar: berlin))
        XCTAssertEqual(tuesday.end, date("2026-10-27T12:30:00Z"))
        XCTAssertNil(schedule.interval(on: date("2026-10-28T09:00:00Z"), calendar: berlin))
    }
    func testAccountMigrationAndSchedulePersistence() throws {
        var account = AccountConfiguration(id: "a", provider: .claude)
        let oldData = try JSONEncoder().encode(account)
        XCTAssertNil(try JSONDecoder().decode(AccountConfiguration.self, from: oldData).workSchedule)
        account.workSchedule = schedule
        let db = try HistoryDatabase(path: ":memory:")
        try db.write([account], key: "accounts")
        let restored = try XCTUnwrap(db.read([AccountConfiguration].self, key: "accounts")?.first)
        XCTAssertEqual(restored.workSchedule, schedule)
        XCTAssertNil(AccountConfiguration(id: "b", provider: .claude).workSchedule)
    }
}
