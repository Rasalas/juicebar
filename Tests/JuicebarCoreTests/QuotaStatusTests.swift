import XCTest
@testable import JuicebarCore

final class QuotaStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(used: Double, age: TimeInterval = 0, reset: TimeInterval = 38100,
                          duration: TimeInterval? = 604800, supportsPace: Bool = true) -> AccountSnapshot {
        AccountSnapshot(configurationID: "codex", identity: "login", observedAt: now.addingTimeInterval(-age), source: "fixture",
                        windows: [QuotaWindow(id: "week", title: "Woche", usedPercent: used,
                                              resetsAt: now.addingTimeInterval(reset), duration: duration, supportsPace: supportsPace)])
    }
    private func status(_ snapshot: AccountSnapshot, history: [AccountSnapshot] = [], hasFailure: Bool = false) -> QuotaStatus {
        QuotaStatus.assess(window: snapshot.windows[0], snapshot: snapshot, history: history, now: now, hasFailure: hasFailure)
    }
    func testQuotaBalanceAloneDoesNotProduceAHint() {
        XCTAssertEqual(status(snapshot(used: 90)), .unavailable)
        XCTAssertEqual(status(snapshot(used: 95)), .unavailable)
        XCTAssertEqual(status(snapshot(used: 100)), .exhausted)
    }
    func testMissingHistoryOrTimingDoesNotProduceAPrediction() {
        XCTAssertEqual(status(snapshot(used: 55, reset: 302400)), .unavailable)
        XCTAssertEqual(status(snapshot(used: 56, reset: 302400)), .unavailable)
        XCTAssertEqual(status(snapshot(used: 90, reset: 600000)), .unavailable)
        XCTAssertEqual(status(snapshot(used: 90, duration: nil)), .unavailable)
        XCTAssertEqual(status(snapshot(used: 90, supportsPace: false)), .unavailable)
        XCTAssertEqual(status(snapshot(used: 100, supportsPace: false)), .exhausted)
    }
    func testStaleFailedAndExpiredDataCannotDescribeCurrentHealth() {
        for used: Double in [90, 100] {
            XCTAssertEqual(status(snapshot(used: used, age: 400)), .unavailable)
            XCTAssertEqual(status(snapshot(used: used, reset: 0)), .unavailable)
            XCTAssertEqual(status(snapshot(used: used), hasFailure: true), .unavailable)
        }
    }
    func testRecentConsumptionOverridesReassuringWindowAverage() {
        let current = snapshot(used: 90)
        let history = [snapshot(used: 70, age: 600), snapshot(used: 80, age: 300)]
        guard case .projectedExhaustion(let date) = status(current, history: history) else {
            return XCTFail("Recent consumption should warn even while remaining quota is above the steady-usage marker")
        }
        XCTAssertEqual(date.timeIntervalSince(now), 300, accuracy: 0.01)
        XCTAssertEqual(status(current, history: Array(history.suffix(1))), .unavailable)
        var otherLogin = history
        for index in otherLogin.indices { otherLogin[index].identity = "other" }
        XCTAssertEqual(status(current, history: otherLogin), .unavailable)
        XCTAssertEqual(status(snapshot(used: 90, age: 400), history: history), .unavailable)
    }
    func testSlowConsumptionDoesNotExtrapolateDaysFromRecentActivity() {
        let current = snapshot(used: 90, reset: 302400)
        let history = [snapshot(used: 89.5, age: 600, reset: 302400), snapshot(used: 89.75, age: 300, reset: 302400)]
        XCTAssertNotNil(WarningEngine.projection(window: current.windows[0], snapshot: current, history: history, now: now))
        XCTAssertEqual(status(current, history: history), .unavailable)
    }
    private func movingTargetScenario(used: Double = 30, rate: Double) -> (AccountSnapshot, [AccountSnapshot]) {
        // Ten-hour window, four hours elapsed: target = 40%, target speed = 10 points/hour.
        let current = snapshot(used: used, reset: 21600, duration: 36000)
        let history = [600.0, 300.0].map { age in
            snapshot(used: used - rate * age / 3600, age: age, reset: 21600, duration: 36000)
        }
        return (current, history)
    }
    func testPacePredictionCatchesMovingTargetRatherThanCurrentMarkerPosition() {
        let (current, history) = movingTargetScenario(rate: 34)
        guard case .projectedPaceCrossing(let date) = status(current, history: history) else {
            return XCTFail("A shrinking ten-point cushion should produce a target countdown")
        }
        // 10 / (34 - 10) hours = 25 minutes. Treating the marker as fixed would predict 17.6 minutes.
        XCTAssertEqual(date.timeIntervalSince(now), 25 * 60, accuracy: 0.01)
        let futureUsage = current.windows[0].usedPercent + 34 * date.timeIntervalSince(now) / 3600
        XCTAssertEqual(futureUsage, current.windows[0].idealPercent(at: date)!, accuracy: 0.001)
        XCTAssertEqual(status(current, history: Array(history.prefix(1))), .unavailable)
        XCTAssertEqual(status(current, history: history, hasFailure: true), .unavailable)
    }
    func testStableGrowingOrDistantHeadroomDoesNotProduceACountdown() {
        // Includes no use, slower/equal pace, no crossing before reset, and crossing beyond two hours.
        for rate: Double in [0, 5, 10, 11, 12] {
            let (current, history) = movingTargetScenario(rate: rate)
            XCTAssertEqual(status(current, history: history), .unavailable, "Rate: \(rate)")
        }
    }
    func testAlreadyAtOrAboveTargetDoesNotPredictASecondCrossing() {
        for used: Double in [40, 55] {
            let (current, history) = movingTargetScenario(used: used, rate: 20)
            XCTAssertEqual(status(current, history: history), .unavailable)
        }
    }
    func testImminentLimitTakesPriorityOverEarlierTargetCrossing() {
        let (current, history) = movingTargetScenario(rate: 40)
        guard case .projectedExhaustion(let date) = status(current, history: history) else {
            return XCTFail("The limit warning should take priority when both events fall within two hours")
        }
        XCTAssertEqual(date.timeIntervalSince(now), 105 * 60, accuracy: 0.01)
    }
}
