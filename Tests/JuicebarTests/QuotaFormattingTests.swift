import XCTest
import JuicebarCore
@testable import Juicebar

final class QuotaFormattingTests: XCTestCase {
    func testUnrepresentableDatesHaveUnknownLabels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for value in [1e100, -1e100, Double.infinity, -.infinity, .nan] {
            let date = Date(timeIntervalSince1970: value)
            XCTAssertEqual(pointInTime(date), tr("unbekannt"))
            XCTAssertEqual(updatedText(date, now: now), tr("unbekannt"))
        }
        XCTAssertEqual(relativeTime(Date(timeIntervalSince1970: 1e100), now: now), tr("in {0}", tr("unbekannt")))
    }
}
