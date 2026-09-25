import Foundation
import CSQLite

public struct LocalUsageReport: Codable, Sendable {
    public var events: [ActivityEvent] = []
    public var days: [UsageDay]
    public var models: [ModelUsage]
    public var messageCount: Int
    public var notice: String
    public var observedAt: Date
    public init(days: [UsageDay], models: [ModelUsage], messageCount: Int, notice: String, observedAt: Date = Date()) {
        self.days = days; self.models = models; self.messageCount = messageCount; self.notice = notice; self.observedAt = observedAt
    }
}
public struct ModelUsage: Codable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var model: String
    public var tokens: Double
    public var cost: Double
}

public enum OpenCodeHistory {
    public static func read(path: String? = nil, now: Date = Date(), lookbackDays: Int = 30) throws -> LocalUsageReport {
        let root = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
        let file = path ?? URL(fileURLWithPath: root).appendingPathComponent("opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: file) else { throw ProviderFailure.unavailable("Keine lokale OpenCode-Datenbank gefunden. OpenCode einmal verwenden oder den Datenbankpfad auswählen.") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); throw ProviderFailure.unavailable("Die OpenCode-Datenbank ist nicht lesbar.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        let since = now.addingTimeInterval(-Double(lookbackDays) * 86400).timeIntervalSince1970 * 1000
        var rows: [String: (day: Date, date: Date, tokens: Double, cost: Double?, provider: String, model: String, usage: TokenBreakdown?)] = [:]
        var supported = false, limited = false, missingCosts = false
        // V2 is read after V1 so a migrated record replaces its legacy copy.
        for table in ["message", "session_message"] {
            var stmt: OpaquePointer?
            let sql = "SELECT id,data,time_created FROM \(table) WHERE time_created >= ? ORDER BY time_created DESC LIMIT 100001"
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            supported = true; sqlite3_bind_double(stmt, 1, since)
            var count = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                count += 1
                if count > 100000 { limited = true; break }
                try Task.checkCancellation()
                guard sqlite3_column_bytes(stmt, 1) <= 2_000_000,
                      let rawID = sqlite3_column_text(stmt, 0), let rawJSON = sqlite3_column_text(stmt, 1) else { continue }
                let data = Data(bytes: rawJSON, count: Int(sqlite3_column_bytes(stmt, 1)))
                guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (message["role"] as? String ?? message["type"] as? String) == "assistant",
                      let tokens = message["tokens"] as? [String: Any] else { continue }
                let cache = tokens["cache"] as? [String: Any] ?? [:]
                let total = [tokens["input"], tokens["output"], tokens["reasoning"], cache["read"], cache["write"]].compactMap(JSONValue.number).reduce(0, +)
                guard total > 0 else { continue }
                let model = message["model"] as? [String: Any] ?? [:]
                let id = message["id"] as? String ?? String(cString: rawID)
                let provider = message["providerID"] as? String ?? model["providerID"] as? String ?? model["providerId"] as? String ?? "Unbekannt"
                let name = message["modelID"] as? String ?? model["modelID"] as? String ?? model["id"] as? String ?? "Unbekannt"
                let cost = JSONValue.number(message["cost"])
                if cost == nil { missingCosts = true }
                let time = (message["time"] as? [String: Any]).flatMap { JSONValue.number($0["created"]) } ?? sqlite3_column_double(stmt, 2)
                let date = Date(timeIntervalSince1970: time / 1000)
                guard date <= now, date.timeIntervalSince1970 * 1000 >= since else { continue }
                let day = Calendar.current.startOfDay(for: date)
                rows[id] = (day, date, total, cost, provider, name, TokenBreakdown.opencode(tokens))
            }
        }
        guard supported else { throw ProviderFailure.unsupported("Dieses OpenCode-Datenbankschema wird noch nicht unterstützt.") }
        var days: [Date: UsageDay] = [:], models: [String: ModelUsage] = [:]
        for row in rows.values {
            var day = days[row.day] ?? UsageDay(day: row.day, tokens: 0, cost: 0)
            day.tokens += row.tokens; day.cost = (day.cost ?? 0) + (row.cost ?? 0); days[row.day] = day
            let id = "\(row.provider)/\(row.model)"
            var model = models[id] ?? ModelUsage(id: id, provider: row.provider, model: row.model, tokens: 0, cost: 0)
            model.tokens += row.tokens; model.cost += row.cost ?? 0; models[id] = model
        }
        let note = "Lokale Nachrichten der letzten \(lookbackDays) Tage. Kosten sind OpenCode-Schätzungen, keine Abo-Rechnung. Kopien mit gleicher Nachrichten-ID werden nur einmal gezählt."
            + (limited ? " Anzeige auf die neuesten 100.000 Zeilen je Tabelle begrenzt." : "")
            + (missingCosts ? " Für einige Nachrichten fehlen Kosten." : "")
        var report = LocalUsageReport(days: days.values.sorted { $0.day < $1.day }, models: models.values.sorted { $0.tokens > $1.tokens }, messageCount: rows.count, notice: note, observedAt: now)
        report.events = rows.map { id, row in ActivityEvent(id: stableID(id), source: .opencode, date: row.date, model: row.model, provider: row.provider, tokens: row.tokens, usage: row.usage) }
        return report
    }
}
