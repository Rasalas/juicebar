import Foundation

public enum QuotaDisplay: String, Codable, CaseIterable, Sendable {
    case remaining, used
    public var label: String { self == .remaining ? tr("Verbleibend") : tr("Verbraucht") }
    public func value(used: Double) -> Double { self == .remaining ? max(0, 100 - used) : max(0, used) }
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
        self.windows(windows.filter { provider != .claude || $0.id != "nimbus_quill" })
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
    case codex, claude, opencode
    public var id: String { rawValue }
    public var name: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .opencode: "OpenCode" } }
}
/// A completed model response, not a user prompt or a tool invocation. IDs are hashed before persistence.
public struct ActivityEvent: Codable, Sendable, Identifiable {
    public var id: String
    public var source: ActivitySource
    public var date: Date
    public var model: String
    public var provider: String
    public var tokens: Double
    public var usage: TokenBreakdown?
    public init(id: String, source: ActivitySource, date: Date, model: String, provider: String = "", tokens: Double, usage: TokenBreakdown? = nil) {
        self.id = id; self.source = source; self.date = date; self.model = model; self.provider = provider; self.tokens = tokens; self.usage = usage
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
public struct ActivityReport: Codable, Sendable {
    public var days: [ActivityDay]
    public var notices: [String]
    public var warnings: [String]
    public var observedAt: Date
    public init(events: [ActivityEvent], notices: [String] = [], warnings: [String] = [], now: Date = Date(), calendar: Calendar = .current) {
        struct Key: Hashable { var source: ActivitySource; var id: String }
        var unique: [Key: ActivityEvent] = [:]
        unique.reserveCapacity(events.count)
        for event in events where event.date <= now && event.tokens.isFinite && event.tokens > 0 {
            let key = Key(source: event.source, id: event.id)
            // Streaming blocks may repeat a message with an updated output count.
            if let previous = unique[key], previous.tokens > event.tokens || (previous.tokens == event.tokens && previous.usage != nil) { continue }
            unique[key] = event
        }
        var groups: [String: ActivityDay] = [:]
        for event in unique.values {
            let day = calendar.startOfDay(for: event.date), key = "\(event.source.rawValue)-\(calendar.startOfDay(for: event.date).timeIntervalSince1970)"
            var value = groups[key] ?? ActivityDay(day: day, source: event.source, tokens: 0, responses: 0)
            value.tokens += event.tokens; value.responses += 1
            if let usage = event.usage, abs(usage.total - event.tokens) < 0.5, let cost = APICost.estimate(model: event.model, provider: event.provider, usage: usage) {
                value.apiCost += cost; value.pricedTokens += event.tokens
            } else { value.unpricedModels.insert(event.model) }
            groups[key] = value
        }
        days = groups.values.sorted { $0.day == $1.day ? $0.source.rawValue < $1.source.rawValue : $0.day < $1.day }
        let resolved = Set(unique.values.compactMap { event -> String? in
            guard let alias = ModelAliases.resolve(model: event.model, provider: event.provider) else { return nil }
            return "\(event.model) → \(alias.displayName)"
        }).sorted()
        self.notices = notices + (resolved.isEmpty ? [] : [tr("Veröffentlichte Modell-Aliase: ") + resolved.joined(separator: "; ") + tr(". Auch ältere Nutzung wird zum aktuellen API-Gegenwert bewertet; die damals kostenlose Preview bleibt in gemeldeten Kosten unverändert.")])
        self.warnings = warnings; observedAt = now
    }
}
