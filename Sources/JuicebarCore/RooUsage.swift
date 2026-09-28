import Foundation

enum RooUsage {
    static func event(_ record: [String: Any], taskID: String) -> ActivityEvent? {
        guard record["type"] as? String == "say", record["say"] as? String == "api_req_started",
              let timestamp = JSONValue.number(record["ts"]), timestamp > 0,
              let text = record["text"] as? String,
              let data = text.data(using: .utf8), let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = JSONValue.number(usage["tokensIn"]), input >= 0,
              let output = JSONValue.number(usage["tokensOut"]), output >= 0,
              input + output > 0 else { return nil }
        // Roo's cost calculation normalizes tokensIn to include both cache buckets.
        let read = JSONValue.number(usage["cacheReads"]) ?? 0, write = JSONValue.number(usage["cacheWrites"]) ?? 0
        let breakdown = TokenBreakdown(input: input - read - write, output: output, cacheRead: read, cacheWrite: write)
        let cost = JSONValue.number(usage["cost"]).flatMap { $0 >= 0 ? $0 : nil }
        return ActivityEvent(id: stableID("\(taskID)|\(timestamp)"), source: .roo,
                             date: Date(timeIntervalSince1970: timestamp / 1000), model: tr("Unbekannt"),
                             tokens: input + output, usage: breakdown.isValid ? breakdown : nil, reportedCost: cost)
    }
}
