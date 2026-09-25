import Foundation

/// Disjoint buckets. Output includes reasoning; cached input is excluded from input.
public struct TokenBreakdown: Codable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var cacheWriteHour: Double
    public init(input: Double, output: Double, cacheRead: Double = 0, cacheWrite: Double = 0, cacheWriteHour: Double = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.cacheWriteHour = cacheWriteHour
    }
    public var total: Double { input + output + cacheRead + cacheWrite + cacheWriteHour }
    public var isValid: Bool { [input, output, cacheRead, cacheWrite, cacheWriteHour].allSatisfy { $0.isFinite && $0 >= 0 } }
    static func codex(_ usage: [String: Any]) -> Self? {
        guard let input = JSONValue.number(usage["input_tokens"]), let output = JSONValue.number(usage["output_tokens"]) else { return nil }
        let read = JSONValue.number(usage["cached_input_tokens"]) ?? 0
        let write = JSONValue.number(usage["cache_write_input_tokens"]) ?? 0
        let result = Self(input: input - read - write, output: output, cacheRead: read, cacheWrite: write)
        return result.isValid ? result : nil
    }
    static func claude(_ usage: [String: Any]) -> Self? {
        guard let input = JSONValue.number(usage["input_tokens"]), let output = JSONValue.number(usage["output_tokens"]) else { return nil }
        let creation = usage["cache_creation"] as? [String: Any] ?? [:]
        let hour = JSONValue.number(creation["ephemeral_1h_input_tokens"]) ?? 0
        let write = JSONValue.number(usage["cache_creation_input_tokens"]) ?? 0
        let result = Self(input: input, output: output, cacheRead: JSONValue.number(usage["cache_read_input_tokens"]) ?? 0, cacheWrite: write - hour, cacheWriteHour: hour)
        return result.isValid ? result : nil
    }
    static func opencode(_ tokens: [String: Any]) -> Self? {
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        guard let input = JSONValue.number(tokens["input"]), let output = JSONValue.number(tokens["output"]) else { return nil }
        let result = Self(input: input, output: output + (JSONValue.number(tokens["reasoning"]) ?? 0), cacheRead: JSONValue.number(cache["read"]) ?? 0, cacheWrite: JSONValue.number(cache["write"]) ?? 0)
        return result.isValid ? result : nil
    }
}

/// Current standard list prices, USD / million tokens, verified 2026-09-25.
/// This compares equivalent API usage today, not historical invoices or subscription charges.
public enum APICost {
    public static var priceDate: String { ModelCatalog.shared.snapshot.verifiedOn }
    public static func estimate(model: String, provider: String = "", usage: TokenBreakdown?) -> Double? {
        guard let usage, usage.isValid else { return nil }
        // Resolve identities when pricing, including archived events from the preview period.
        let catalog = ModelCatalog.shared.snapshot
        let rates = catalog.rates
        let canonical = catalog.resolve(model: model, provider: provider)?.canonicalModel ?? model.lowercased()
        // The common case avoids running a regular expression for every logged response.
        let name = rates[canonical] != nil ? canonical : canonical.replacingOccurrences(of: #"-(?:\d{8}|\d{4}-\d{2}-\d{2})$"#, with: "", options: .regularExpression)
        guard let rate = rates[name] else { return nil }
        guard (usage.cacheWrite == 0 || rate.write > 0), (usage.cacheWriteHour == 0 || rate.hour > 0) else { return nil }
        let long = rate.longContext.map { usage.input + usage.cacheRead + usage.cacheWrite + usage.cacheWriteHour > $0 } ?? false
        let inputCost = usage.input * rate.input + usage.cacheRead * rate.read + usage.cacheWrite * rate.write + usage.cacheWriteHour * rate.hour
        return (inputCost * (long ? 2 : 1) + usage.output * rate.output * (long ? 1.5 : 1)) / 1_000_000
    }
}
