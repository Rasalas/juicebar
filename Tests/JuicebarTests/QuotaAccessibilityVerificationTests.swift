import XCTest
import JuicebarCore
@testable import Juicebar

final class QuotaAccessibilityVerificationTests: XCTestCase {
    private typealias Probe = QuotaAccessibilityVerification

    func testFixtureTitleMatchesExposedSemanticsInBothLanguages() {
        for (language, title) in [("en", "Week"), ("de", "Woche")] {
            let quota = Probe.fixture(now: Date(timeIntervalSince1970: 1_800_000_000), language: language)
            XCTAssertEqual(quota.title, title)
            // QuotaBar inserts the already localized model title into its AX label.
            let label = Localization.text("{0}, {1} Prozent {2}{3}",
                                          arguments: [quota.title, "50", "", ""], language: language)
            XCTAssertEqual(Probe.evaluate([.init(label: label, value: "12:00 pace")],
                                          title: title, reset: "12:00", pace: "pace"), .verified)
        }
    }

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
