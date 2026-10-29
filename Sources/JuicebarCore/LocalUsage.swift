import Foundation
import CSQLite

public struct LocalUsageReport: Codable, Sendable {
    public var events: [ActivityEvent] = []
    public var importWarnings: [String]?
    public var days: [UsageDay]
    public var models: [ModelUsage]
    public var messageCount: Int
    public var notice: String
    public var observedAt: Date
    public init(days: [UsageDay], models: [ModelUsage], messageCount: Int, notice: String, observedAt: Date = Date()) {
        self.days = days; self.models = models; self.messageCount = messageCount; self.notice = notice; self.observedAt = observedAt
    }
}
public struct ModelUsage: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var model: String
    public var tokens: Double
    public var cost: Double
    /// Tokens belonging to messages with an explicit, valid logged cost, including zero.
    /// Nil means an older cache did not record coverage; its summed cost cannot prove full coverage.
    public var pricedTokens: Double? = nil
    public enum CostCoverage: Equatable, Sendable { case unknown, partial, complete }
    public var costCoverage: CostCoverage {
        guard let pricedTokens, pricedTokens > 0 else { return .unknown }
        return pricedTokens >= tokens ? .complete : .partial
    }
    public var costLabel: String {
        let amount = cost.formatted(.currency(code: "USD").locale(Localization.locale))
        switch costCoverage {
        case .unknown: return tr("Unbekannt")
        case .partial: return "≥ " + amount
        case .complete: return amount
        }
    }
}

