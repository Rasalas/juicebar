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
        XCTAssertEqual(snapshot.windows.first?.title, tr("Woche"))
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
    func testClaudeIgnoresUnrecognizedQuotaFields() throws {
        let payload: [String: Any] = ["rate_limits": [
            "five_hour": ["utilization": 3, "resets_at": NSNull()],
            "seven_day": ["utilization": 96, "resets_at": "2030-01-01T00:00:00Z"],
            "iguana_necktie": ["utilization": 0, "resets_at": NSNull()],
            "nimbus_quill": ["utilization": 0, "resets_at": NSNull()],
            "future_internal": ["utilization": 12, "resets_at": "2030-01-01T00:00:00Z"],
            "extra_usage": ["utilization": 50, "resets_at": "2030-01-01T00:00:00Z"],
            "model_scoped": [["display_name": "Fable", "utilization": 32, "resets_at": "2030-01-01T00:00:00Z"]]
        ]]
        let snapshot = try ProviderParsing.claude(payload, configuration: .init(provider: .claude))
        XCTAssertEqual(Set(snapshot.windows.map(\.id)), ["five_hour", "seven_day", "model.Fable"])
        XCTAssertNil(snapshot.windows.first(where: { $0.id == "five_hour" })?.resetsAt)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "seven_day" })?.usedPercent, 96)
    }
    func testClaudeDoesNotClaimAutomaticResetInventory() throws {
        let snapshot = try ProviderParsing.claude(["rate_limits": ["five_hour": ["utilization": 22, "resets_at": NSNull()]]], configuration: .init(provider: .claude))
        XCTAssertFalse(snapshot.benefitsChecked)
        XCTAssertNil(snapshot.benefitCount)
        XCTAssertTrue(snapshot.benefits.isEmpty)
        XCTAssertNotNil(snapshot.notice)
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
    func testClaudeFiltersCachedInternalRowsAndRetainsSupportedWindows() throws {
        let supported = ["five_hour", "seven_day", "seven_day_oauth_apps", "seven_day_opus", "seven_day_sonnet"]
        let limits = Dictionary(uniqueKeysWithValues: supported.map { ($0, ["utilization": 0, "resets_at": NSNull()] as [String: Any]) })
        let snapshot = try ProviderParsing.claude(["rate_limits": limits], configuration: .init(provider: .claude))
        XCTAssertEqual(Set(snapshot.windows.map(\.id)), Set(supported))
        let cached = snapshot.windows + ["nimbus_quill", "iguana_necktie", "future_internal", "model.Fable"].map {
            QuotaWindow(id: $0, title: $0, usedPercent: 0)
        }
        XCTAssertEqual(Set(QuotaOrder.visibleWindows(cached, provider: .claude).map(\.id)), Set(supported + ["model.Fable"]))
        XCTAssertEqual(QuotaOrder.visibleWindows(cached, provider: .codex).count, cached.count)
        XCTAssertThrowsError(try ProviderParsing.claude(["rate_limits": ["iguana_necktie": ["utilization": 0, "resets_at": NSNull()]]], configuration: .init(provider: .claude)))
    }
}
