import Foundation

public enum QuotaDisplay: String, Codable, CaseIterable, Sendable {
    case remaining, used
    public var label: String { self == .remaining ? tr("Verbleibend") : tr("Verbraucht") }
    public func value(used: Double) -> Double { self == .remaining ? max(0, 100 - used) : max(0, used) }
}
/// One wording for every remaining time: zero units are dropped, and from a week on only days are shown.
public func durationText(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(seconds / 60))
    if minutes < 60 { return tr("{0} Min.", minutes) }
    let hours = minutes / 60
    if hours < 24 { return minutes % 60 == 0 ? tr("{0} Std.", hours) : tr("{0} Std. {1} Min.", hours, minutes % 60) }
    let days = hours / 24
    return days >= 7 || hours % 24 == 0 ? tr("{0} T.", days) : tr("{0} T. {1} Std.", days, hours % 24)
}
public enum TrayStyle: String, Codable, CaseIterable, Sendable {
    case lines, focused
    public var label: String { self == .lines ? tr("Alle Konten · Limitlinien") : tr("Ein Limit") }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "lines", "all", "glasses": self = .lines
        case "focused": self = .focused
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown tray style"))
        }
    }
}

/// Stable order across refreshes, shared by the menu bar and its detail popover.
public enum QuotaOrder {
    public static func visibleWindows(_ windows: [QuotaWindow], provider: ProviderKind) -> [QuotaWindow] {
        self.windows(windows.filter { provider != .claude || ClaudeQuotaFields.supportsWindow($0.id) })
    }
    public static func accounts(_ accounts: [AccountConfiguration]) -> [AccountConfiguration] {
        let order: [ProviderKind] = [.codex, .claude, .opencodeGo, .opencodeZen, .openaiAPI, .anthropicAPI, .openrouter]
        return accounts.enumerated().sorted {
            let a = order.firstIndex(of: $0.element.provider) ?? order.count
            let b = order.firstIndex(of: $1.element.provider) ?? order.count
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
    public static func windows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        func rank(_ w: QuotaWindow) -> Int {
            if w.title.contains(" · ") || w.id.hasPrefix("model.") { return 3 }
            if ["5 Stunden", "5 hours"].contains(w.title) || (w.duration.map { $0 < 86400 } ?? false) { return 0 }
            if w.duration == 604800 || ["Woche", "Week"].contains(w.title) { return 1 }
            if ["Monat", "Month"].contains(w.title) || w.id == "budget" { return 2 }
            return 3
        }
        return windows.sorted { rank($0) == rank($1) ? $0.id < $1.id : rank($0) < rank($1) }
    }
}
public struct TrayMeter: Identifiable {
    public var account: AccountConfiguration
    public var window: QuotaWindow?
    public var fresh: Bool
    public var expired = false
    public var id: String { "\(account.id):\(window?.id ?? "unknown")" }
    public var windowLabel: String {
        guard let window else { return "" }
        if let duration = window.duration {
            if duration == 604800 { return "W" }
            if duration == 18000 { return "5h" }
            if duration < 86400 { return "\(Int(duration / 3600))h" }
        }
        if ["woche", "week"].contains(where: { window.title.lowercased().contains($0) }) { return "W" }
        if ["monat", "month"].contains(where: { window.title.lowercased().contains($0) }) { return "M" }
        return ["5 Stunden", "5 hours"].contains(window.title) ? "5h" : String(window.title.prefix(5))
    }
}
public enum TraySelection {
    public static func meters(accounts: [AccountConfiguration], snapshots: [String: AccountSnapshot],
                              failures: Set<String>, settings: MonitorSettings, now: Date) -> [TrayMeter] {
        let values = QuotaOrder.accounts(accounts.filter(\.enabled)).flatMap { account -> [TrayMeter] in
            let snapshot = snapshots[account.id]
            let allWindows = QuotaOrder.visibleWindows(snapshot?.windows ?? [], provider: account.provider)
            let windows = QuotaOrder.windows(allWindows.filter {
                settings.menuStyle == .focused || settings.showsTrayLimit(account: account, windowID: $0.id)
            })
            let fresh = snapshot?.isFresh(at: now) == true && !failures.contains(account.id)
            if settings.menuStyle == .lines {
                if windows.isEmpty {
                    // Hidden limits are not missing data. Only an unread account gets a placeholder.
                    return allWindows.isEmpty ? [TrayMeter(account: account, window: nil, fresh: false)] : []
                }
                return windows.map { window in
                    TrayMeter(account: account, window: window, fresh: fresh,
                              expired: window.resetsAt.map { $0 <= now } ?? false)
                }
            }
            let current = windows.filter { $0.resetsAt.map { $0 > now } ?? true }
            let selected: QuotaWindow?
            if settings.selectedTrayAccount == account.id, let id = settings.selectedTrayWindow {
                selected = current.first { $0.id == id }
            } else {
                selected = current.sorted { $0.usedPercent == $1.usedPercent ? $0.id < $1.id : $0.usedPercent > $1.usedPercent }.first
            }
            return [TrayMeter(account: account, window: selected, fresh: fresh)]
        }
        guard settings.menuStyle == .focused else { return values }
        if let id = settings.selectedTrayAccount { return values.filter { $0.account.id == id } }
        return Array(values.sorted { a, b in
            if a.fresh != b.fresh { return a.fresh }
            return (a.window?.usedPercent ?? -1) > (b.window?.usedPercent ?? -1)
        }.prefix(1))
    }
}

public enum ActivitySource: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, opencode, pi, gemini, cline, roo, kilo, qwen
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .gemini: "Gemini CLI"
        case .cline: "Cline"
        case .roo: "Roo Code"
        case .kilo: "Kilo"
        case .qwen: "Qwen Code"
        }
    }
    public static var logFormats: [Self] { allCases.filter { $0 != .opencode } }
}
/// Usage metadata. Tool usage can contribute tokens without adding a model response.
public struct ActivityEvent: Codable, Sendable, Identifiable {
    public var id: String
    public var source: ActivitySource
    public var date: Date
    public var model: String
    public var provider: String
    public var tokens: Double
    public var usage: TokenBreakdown?
    public var responseCount: Int?
    public var reportedCost: Double?
    public var sessionStartedAt: Date?
    public init(id: String, source: ActivitySource, date: Date, model: String, provider: String = "", tokens: Double, usage: TokenBreakdown? = nil,
                responseCount: Int? = nil, reportedCost: Double? = nil, sessionStartedAt: Date? = nil) {
        self.id = id; self.source = source; self.date = date; self.model = model; self.provider = provider; self.tokens = tokens; self.usage = usage
        self.responseCount = responseCount; self.reportedCost = reportedCost; self.sessionStartedAt = sessionStartedAt
    }
    /// Duplicates are observations, not additional responses. Pi's earliest known session wins over forks,
    /// then the largest streaming total wins, then completeness (valid split, logged cost, model, provider,
    /// explicit response count, in that order). Those preferences are independent of traversal order.
    /// Equally complete conflicts use the later input observation, including lower/zero cost corrections.
    /// This is an ordered conflict policy, not a claim of log revision time: peer copies have no such field.
    /// Archives therefore pass retained observations first and reread source observations second.
    static func preferred(_ first: Self, _ second: Self) -> Self {
        keepsFirst(source: first.source, first.preference, second.preference) ? first : second
    }
    /// The fields `preferred` decides on; the report builder keeps only these.
    struct Preference {
        var tokens: Double
        var completeness: UInt8
        var session: Date?
    }
    var preference: Preference {
        func known(_ text: String) -> Bool { !["", "unknown", "unbekannt"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        let validUsage = usage.map { $0.isValid && abs($0.total - tokens) < 0.5 } ?? false
        let validCost = reportedCost.map { $0.isFinite && $0 >= 0 } ?? false
        let completeness: UInt8 = (validUsage ? 16 : 0) | (validCost ? 8 : 0) | (known(model) ? 4 : 0)
            | (known(provider) ? 2 : 0) | (responseCount != nil ? 1 : 0)
        return Preference(tokens: tokens, completeness: completeness, session: sessionStartedAt)
    }
    static func keepsFirst(source: ActivitySource, _ first: Preference, _ second: Preference) -> Bool {
        if source == .pi, first.session != second.session { return (first.session ?? .distantFuture) < (second.session ?? .distantFuture) }
        return first.tokens > second.tokens || (first.tokens == second.tokens && first.completeness > second.completeness)
    }
}
public struct ActivityDay: Codable, Identifiable, Sendable {
    public var day: Date
    public var source: ActivitySource
    public var tokens: Double
    public var responses: Int
    public var apiCost: Double = 0
    public var pricedTokens: Double = 0
    public var unpricedModels: Set<String> = []
    public var archivedMessages: Int = 0
    public var archivedTokens: Double = 0
    public var id: String { "\(source.rawValue)-\(day.timeIntervalSince1970)" }
}
/// Local hours of a day with activity as a 24-bit mask.
public struct ActivityHours: Codable, Equatable, Sendable {
    public var day: Date
    public var source: ActivitySource
    public var hours: Int
    public init(day: Date, source: ActivitySource, hours: Int) { self.day = day; self.source = source; self.hours = hours }
}
public struct ActivityReport: Codable, Sendable {
    public static let hourHistoryDays = 28
    public var days: [ActivityDay]
    /// Recent days only; nil in reports saved before hours were recorded.
    public var activeHours: [ActivityHours]?
    public var notices: [String]
    public var warnings: [String]
    public var observedAt: Date
    public init(events: [ActivityEvent], notices: [String] = [], warnings: [String] = [], now: Date = Date(), calendar: Calendar = .current) {
        var builder = Builder(now: now, calendar: calendar)
        for event in events { builder.add(event) }
        self = builder.report(notices: notices, warnings: warnings)
    }
    init(days: [ActivityDay], activeHours: [ActivityHours]?, notices: [String], warnings: [String], observedAt: Date) {
        self.days = days; self.activeHours = activeHours; self.notices = notices; self.warnings = warnings; self.observedAt = observedAt
    }
}
