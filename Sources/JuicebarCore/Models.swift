import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, opencodeGo, opencodeZen, openrouter, anthropicAPI, openaiAPI
    public var id: String { rawValue }
    public var shortLabel: String {
        switch self { case .codex: return "CX"; case .claude: return "CL"; case .opencodeGo: return "GO"; case .opencodeZen: return "ZE"; case .openrouter: return "OR"; case .anthropicAPI: return "AN"; case .openaiAPI: return "OA" }
    }
    public var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .opencodeGo: return "OpenCode Go"
        case .opencodeZen: return "OpenCode Zen"
        case .openrouter: return "OpenRouter"
        case .anthropicAPI: return "Anthropic API"
        case .openaiAPI: return "OpenAI API"
        }
    }
    public var symbol: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "sun.max"
        case .opencodeGo, .opencodeZen: return "chevron.left.forwardslash.chevron.right"
        default: return "key.horizontal"
        }
    }
    public var accountURL: URL {
        let address = switch self {
        case .codex: "https://chatgpt.com/codex/settings/usage"
        case .claude: "https://claude.ai/settings/usage"
        case .opencodeGo, .opencodeZen: "https://opencode.ai/console/"
        case .openrouter: "https://openrouter.ai/settings/credits"
        case .anthropicAPI: "https://platform.claude.com/settings/usage"
        case .openaiAPI: "https://platform.openai.com/usage"
        }
        return URL(string: address)!
    }
    public var needsKey: Bool { self != .codex && self != .claude }
    public var keyHelp: String {
        switch self {
        case .openaiAPI: return tr("Admin-Key zum Lesen der Organisationskosten. Ein normaler Modell-Key reicht nicht.")
        case .anthropicAPI: return tr("Admin-Key zum Lesen der Organisationskosten. Das Claude-Abo wird separat angezeigt.")
        case .opencodeGo, .opencodeZen: return tr("OpenCode-Key. Alternativ den vorhandenen lokalen OpenCode-Login verwenden.")
        case .openrouter: return tr("Management-Key für kontoweites Guthaben.")
        default: return tr("Die Anmeldung bleibt bei der installierten CLI.")
        }
    }
}

public struct AccountConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var provider: ProviderKind
    public var label: String
    public var enabled: Bool
    public var executablePath: String
    public var profileDirectory: String
    public var monthlyBudget: Double?
    public var useLocalCredentials: Bool
    public init(id: String = UUID().uuidString, provider: ProviderKind, label: String = "", enabled: Bool = true,
                executablePath: String = "", profileDirectory: String = "", monthlyBudget: Double? = nil,
                useLocalCredentials: Bool = true) {
        self.id = id; self.provider = provider; self.label = label; self.enabled = enabled
        self.executablePath = executablePath; self.profileDirectory = profileDirectory
        self.monthlyBudget = monthlyBudget; self.useLocalCredentials = useLocalCredentials
    }
    public var displayName: String { label.isEmpty ? provider.name : label }
}

public struct QuotaWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var duration: TimeInterval?
    public var supportsPace: Bool
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil,
                duration: TimeInterval? = nil, supportsPace: Bool = true) {
        self.id = id; self.title = title; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.duration = duration; self.supportsPace = supportsPace
    }
    public func idealPercent(at date: Date) -> Double? {
        guard supportsPace, let duration, duration > 0, let resetsAt, resetsAt > date else { return nil }
        return min(100, max(0, 100 * (1 - resetsAt.timeIntervalSince(date) / duration)))
    }
}

public enum BenefitStatus: String, Codable, Sendable { case available, used, expired, paused, unknown }
public struct ResetBenefit: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var scope: String
    public var count: Int
    public var expiresAt: Date?
    public var status: BenefitStatus
    public var isManual: Bool
    public init(id: String, title: String, scope: String, count: Int = 1, expiresAt: Date? = nil,
                status: BenefitStatus = .available, isManual: Bool = false) {
        self.id = id; self.title = title; self.scope = scope; self.count = count
        self.expiresAt = expiresAt; self.status = status; self.isManual = isManual
    }
}

public struct MoneyMetric: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var amount: Double
    public var currency: String
    public var isEstimate: Bool
    public init(id: String, title: String, amount: Double, currency: String = "USD", isEstimate: Bool = false) {
        self.id = id; self.title = title; self.amount = amount; self.currency = currency; self.isEstimate = isEstimate
    }
}

public struct UsageDay: Identifiable, Codable, Equatable, Sendable {
    public var day: Date
    public var tokens: Double
    public var cost: Double?
    public var id: Date { day }
    public init(day: Date, tokens: Double, cost: Double? = nil) { self.day = day; self.tokens = tokens; self.cost = cost }
}

