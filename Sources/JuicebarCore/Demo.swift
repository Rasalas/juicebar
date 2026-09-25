import Foundation

public enum DemoData {
    public static let accounts = [AccountConfiguration(id: "demo-codex", provider: .codex),
                                  AccountConfiguration(id: "demo-claude", provider: .claude),
                                  AccountConfiguration(id: "demo-go", provider: .opencodeGo)]
    public static func activity(now: Date = Date()) -> ActivityReport {
        let calendar = Calendar.current
        let events = (0..<90).flatMap { offset -> [ActivityEvent] in
            guard offset % 7 != 2 else { return [] }
            return ActivitySource.allCases.flatMap { source -> [ActivityEvent] in
                let count = (offset * 7 + source.rawValue.count) % 12 + 2
                let date = calendar.date(byAdding: .day, value: -offset, to: now)!
                return (0..<count).map { index in ActivityEvent(id: "demo-\(source)-\(offset)-\(index)", source: source, date: date, model: source == .claude ? "claude-opus-5" : "gpt-6-sol", tokens: Double((offset * 1777 + index * 910 + 1000) % 100000), usage: TokenBreakdown(input: Double((offset * 1777 + index * 910 + 1000) % 100000) * 0.2, output: Double((offset * 1777 + index * 910 + 1000) % 100000) * 0.1, cacheRead: Double((offset * 1777 + index * 910 + 1000) % 100000) * 0.7)) }
            }
        }
        return ActivityReport(events: events, now: now)
    }
    public static func snapshots(now: Date = Date()) -> [AccountSnapshot] {
        [AccountSnapshot(configurationID: "demo-codex", identity: "demo-codex", plan: "Pro 20×", observedAt: now, source: "Beispieldaten",
                         windows: [QuotaWindow(id: "week", title: "Woche", usedPercent: 38, resetsAt: now.addingTimeInterval(3 * 86400), duration: 604800),
                                   QuotaWindow(id: "short", title: "5 Stunden", usedPercent: 24, resetsAt: now.addingTimeInterval(2.5 * 3600), duration: 18000)],
                         benefits: [ResetBenefit(id: "reset-demo", title: "Angesparter Reset", scope: "Codex-Limits", expiresAt: now.addingTimeInterval(18 * 3600))], benefitCount: 1, benefitsChecked: true),
         AccountSnapshot(configurationID: "demo-claude", identity: "demo-claude", plan: "Max 20×", observedAt: now, source: "Beispieldaten",
                         windows: [QuotaWindow(id: "five_hour", title: "5 Stunden", usedPercent: 64, resetsAt: now.addingTimeInterval(2 * 3600), duration: 18000),
                                   QuotaWindow(id: "seven_day", title: "Woche", usedPercent: 47, resetsAt: now.addingTimeInterval(2 * 86400), duration: 604800)], benefitsChecked: true),
         AccountSnapshot(configurationID: "demo-go", identity: "demo-go", plan: "Go", observedAt: now, source: "Beispieldaten",
                         windows: [QuotaWindow(id: "rolling", title: "5 Stunden", usedPercent: 12, resetsAt: now.addingTimeInterval(4 * 3600), duration: nil, supportsPace: false),
                                   QuotaWindow(id: "monthly", title: "Monat", usedPercent: 31, resetsAt: now.addingTimeInterval(8 * 86400), duration: nil, supportsPace: false)])]
    }
}
