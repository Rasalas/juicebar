import XCTest
@testable import JuicebarCore

final class ParsingTests: XCTestCase {
    func testCostUnitsAndUnknownCurrency() throws {
        XCTAssertEqual(try ProviderParsing.costBucket(["results": [["amount": "1234", "currency": "USD"]]], provider: .anthropicAPI), 12.34, accuracy: 0.001)
        XCTAssertEqual(try ProviderParsing.costBucket(["results": [["amount": ["value": 12.34, "currency": "usd"]]]], provider: .openaiAPI), 12.34, accuracy: 0.001)
        XCTAssertThrowsError(try ProviderParsing.costBucket(["results": [["amount": "1234", "currency": "EUR"]]], provider: .anthropicAPI))
        XCTAssertThrowsError(try ProviderParsing.costBucket([:], provider: .openaiAPI))
    }
    func testCodexPrimaryCanBeWeekAndUnknownInventoryDatesStayUnknown() throws {
        let payload: [String: Any] = ["accountId": "a", "rateLimits": ["primary": ["usedPercent": 0.5, "windowDurationMins": 10080, "resetsAt": 1900000000]], "rateLimitResetCredits": ["availableCount": 3, "credits": [["id": "r", "status": "available", "expiresAt": NSNull()]]]]
        let snapshot = try ProviderParsing.codex(payload, configuration: .init(provider: .codex))
        XCTAssertEqual(snapshot.windows.first?.title, "Woche")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 0.5)
        XCTAssertEqual(snapshot.benefitCount, 3)
        XCTAssertEqual(snapshot.benefits.count, 1)
        XCTAssertNil(snapshot.benefits.first?.expiresAt)
    }
    func testBooleanIsNotPercentage() {
        XCTAssertNil(JSONValue.number(true))
        XCTAssertNil(JSONValue.number(Double.infinity))
        XCTAssertThrowsError(try ProviderParsing.codex(["rateLimits": ["primary": ["usedPercent": true]]], configuration: .init(provider: .codex)))
    }
    func testClaudeDiscoversNewWindowsWithoutInventingDuration() throws {
        let payload: [String: Any] = ["rate_limits": ["five_hour": ["utilization": 22, "resets_at": NSNull()], "future_model": ["utilization": 12, "resets_at": "2030-01-01T00:00:00Z"], "extra_usage": ["utilization": 50, "resets_at": "2030-01-01T00:00:00Z"]]]
        let snapshot = try ProviderParsing.claude(payload, configuration: .init(provider: .claude))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertNil(snapshot.windows.first(where: { $0.id == "five_hour" })?.resetsAt)
        XCTAssertFalse(snapshot.windows.first(where: { $0.id == "future_model" })!.supportsPace)
    }
    func testClaudeResetStates() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let result = ProviderParsing.claudeBenefits(["cedar_ember": ["grants": [
            ["id": "available", "resets_left": 2, "ends_at": 1900000000, "usable_now": true],
            ["id": "paused", "resets_left": 3, "ends_at": 1900000000, "paused": true],
            ["id": "expired", "resets_left": 1, "ends_at": 1700000000],
            ["id": "used", "resets_left": 0]
        ]]], now: now)!
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.benefits.map(\.status), [.available, .paused, .expired, .used])
    }
    func testGoPercentIsNotFractionAndRollingHasNoPace() throws {
        let snapshot = try ProviderParsing.openCodeGo(["usage": ["rolling": ["percent": 0.5], "weekly": ["percent": 57]]], configuration: .init(provider: .opencodeGo), identity: "a")
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "rolling" })?.usedPercent, 0.5)
        XCTAssertFalse(snapshot.windows.first(where: { $0.id == "rolling" })!.supportsPace)
        XCTAssertTrue(snapshot.windows.first(where: { $0.id == "weekly" })!.supportsPace)
    }
    func testSchemaBreakIsErrorNotZero() {
        XCTAssertThrowsError(try ProviderParsing.claude(["new_shape": [:]], configuration: .init(provider: .claude)))
        XCTAssertThrowsError(try ProviderParsing.openCodeGo(["usage": ["weekly": ["percent": "unknown"]]], configuration: .init(provider: .opencodeGo), identity: "a"))
    }
    func testPlanMultipliersUseProviderMetadata() throws {
        XCTAssertEqual(PlanLabels.codex("pro"), "Pro 20×")
        XCTAssertEqual(PlanLabels.codex("prolite"), "Pro 5×")
        XCTAssertEqual(PlanLabels.codex("plus"), "Plus")
        XCTAssertEqual(PlanLabels.codex("future_tier"), "Future Tier")
        XCTAssertEqual(PlanLabels.claude("max", tier: "default_claude_max_20x"), "Max 20×")
        XCTAssertEqual(PlanLabels.claude("max", tier: "default_claude_max_5x"), "Max 5×")
        XCTAssertEqual(PlanLabels.claude("pro", tier: "default_claude_max_20x"), "Pro")
        XCTAssertEqual(PlanLabels.claude("max", tier: "custom"), "Max")
        XCTAssertEqual(PlanLabels.claude("Max 20×", tier: nil), "Max 20×")
    }
    func testNimbusIsExcludedWithoutDisablingNewLimitDiscovery() throws {
        let payload: [String: Any] = ["rate_limits": [
            "five_hour": ["utilization": 22, "resets_at": NSNull()],
            "nimbus_quill": ["utilization": 0, "resets_at": NSNull()],
            "future_limit": ["utilization": 12, "resets_at": NSNull()]
        ]]
        let snapshot = try ProviderParsing.claude(payload, configuration: .init(provider: .claude))
        XCTAssertEqual(Set(snapshot.windows.map(\.id)), ["five_hour", "future_limit"])
        let cached = snapshot.windows + [QuotaWindow(id: "nimbus_quill", title: "Nimbus Quill", usedPercent: 0)]
        XCTAssertEqual(QuotaOrder.visibleWindows(cached, provider: .claude).count, 2)
    }

}