public struct AccountSnapshot: Codable, Equatable, Sendable {
    public var configurationID: String
    public var identity: String
    public var plan: String
    public var observedAt: Date
    public var source: String
    public var windows: [QuotaWindow]
    public var benefits: [ResetBenefit]
    public var benefitCount: Int?
    public var benefitsChecked: Bool
    public var money: [MoneyMetric]
    public var dailyUsage: [UsageDay]
    public var notice: String?
    public init(configurationID: String, identity: String, plan: String = "", observedAt: Date = Date(),
                source: String, windows: [QuotaWindow] = [], benefits: [ResetBenefit] = [], benefitCount: Int? = nil,
                benefitsChecked: Bool = false, money: [MoneyMetric] = [], dailyUsage: [UsageDay] = [], notice: String? = nil) {
        self.configurationID = configurationID; self.identity = identity; self.plan = plan; self.observedAt = observedAt
        self.source = source; self.windows = windows; self.benefits = benefits; self.benefitCount = benefitCount
        self.benefitsChecked = benefitsChecked; self.money = money; self.dailyUsage = dailyUsage; self.notice = notice
    }
    public func isFresh(at now: Date, maximumAge: TimeInterval = 360) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= -60 && age <= maximumAge
    }
}

public struct MonitorSettings: Codable, Equatable, Sendable {
    public var refreshSeconds: Double = 90
    public var threshold: Double = 50
    public var thresholdEnabled = true
    public var paceEnabled = true
    public var paceBuffer: Double = 10
    public var forecastEnabled = true
    public var forecastHours: Double = 2
    public var expiryEnabled = true
    public var expiryHours: [Double] = [72, 24, 3]
    public var notificationsEnabled = false
    public var soundEnabled = true
    public var quietEnabled = true
    public var quietStart = 22
    public var quietEnd = 8
    public var snoozedUntil: Date?
    public var selectedTrayAccount: String?
    public var selectedTrayWindow: String?
    // Optional fields preserve decoding of preferences written before these options existed.
    public var quotaDisplay: QuotaDisplay?
    public var trayStyle: TrayStyle?
    public var trayLimitVisibility: [String: [String: Bool]]?
    public var automaticallyShowNewTrayLimits: Bool?
    public var showsNewTrayLimits: Bool { automaticallyShowNewTrayLimits ?? true }
    public func showsTrayLimit(account: AccountConfiguration, windowID: String) -> Bool {
        if let visible = trayLimitVisibility?[account.id]?[windowID] { return visible }
        if account.provider == .claude && windowID == "nimbus_quill" { return false }
        return showsNewTrayLimits
    }
    public mutating func setTrayLimit(accountID: String, windowID: String, visible: Bool) {
        var visibility = trayLimitVisibility ?? [:]
        visibility[accountID, default: [:]][windowID] = visible
        trayLimitVisibility = visibility
    }
    public mutating func setNewTrayLimitsVisible(_ visible: Bool, accounts: [AccountConfiguration], snapshots: [String: AccountSnapshot]) {
        // Preserve current choices; the switch only changes the policy for future discoveries.
        for account in accounts {
            for window in snapshots[account.id]?.windows ?? [] {
                let current = showsTrayLimit(account: account, windowID: window.id)
                setTrayLimit(accountID: account.id, windowID: window.id, visible: current)
            }
        }
        automaticallyShowNewTrayLimits = visible
    }
    public var displayMode: QuotaDisplay { quotaDisplay ?? .remaining }
    public var menuStyle: TrayStyle { trayStyle ?? .lines }
    public init() {}
    public func isQuiet(at now: Date, calendar: Calendar = .current) -> Bool {
        if let snoozedUntil, now < snoozedUntil { return true }
        guard quietEnabled, quietStart != quietEnd else { return false }
        let h = calendar.component(.hour, from: now)
        return quietStart < quietEnd ? (h >= quietStart && h < quietEnd) : (h >= quietStart || h < quietEnd)
    }
}

public enum ProviderFailure: Error, LocalizedError, Equatable {
    case missingExecutable(String), authentication, unsupported(String), invalidData(String), timedOut, rateLimited(TimeInterval), network, unavailable(String), needsSetup(String)
    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let name): return tr("{0} wurde nicht gefunden. Pfad unter Konten einstellen.", name)
        case .authentication: return tr("Anmeldung fehlt oder ist abgelaufen. Beim Anbieter erneut anmelden.")
        case .unsupported(let detail), .invalidData(let detail), .unavailable(let detail), .needsSetup(let detail): return detail
        case .timedOut: return tr("Die Abfrage hat zu lange gedauert. Der letzte Stand bleibt sichtbar.")
        case .rateLimited: return tr("Der Anbieter begrenzt die Abfragen. Juicebar wartet vor dem nächsten Versuch.")
        case .network: return tr("Verbindung nicht möglich. Juicebar versucht es später erneut.")
        }
    }
}
