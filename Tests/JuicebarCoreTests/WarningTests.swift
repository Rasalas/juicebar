import XCTest
@testable import JuicebarCore

final class WarningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1800000000)
    func testResetTimestampJitterDoesNotRepeatThresholdWarning() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = MonitorSettings(); settings.paceEnabled = false; settings.forecastEnabled = false; settings.expiryEnabled = false
        let first = AccountSnapshot(configurationID: "a", identity: "a", observedAt: now, source: "test", windows: [QuotaWindow(id: "five_hour", title: "5 Stunden", usedPercent: 60, resetsAt: now.addingTimeInterval(3600.4), duration: 18000)])
        let sent = WarningEngine.events(snapshot: first, accountName: "Claude", history: [], settings: settings, sent: [], now: now)
        var second = first; second.windows[0].resetsAt = now.addingTimeInterval(3599.7)
        XCTAssertTrue(WarningEngine.events(snapshot: second, accountName: "Claude", history: [first], settings: settings, sent: Set(sent.map(\.id)), now: now).isEmpty)
    }
    func snapshot(percent: Double = 60, age: Double = 0, resetOffset: Double = 3600) -> AccountSnapshot {
        AccountSnapshot(configurationID: "a", identity: "login", observedAt: now.addingTimeInterval(-age), source: "fixture", windows: [.init(id: "w", title: "5h", usedPercent: percent, resetsAt: now.addingTimeInterval(resetOffset), duration: 18000)])
    }
    func events(_ snapshot: AccountSnapshot, sent: Set<String> = []) -> [WarningEvent] {
        WarningEngine.events(snapshot: snapshot, accountName: "Test", history: [], settings: MonitorSettings(), sent: sent, now: now)
    }
    func testThresholdOncePerWindowAndAgainAfterReset() {
        let first = events(snapshot())
        XCTAssertEqual(first.map(\.kind), [.threshold])
        XCTAssertTrue(events(snapshot(), sent: Set(first.map(\.id))).isEmpty)
        XCTAssertFalse(events(snapshot(resetOffset: 18000), sent: Set(first.map(\.id))).isEmpty)
    }
    func testOldOrExpiredMeasurementsNeverWarn() {
        XCTAssertTrue(events(snapshot(age: 400)).isEmpty)
        XCTAssertTrue(events(snapshot(resetOffset: -1)).isEmpty)
    }
    func testProjectionRequiresRecentMonotonicHistory() throws {
        let current = snapshot(percent: 80, resetOffset: 7200)
        let samples = [snapshot(percent: 60, age: 600, resetOffset: 7200), snapshot(percent: 70, age: 300, resetOffset: 7200)]
        let projection = try XCTUnwrap(WarningEngine.projection(window: current.windows[0], snapshot: current, history: samples, now: now))
        XCTAssertEqual(projection.percentPerHour, 120, accuracy: 0.01)
        XCTAssertEqual(projection.reachesLimitAt.timeIntervalSince(now), 600, accuracy: 0.01)
        XCTAssertNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: [], now: now))
        XCTAssertNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: [snapshot(percent: 90, age: 600, resetOffset: 7200), samples[1]], now: now))
    }
    func testProjectionRejectsAccountSwitchAndExhaustionAfterReset() {
        var current = snapshot(percent: 80, resetOffset: 300)
        let samples = [snapshot(percent: 60, age: 600, resetOffset: 300), snapshot(percent: 70, age: 300, resetOffset: 300)]
        XCTAssertNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: samples, now: now))
        current.identity = "other-login"
        XCTAssertNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: samples, now: now))
    }
    func testProjectionWeightsRecentIntervalsMoreHeavilyWithoutDependingOnPollCount() throws {
        let current = snapshot(percent: 40, resetOffset: 7200)
        let sparse = [snapshot(percent: 10, age: 1200, resetOffset: 7200), snapshot(percent: 30, age: 600, resetOffset: 7200)]
        let dense = sparse + [snapshot(percent: 20, age: 900, resetOffset: 7200), snapshot(percent: 35, age: 300, resetOffset: 7200)]
        for samples in [sparse, dense] {
            let projection = try XCTUnwrap(WarningEngine.projection(window: current.windows[0], snapshot: current, history: samples, now: now))
            // Recent ten minutes: 60 points/hour; preceding ten minutes: 120. Recent weight is twice as large.
            XCTAssertEqual(projection.percentPerHour, 80, accuracy: 0.01)
        }
        let accelerating = [snapshot(percent: 10, age: 1200, resetOffset: 7200), snapshot(percent: 20, age: 600, resetOffset: 7200)]
        let faster = try XCTUnwrap(WarningEngine.projection(window: current.windows[0], snapshot: current, history: accelerating, now: now))
        XCTAssertEqual(faster.percentPerHour, 100, accuracy: 0.01)
    }
    func testIdleMeasurementsReduceRateAndThenHideProjection() throws {
        let current = snapshot(percent: 80, resetOffset: 7200)
        let samples = [snapshot(percent: 60, age: 1200, resetOffset: 7200), snapshot(percent: 70, age: 900, resetOffset: 7200),
                       snapshot(percent: 80, age: 600, resetOffset: 7200), snapshot(percent: 80, age: 300, resetOffset: 7200)]
        let slowing = try XCTUnwrap(WarningEngine.projection(window: current.windows[0], snapshot: current, history: samples, now: now))
        XCTAssertEqual(slowing.percentPerHour, 40, accuracy: 0.01)
        let paused = samples.map { sample in var older = sample; older.observedAt.addTimeInterval(-60); return older }
        XCTAssertNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: paused, now: now))
        let yesterday = samples.map { sample in var older = sample; older.observedAt.addTimeInterval(-86400); return older }
        XCTAssertNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: yesterday, now: now))
    }
    func testProjectionRestartsAfterAGapInMeasurements() throws {
        let current = snapshot(percent: 80, resetOffset: 7200)
        let beforeGap = [snapshot(percent: 20, age: 1800, resetOffset: 7200), snapshot(percent: 30, age: 1500, resetOffset: 7200)]
        XCTAssertNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: beforeGap, now: now))
        let afterGap = [snapshot(percent: 60, age: 600, resetOffset: 7200), snapshot(percent: 70, age: 300, resetOffset: 7200)]
        let resumed = try XCTUnwrap(WarningEngine.projection(window: current.windows[0], snapshot: current, history: beforeGap + afterGap, now: now))
        XCTAssertEqual(resumed.percentPerHour, 120, accuracy: 0.01)
    }
    func testExpiryMostUrgentStageAndManualOffline() {
        var s = snapshot(age: 1000); s.windows = []
        s.benefits = [.init(id: "r", title: "Reset", scope: "week", expiresAt: now.addingTimeInterval(7200), isManual: true)]
        let warning = events(s)
        XCTAssertEqual(warning.map(\.kind), [.expiry])
        XCTAssertTrue(events(s, sent: Set(warning.map(\.id))).isEmpty)
        s.identity = "new-login"
        XCTAssertTrue(events(s, sent: Set(warning.map(\.id))).isEmpty)
        s.benefits[0].isManual = false; s.benefitsChecked = true
        XCTAssertTrue(events(s).isEmpty)
        s.observedAt = now; s.benefits[0].expiresAt = nil
        XCTAssertTrue(events(s).isEmpty)
    }
    func testQuietHoursCrossMidnightAndSnooze() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var settings = MonitorSettings()
        let day = calendar.startOfDay(for: now)
        XCTAssertTrue(settings.isQuiet(at: day.addingTimeInterval(23 * 3600), calendar: calendar))
        XCTAssertTrue(settings.isQuiet(at: day.addingTimeInterval(7 * 3600), calendar: calendar))
        XCTAssertFalse(settings.isQuiet(at: day.addingTimeInterval(12 * 3600), calendar: calendar))
        settings.snoozedUntil = day.addingTimeInterval(13 * 3600)
        XCTAssertTrue(settings.isQuiet(at: day.addingTimeInterval(12 * 3600), calendar: calendar))
    }
}
