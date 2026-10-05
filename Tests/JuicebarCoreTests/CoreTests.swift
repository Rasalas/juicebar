import XCTest
@testable import JuicebarCore

final class CoreTests: XCTestCase {
    func testPaceUsesActualWindowDuration() {
        let now = Date()
        let week = QuotaWindow(id: "week", title: "Woche", usedPercent: 30, resetsAt: now.addingTimeInterval(3.5 * 86400), duration: 7 * 86400)
        XCTAssertEqual(week.idealPercent(at: now), 50)
        var rolling = week; rolling.supportsPace = false
        XCTAssertNil(rolling.idealPercent(at: now))
    }
    func testPaceRecoveryOnlyWhenAheadOfTarget() {
        let now = Date()
        var week = QuotaWindow(id: "week", title: "Woche", usedPercent: 75, resetsAt: now.addingTimeInterval(3.5 * 86400), duration: 7 * 86400)
        let recovery = week.paceRecovery(at: now)!
        XCTAssertEqual(recovery.timeIntervalSince(now), 1.75 * 86400, accuracy: 0.01)
        XCTAssertEqual(week.idealPercent(at: recovery)!, 75, accuracy: 0.001)
        week.usedPercent = 40
        XCTAssertNil(week.paceRecovery(at: now))
    }
}
