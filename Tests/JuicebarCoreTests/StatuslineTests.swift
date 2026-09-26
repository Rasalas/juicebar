import XCTest
@testable import JuicebarCore

final class StatuslineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testExportsOnlyValidatedQuotaFields() throws {
        let raw: [String: Any] = ["session_id": "private-session", "transcript_path": "/private/chat", "token": "secret",
            "rate_limits": ["five_hour": ["used_percentage": 42.0, "resets_at": now.timeIntervalSince1970 + 3600],
                            "seven_day": ["used_percentage": 65, "resets_at": now.timeIntervalSince1970 + 86400],
                            "unknown": ["secret": "do-not-copy"]]]
        let observation = try XCTUnwrap(ClaudeStatuslineObservation.capture(JSONSerialization.data(withJSONObject: raw), now: now))
        XCTAssertEqual(observation.windows.count, 2)
        let encoded = try observation.encoded()
        let string = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["private", "secret", "transcript", "session", "unknown"] { XCTAssertFalse(string.contains(forbidden)) }
        let restored = try ClaudeStatuslineObservation.read(encoded, now: now)
        XCTAssertEqual(restored, observation)
        XCTAssertEqual(restored.activeWindows(at: now.addingTimeInterval(3601)).count, 1)
        XCTAssertTrue(restored.activeWindows(at: now.addingTimeInterval(86401)).isEmpty)
    }

    func testMissingOrMalformedQuotasDoNotEraseLastObservation() throws {
        XCTAssertNil(try ClaudeStatuslineObservation.capture(Data("{}".utf8), now: now))
        for used: Any in [true, -1, 101, "50"] {
            let data = try JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": used, "resets_at": now.timeIntervalSince1970 + 60]]])
            XCTAssertNil(try ClaudeStatuslineObservation.capture(data, now: now))
        }
        for reset in [now.timeIntervalSince1970 - 1, now.timeIntervalSince1970 + 86400] {
            let data = try JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": 50, "resets_at": reset]]])
            XCTAssertNil(try ClaudeStatuslineObservation.capture(data, now: now))
        }
        XCTAssertThrowsError(try ClaudeStatuslineObservation.capture(Data(repeating: 32, count: 262_145), now: now))
    }
}
