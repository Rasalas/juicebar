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
    public static let priceDate = "25.09.2026"
    private struct Rate {
        var input: Double; var output: Double; var read: Double; var write: Double; var hour: Double
        var longContext: Double?
    }
    private static let rates: [String: Rate] = {
        var result: [String: Rate] = [:]
        func openai(_ model: String, _ input: Double, _ output: Double, _ read: Double, long: Bool = true, writes: Bool = true) {
            result[model] = Rate(input: input, output: output, read: read, write: writes ? input * 1.25 : input, hour: input * 1.25, longContext: long ? 272_000 : nil)
        }
        openai("gpt-6-astra", 10, 50, 1)
        openai("gpt-6-sol", 2, 10, 0.2)
        openai("gpt-6-luna", 0.1, 0.5, 0.01)
        openai("gpt-5.6-sol", 4, 20, 0.4)
        openai("gpt-5.6", 4, 20, 0.4)
        openai("gpt-5.6-terra", 2, 12, 0.2)
        openai("gpt-5.6-luna", 0.2, 1.2, 0.02)
        openai("gpt-5.5", 5, 30, 0.5, writes: false)
        openai("gpt-5.4", 2.5, 15, 0.25, writes: false)
        openai("gpt-5.4-mini", 0.75, 4.5, 0.075, long: false, writes: false)
        openai("gpt-5.2", 1.75, 14, 0.175, long: false, writes: false)
        openai("gpt-5.2-codex", 1.75, 14, 0.175, long: false, writes: false)
        openai("gpt-5.3-codex", 1.75, 14, 0.175, long: false, writes: false)
        func claude(_ models: [String], _ input: Double, _ output: Double, _ read: Double) {
            for model in models { result[model] = Rate(input: input, output: output, read: read, write: input * 1.25, hour: input * 2, longContext: nil) }
        }
        claude(["claude-fable-5-1"], 10, 50, 0.25)
        claude(["claude-fable-5"], 10, 50, 1)
        claude(["claude-opus-5-5"], 4, 20, 0.2)
        claude(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], 5, 25, 0.5)
        claude(["claude-opus-4-1", "claude-opus-4"], 15, 75, 1.5)
        claude(["claude-sonnet-5"], 2, 10, 0.2)
        claude(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4"], 3, 15, 0.3)
        claude(["claude-haiku-4-5"], 1, 5, 0.1)
        claude(["claude-3-5-haiku", "claude-haiku-3-5"], 0.8, 4, 0.08)
        // OpenCode Zen list prices for Go models that also have a public API price.
        for (model, input, output, read) in [
            ("glm-5.3-flash", 0.15, 0.5, 0.03), ("glm-5.3", 1.4, 4.4, 0.26),
            ("glm-5.2", 1.4, 4.4, 0.26), ("glm-5.1", 1.4, 4.4, 0.26), ("glm-5", 1.0, 3.2, 0.2),
            ("deepseek-v4.1-flash", 0.3, 1.2, 0.006), ("deepseek-v4-flash", 0.14, 0.28, 0.028),
            ("minimax-m3", 0.3, 1.2, 0.06), ("minimax-m2.7", 0.3, 1.2, 0.06), ("minimax-m2.5", 0.3, 1.2, 0.06),
            ("kimi-k2.5", 0.6, 3.0, 0.1), ("kimi-k2.6", 0.95, 4.0, 0.16), ("kimi-k2.7-code", 0.95, 4.0, 0.19)
        ] { result[model] = Rate(input: input, output: output, read: read, write: input, hour: input, longContext: nil) }
        // Unbiased's published direct offering on OpenRouter. No cache-write tariff is published.
        result["pareto"] = Rate(input: 2.5, output: 7.5, read: 0.25, write: 0, hour: 0, longContext: nil)
        result["claude-sonnet-4-5"]?.longContext = 200_000
        result["claude-sonnet-4"]?.longContext = 200_000
        return result
    }()
    public static func estimate(model: String, provider: String = "", usage: TokenBreakdown?) -> Double? {
        guard let usage, usage.isValid else { return nil }
        // Resolve identities when pricing, including archived events from the preview period.
        let canonical = ModelAliases.resolve(model: model, provider: provider)?.canonicalModel ?? model.lowercased()
        // The common case avoids running a regular expression for every logged response.
        let name = rates[canonical] != nil ? canonical : canonical.replacingOccurrences(of: #"-(?:\d{8}|\d{4}-\d{2}-\d{2})$"#, with: "", options: .regularExpression)
        guard let rate = rates[name] else { return nil }
        guard (usage.cacheWrite == 0 || rate.write > 0), (usage.cacheWriteHour == 0 || rate.hour > 0) else { return nil }
        let long = rate.longContext.map { usage.input + usage.cacheRead + usage.cacheWrite + usage.cacheWriteHour > $0 } ?? false
        let inputCost = usage.input * rate.input + usage.cacheRead * rate.read + usage.cacheWrite * rate.write + usage.cacheWriteHour * rate.hour
        return (inputCost * (long ? 2 : 1) + usage.output * rate.output * (long ? 1.5 : 1)) / 1_000_000
    }
}