public enum OpenCodeHistory {
    // Only normalized usage metadata lives here. Bound retained events across databases,
    // and validate main/WAL/journal metadata before reusing a successful read.
    private final class CachedRead: NSObject {
        let report: LocalUsageReport
        let fingerprint: String
        let nextFutureDate: Date?
        let oldestDate: Date?
        init(report: LocalUsageReport, fingerprint: String, nextFutureDate: Date?) {
            self.report = report; self.fingerprint = fingerprint; self.nextFutureDate = nextFutureDate
            self.oldestDate = report.events.map(\.date).min()
        }
    }
    private static let recentReads: NSCache<NSString, CachedRead> = {
        let cache = NSCache<NSString, CachedRead>()
        cache.countLimit = 2; cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static func databaseFile(_ path: String?) -> String {
        let root = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
        return path ?? URL(fileURLWithPath: root).appendingPathComponent("opencode/opencode.db").path
    }

    /// Database, WAL and journal metadata; equal values mean the import would read the same rows.
    static func fingerprint(path: String?) throws -> String {
        try KiloHistory.fingerprint(root: URL(fileURLWithPath: databaseFile(path)).standardizedFileURL.resolvingSymlinksInPath())
    }

    public static func read(path: String? = nil, now: Date = Date(), lookbackDays: Int = 30, source: ActivitySource = .opencode) throws -> LocalUsageReport {
        let file = databaseFile(path)
        guard FileManager.default.fileExists(atPath: file) else { throw ProviderFailure.unavailable(tr("Keine lokale OpenCode-Datenbank gefunden. OpenCode einmal verwenden oder den Datenbankpfad auswählen.")) }
        try Task.checkCancellation()
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath()
        let cacheKey = "\(fileURL.path)|\(source.rawValue)|\(lookbackDays)|\(TimeZone.current.identifier)|\(Calendar.current.identifier)" as NSString
        let fingerprint = try KiloHistory.fingerprint(root: fileURL)
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86400)
        if let cached = recentReads.object(forKey: cacheKey), cached.fingerprint == fingerprint,
           now >= cached.report.observedAt, now.timeIntervalSince(cached.report.observedAt) < 3600,
           cached.nextFutureDate.map({ $0 > now }) ?? true,
           cached.oldestDate.map({ $0 >= cutoff }) ?? true {
            try Task.checkCancellation()
            var report = cached.report
            report.observedAt = now
            return report
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); throw ProviderFailure.unavailable(tr("Die OpenCode-Datenbank ist nicht lesbar."))
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        let since = now.addingTimeInterval(-Double(lookbackDays) * 86400).timeIntervalSince1970 * 1000
        var rows: [String: (day: Date, date: Date, tokens: Double, cost: Double?, provider: String, model: String, usage: TokenBreakdown?)] = [:]
        var supported = false, limited = false
        var nextFutureDate: Date?
        // V2 is read after V1 so a migrated record replaces its legacy copy.
        for table in ["message", "session_message"] {
            var stmt: OpaquePointer?
            let sql = "SELECT id,data,time_created FROM \(table) WHERE time_created >= ? ORDER BY time_created DESC LIMIT 100001"
            // Missing legacy tables are expected. Busy, corrupt or incompatible tables are not.
            var exists: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE name='\(table)' AND type IN ('table','view')", -1, &exists, nil) == SQLITE_OK else {
                throw ProviderFailure.unavailable(tr("Die OpenCode-Datenbank ist nicht lesbar."))
            }
            let existenceStatus = sqlite3_step(exists)
            sqlite3_finalize(exists)
            if existenceStatus == SQLITE_DONE { continue }
            guard existenceStatus == SQLITE_ROW,
                  sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw ProviderFailure.unavailable(tr("Die OpenCode-Datenbank ist nicht lesbar."))
            }
            defer { sqlite3_finalize(stmt) }
            supported = true; sqlite3_bind_double(stmt, 1, since)
            var count = 0
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                defer { status = sqlite3_step(stmt) }
                count += 1
                if count > 100000 { limited = true; continue }
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
                let provider = message["providerID"] as? String ?? model["providerID"] as? String ?? model["providerId"] as? String ?? tr("Unbekannt")
                let name = message["modelID"] as? String ?? model["modelID"] as? String ?? model["id"] as? String ?? tr("Unbekannt")
                let cost = JSONValue.number(message["cost"]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                let time = (message["time"] as? [String: Any]).flatMap { JSONValue.number($0["created"]) } ?? sqlite3_column_double(stmt, 2)
                let date = Date(timeIntervalSince1970: time / 1000)
                if date > now {
                    nextFutureDate = min(nextFutureDate ?? date, date)
                    continue
                }
                guard date.timeIntervalSince1970 * 1000 >= since else { continue }
                let day = Calendar.current.startOfDay(for: date)
                rows[id] = (day, date, total, cost, provider, name, TokenBreakdown.opencode(tokens))
            }
            guard status == SQLITE_DONE else {
                throw ProviderFailure.unavailable(tr("Die OpenCode-Datenbank konnte nicht vollständig gelesen werden."))
            }
        }
        guard supported else { throw ProviderFailure.unsupported(tr("Dieses OpenCode-Datenbankschema wird noch nicht unterstützt.")) }
        var days: [Date: UsageDay] = [:], models: [String: ModelUsage] = [:]
        for row in rows.values {
            var day = days[row.day] ?? UsageDay(day: row.day, tokens: 0, cost: 0)
            day.tokens += row.tokens; day.cost = (day.cost ?? 0) + (row.cost ?? 0); days[row.day] = day
            let id = "\(row.provider)/\(row.model)"
            var model = models[id] ?? ModelUsage(id: id, provider: row.provider, model: row.model, tokens: 0, cost: 0, pricedTokens: 0)
            model.tokens += row.tokens; model.cost += row.cost ?? 0
            if row.cost != nil { model.pricedTokens = (model.pricedTokens ?? 0) + row.tokens }
            models[id] = model
        }
        let missingCosts = rows.values.contains { $0.cost == nil }
        let note = tr("Lokale Nachrichten der letzten {0} Tage. Kosten sind OpenCode-Schätzungen, keine Abo-Rechnung. Kopien mit gleicher Nachrichten-ID werden nur einmal gezählt.", lookbackDays)
            + (limited ? tr(" Anzeige auf die neuesten 100.000 Zeilen je Tabelle begrenzt.") : "")
            + (missingCosts ? tr(" Für einige Nachrichten fehlen Kosten.") : "")
        var report = LocalUsageReport(days: days.values.sorted { $0.day < $1.day }, models: models.values.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }, messageCount: rows.count, notice: note, observedAt: now)
        report.importWarnings = limited ? [tr("{0}: Import auf die neuesten 100.000 Zeilen je Tabelle begrenzt.", source.name)] : []
        report.events = rows.map { id, row in ActivityEvent(id: stableID(id), source: source, date: row.date, model: row.model, provider: row.provider, tokens: row.tokens, usage: row.usage, reportedCost: source == .kilo ? row.cost : nil) }
        try Task.checkCancellation()
        let estimatedBytes = report.events.reduce(0) { $0 + 256 + $1.id.utf8.count + $1.model.utf8.count + $1.provider.utf8.count }
        if report.events.count <= 50000, estimatedBytes <= 8 * 1024 * 1024,
           try KiloHistory.fingerprint(root: fileURL) == fingerprint {
            recentReads.setObject(CachedRead(report: report, fingerprint: fingerprint, nextFutureDate: nextFutureDate),
                                  forKey: cacheKey, cost: max(1, estimatedBytes))
        }
        return report
    }
}
