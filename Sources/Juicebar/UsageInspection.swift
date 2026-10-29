import Foundation
import JuicebarCore

/// Selection uses dates and period identities, never indexes into a changing chart.
enum UsageSelection {
    static func nearest(_ date: Date?, in dates: [Date]) -> Date? {
        guard let date else { return dates.max() }
        return dates.min {
            let lhs = abs($0.timeIntervalSince(date)), rhs = abs($1.timeIntervalSince(date))
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }
    static func move(_ date: Date?, by offset: Int, in dates: [Date]) -> Date? {
        let sorted = Array(Set(dates)).sorted()
        guard let current = nearest(date, in: sorted), let index = sorted.firstIndex(of: current) else { return nil }
        return sorted[min(sorted.count - 1, max(0, index + offset))]
    }
    static func days(ending now: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        let end = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: end) }
    }
}

enum ActivityMetric: String, CaseIterable, Identifiable {
    case cost = "API-Kosten", tokens = "Tokens", responses = "Antworten"
    var id: String { rawValue }
    func value(_ day: ActivityDay) -> Double {
        switch self { case .cost: day.apiCost; case .tokens: day.tokens; case .responses: Double(day.responses) }
    }
    /// Unknown cost is not a zero-height measurement. Archive-only response counts are unknown too.
    func plottedValue(_ day: ActivityDay) -> Double? {
        if self == .cost && !ActivityMetricDetails([day]).hasKnownCost { return nil }
        if self == .responses && day.responses == 0 && day.archivedMessages > 0 { return nil }
        if self == .tokens && day.tokens == 0 && day.archivedMessages > 0 { return nil }
        return value(day)
    }
}

struct ActivityMetricDetails {
    let days: [ActivityDay]
    init(_ days: [ActivityDay]) { self.days = days }
    var tokens: Double { days.reduce(0) { $0 + $1.tokens } }
    var pricedTokens: Double { days.reduce(0) { $0 + $1.pricedTokens } }
    var archived: Int { days.reduce(0) { $0 + $1.archivedMessages } }
    var hasKnownCost: Bool { days.contains { $0.pricedTokens > 0 || $0.apiCost > 0 } }
    var isPartialCost: Bool { pricedTokens < tokens || archived > 0 || days.contains { !$0.unpricedModels.isEmpty } }
    func valueLabel(_ metric: ActivityMetric) -> String {
        guard !days.isEmpty else { return tr("Keine protokollierte Aktivität") }
        switch metric {
        case .cost:
            guard hasKnownCost else { return tr("Kosten unbekannt") }
            return costLabel(precise: true) + " · " + tr("API-Gegenwert")
        case .tokens:
            guard tokens > 0 || archived == 0 else { return tr("Tokens unbekannt") }
            return tr("{0} Tokens", tokens.formatted(.number.locale(Localization.locale)))
        case .responses:
            let count = days.reduce(0) { $0 + $1.responses }
            guard count > 0 || archived == 0 else { return tr("Antworten unbekannt") }
            return tr("{0} Modellantworten", count.formatted(.number.locale(Localization.locale)))
        }
    }
    func costLabel(precise: Bool = false) -> String {
        guard !days.isEmpty else { return "—" }
        guard hasKnownCost else { return tr("Kosten unbekannt") }
        let amount = days.reduce(0) { $0 + $1.apiCost }
            .formatted(.currency(code: "USD").precision(.fractionLength(2...(precise ? 10 : 2))).locale(Localization.locale))
        return (isPartialCost ? "≥ " : "") + amount
    }
    var tokenCoverage: String {
        guard tokens > 0 else { return "" }
        let percent = min(100, max(0, pricedTokens / tokens * 100))
        return tr("{0} % der Tokens bepreist", percent.formatted(.number.precision(.fractionLength(0...1)).locale(Localization.locale)))
    }
    func coverage(_ metric: ActivityMetric) -> String {
        var parts: [String] = []
        if metric == .cost {
            if tokens > 0 {
                parts.append(tokenCoverage)
            }
            let missing = Set(days.flatMap(\.unpricedModels)).sorted()
            if !missing.isEmpty { parts.append(tr("Unbepreist: {0}", missing.joined(separator: ", "))) }
        }
        if archived > 0 {
            parts.append(tr("{0} archivierte Nachrichten", archived.formatted(.number.locale(Localization.locale))))
            if metric == .cost { parts.append(tr("Claude-Kosten nicht rekonstruierbar")) }
            if metric == .responses { parts.append(tr("Archivierte Nachrichten sind keine Modellantworten.")) }
        }
        return parts.joined(separator: " · ")
    }
    func label(_ metric: ActivityMetric) -> String {
        let detail = coverage(metric)
        return valueLabel(metric) + (detail.isEmpty ? "" : " · " + detail)
    }
}

struct QuotaPoint: Identifiable, Equatable {
    struct ID: Hashable { let series: String; let date: Date }
    var date: Date
    var value: Double
    var label: String
    var series: String
    var id: ID { ID(series: series, date: date) }
}

enum QuotaSelection {
    static func resolve(_ selection: QuotaPoint.ID?, in points: [QuotaPoint]) -> QuotaPoint? {
        if let selection {
            let series = points.filter { $0.series == selection.series }
            let candidates = series.isEmpty ? points : series
            guard let date = UsageSelection.nearest(selection.date, in: candidates.map(\.date)) else { return nil }
            return candidates.filter { $0.date == date }.sorted { $0.series < $1.series }.first
        }
        return points.sorted { $0.date == $1.date ? $0.series < $1.series : $0.date > $1.date }.first
    }
    static func move(_ selection: QuotaPoint.ID?, by offset: Int, in points: [QuotaPoint]) -> QuotaPoint.ID? {
        guard let point = resolve(selection, in: points) else { return nil }
        let dates = points.filter { $0.series == point.series }.map(\.date)
        return UsageSelection.move(point.date, by: offset, in: dates).map { .init(series: point.series, date: $0) }
    }
    static func changeSeries(_ selection: QuotaPoint.ID?, by offset: Int, in points: [QuotaPoint]) -> QuotaPoint.ID? {
        guard let point = resolve(selection, in: points) else { return nil }
        let series = Array(Set(points.map(\.series))).sorted()
        guard let index = series.firstIndex(of: point.series) else { return nil }
        return resolve(.init(series: series[min(series.count - 1, max(0, index + offset))], date: point.date), in: points)?.id
    }
    static func detail(_ point: QuotaPoint, displayLabel: String) -> String {
        let time = point.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(Localization.locale))
        let value = point.value.formatted(.number.precision(.fractionLength(0...6)).locale(Localization.locale))
        return "\(point.label) · \(time) · \(value) % \(displayLabel.lowercased())"
    }
}
