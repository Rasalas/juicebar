import Foundation

/// Pi entries keep their ID and message time when copied into a fork.
struct PiUsageParser {
    let fileID: String
    private var sessionStartedAt: Date?
    private var model = tr("Unbekannt")
    private var provider = ""
    private var entryNumber = 0
    private let dates = LogDateParser()
    private(set) var events: [ActivityEvent] = []

    init(fileID: String) { self.fileID = fileID }

    mutating func consume(_ record: [String: Any]) {
        let kind = record["type"] as? String
        if kind == "session" {
            if sessionStartedAt == nil { sessionStartedAt = dates.parse(record["timestamp"]) }
            return
        }
        let message = record["message"] as? [String: Any] ?? [:]
        let role = message["role"] as? String
        let fields: [String: Any]
        let responses: Int
        switch kind {
        case "message" where role == "assistant" || role == "toolResult":
            fields = message
            responses = role == "assistant" ? 1 : 0
        case "compaction", "branch_summary", "usage":
            fields = record
            responses = kind == "usage" ? 0 : 1
        default: return
        }
        guard let usage = fields["usage"] as? [String: Any] else { return }
        // Assistant timestamps use milliseconds; envelope timestamps use ISO 8601.
        let messageDate = JSONValue.number(message["timestamp"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        guard let date = messageDate ?? dates.parse(record["timestamp"]) else { return }
        let eventModel = fields["model"] as? String ?? model
        let eventProvider = fields["provider"] as? String ?? provider
        if role == "assistant" { model = eventModel; provider = eventProvider }

        let breakdown = TokenBreakdown.pi(usage)
        let total = JSONValue.number(usage["totalTokens"])
        let tokens = total.flatMap { $0 > 0 ? $0 : nil } ?? breakdown?.total ?? 0
        guard tokens.isFinite, tokens > 0 else { return }
        entryNumber += 1
        let cost = (usage["cost"] as? [String: Any]).flatMap { JSONValue.number($0["total"]) }.flatMap { $0 >= 0 ? $0 : nil }
        let identity = (record["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(fileID)|\(entryNumber)"
        events.append(ActivityEvent(id: stableID("\(identity)|\(date.timeIntervalSince1970)"), source: .pi,
                                    date: date, model: eventModel, provider: eventProvider, tokens: tokens,
                                    usage: breakdown, responseCount: responses, reportedCost: cost,
                                    sessionStartedAt: sessionStartedAt))
    }
}
