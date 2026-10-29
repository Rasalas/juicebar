import XCTest
@testable import Juicebar

final class QuotaAccessibilityVerificationTests: XCTestCase {
    private typealias Probe = QuotaAccessibilityVerification

    func testUnavailableTreeNeverReportsSuccess() {
        let result = Probe.evaluate([], title: "Week", reset: "12:00", pace: "Expected")
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(result.exitCode(strict: false), 2)
        XCTAssertEqual(result.exitCode(strict: true), 1)
        XCTAssertTrue(result.message.hasPrefix("UNAVAILABLE:"))
    }

    func testExposedButtonRequiresLabelResetAndPace() {
        for button in [Probe.Button(label: "", value: "12:00 Expected"),
                       .init(label: "Week, 20 percent", value: "12:00 Expected"),
                       .init(label: "Week, 50 percent", value: "Expected"),
                       .init(label: "Week, 50 percent", value: "12:00")] {
            let result = Probe.evaluate([button], title: "Week", reset: "12:00", pace: "Expected")
            XCTAssertEqual(result, .invalid)
            XCTAssertEqual(result.exitCode(strict: false), 1)
            XCTAssertEqual(result.exitCode(strict: true), 1)
        }
    }

    func testVerifiedSemanticsDoNotClaimVoiceOverInteraction() {
        let result = Probe.evaluate([.init(label: "Week, 50 percent remaining", value: "Reset 12:00. Expected 50")],
                                    title: "Week", reset: "12:00", pace: "Expected")
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(result.exitCode(strict: true), 0)
        XCTAssertTrue(result.message.contains("VoiceOver interaction remains unverified"))
    }
}
