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
}
