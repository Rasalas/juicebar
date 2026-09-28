import Foundation

/// Both legacy conversation JSON and append-only JSONL use the same message records.
enum GeminiUsage {
    static func events(_ record: [String: Any]) -> [ActivityEvent] {
        if let messages = record["messages"] as? [[String: Any]] { return messages.flatMap(events) }
        if let update = record["$set"] as? [String: Any], let messages = update["messages"] as? [[String: Any]] {
            return messages.flatMap(events)
        }
        // Rewinding the conversation does not undo usage already incurred.
        guard record["type"] as? String == "gemini", let id = record["id"] as? String, !id.isEmpty,
              let date = JSONValue.date(record["timestamp"]), let tokens = record["tokens"] as? [String: Any] else { return [] }
        let usage = TokenBreakdown.gemini(tokens)
        let total = JSONValue.number(tokens["total"]).flatMap { $0 > 0 ? $0 : nil } ?? usage?.total ?? 0
        guard total.isFinite, total > 0 else { return [] }
        return [ActivityEvent(id: stableID(id), source: .gemini, date: date,
                              model: record["model"] as? String ?? tr("Unbekannt"), provider: "google",
                              tokens: total, usage: usage)]
    }
}
