import Foundation

enum QwenUsage {
    static func event(_ record: [String: Any]) -> ActivityEvent? {
        guard record["type"] as? String == "assistant", let id = record["uuid"] as? String, !id.isEmpty,
              let date = JSONValue.date(record["timestamp"]), let tokens = record["usageMetadata"] as? [String: Any],
              let input = JSONValue.number(tokens["promptTokenCount"]), input >= 0,
              let output = JSONValue.number(tokens["candidatesTokenCount"]), output >= 0,
              input + output > 0 else { return nil }
        let read = JSONValue.number(tokens["cachedContentTokenCount"]) ?? 0
        // Qwen's OpenAI converter already includes reasoning in candidatesTokenCount.
        let usage = TokenBreakdown(input: input - read, output: output, cacheRead: read)
        return ActivityEvent(id: stableID(id), source: .qwen, date: date,
                             model: record["model"] as? String ?? tr("Unbekannt"),
                             tokens: input + output, usage: usage.isValid ? usage : nil)
    }
}
