import Foundation

/// Recover whole missing days from Claude's retained statistics. These are aggregates,
/// not individual responses; never invent a token split or add them to a logged day.
public enum ClaudeHistory {
    public static func supplement(_ report: inout ActivityReport, roots: [URL], now: Date = Date(), calendar: Calendar = .current) {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let since = calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now))!
        let detailedDays = Set(report.days.filter { $0.source == .claude }.map(\.day))
        var recovered: [Date: ActivityDay] = [:]
        for root in Set(roots) {
            let url = root.appendingPathComponent("stats-cache.json")
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10_000_000,
                  let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Unknown cache versions may change token semantics. Keep activity counts only.
            let tokensSupported = JSONValue.number(json["dailyModelTokensVersion"]) == 5
            let tokenRows = tokensSupported ? (json["dailyModelTokens"] as? [[String: Any]] ?? []) : []
            var tokensByDate: [String: Double] = [:]
            for row in tokenRows {
                guard let date = row["date"] as? String, let models = row["tokensByModel"] as? [String: Any] else { continue }
                tokensByDate[date] = models.values.compactMap(JSONValue.number).filter { $0.isFinite && $0 >= 0 }.reduce(0, +)
            }
            for row in json["dailyActivity"] as? [[String: Any]] ?? [] {
                guard let dateString = row["date"] as? String, let day = formatter.date(from: dateString),
                      day >= since, day <= now, !detailedDays.contains(day) else { continue }
                let count = max(0, JSONValue.number(row["messageCount"]) ?? 0)
                guard count.isFinite, count < 1_000_000_000 else { continue }
                let tokens = tokensByDate[dateString] ?? 0
                var value = recovered[day] ?? ActivityDay(day: day, source: .claude, tokens: 0, responses: 0)
                // Profile copies can repeat the same cache; use the maximum, not a sum.
                value.tokens = max(value.tokens, tokens); value.archivedTokens = value.tokens
                value.archivedMessages = max(value.archivedMessages, Int(count))
                if tokens > 0 { value.unpricedModels.insert(tr("Claude-Tagesstatistik ohne Token-Aufschlüsselung")) }
                recovered[day] = value
            }
        }
        if !recovered.isEmpty {
            report.days += recovered.values
            report.days.sort { $0.day == $1.day ? $0.source.rawValue < $1.source.rawValue : $0.day < $1.day }
            report.notices.append(tr("{0} ältere Claude-Tage aus dem Statistik-Cache ergänzt. Nachrichten enthalten auch Nutzer- und Werkzeugnachrichten. Für diese Tageswerte fehlen die Token-Arten zur Kostenberechnung.", recovered.count))
        }
    }
}
