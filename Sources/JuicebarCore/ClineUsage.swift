import Foundation

/// Cline SDK messages contract v1. Only a turn's terminal message carries metrics.
enum ClineUsage {
    static func event(_ record: [String: Any]) -> ActivityEvent? {
        guard record["role"] as? String == "assistant", let id = record["id"] as? String, !id.isEmpty,
              let timestamp = JSONValue.number(record["ts"]), timestamp > 0,
              let metrics = record["metrics"] as? [String: Any],
              let input = JSONValue.number(metrics["inputTokens"]), input >= 0,
              let output = JSONValue.number(metrics["outputTokens"]), output >= 0,
              input + output > 0 else { return nil }
        let read = JSONValue.number(metrics["cacheReadTokens"]) ?? 0, write = JSONValue.number(metrics["cacheWriteTokens"]) ?? 0
        let usage = TokenBreakdown(input: input - read - write, output: output, cacheRead: read, cacheWrite: write)
        let model = record["modelInfo"] as? [String: Any] ?? [:]
        return ActivityEvent(id: stableID(id), source: .cline, date: Date(timeIntervalSince1970: timestamp / 1000),
                             model: model["id"] as? String ?? tr("Unbekannt"), provider: model["provider"] as? String ?? "",
                             tokens: input + output, usage: usage.isValid ? usage : nil,
                             reportedCost: JSONValue.number(metrics["cost"]).flatMap { $0 >= 0 ? $0 : nil })
    }
}
