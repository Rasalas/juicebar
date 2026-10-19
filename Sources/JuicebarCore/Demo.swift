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
                // Hours around the current time keep the learned usable hours independent of the render time.
                return (0..<count).map { index in ActivityEvent(id: "demo-\(source)-\(offset)-\(index)", source: source, date: date.addingTimeInterval(Double(index % 12 - 6) * 3600), model: source == .claude ? "claude-opus-5" : "gpt-6-sol", tokens: Double((offset * 1777 + index * 910 + 1000) % 100000), usage: TokenBreakdown(input: Double((offset * 1777 + index * 910 + 1000) % 100000) * 0.2, output: Double((offset * 1777 + index * 910 + 1000) % 100000) * 0.1, cacheRead: Double((offset * 1777 + index * 910 + 1000) % 100000) * 0.7)) }
            }
        }
        return ActivityReport(events: events, now: now)
    }
    public static func snapshots(now: Date = Date()) -> [AccountSnapshot] {
        [AccountSnapshot(configurationID: "demo-codex", identity: "demo-codex", plan: "Pro 20×", observedAt: now, source: "Beispieldaten",
                         windows: [QuotaWindow(id: "week", title: tr("Woche"), usedPercent: 83, resetsAt: now.addingTimeInterval(2.5 * 3600), duration: 604800),
                                   QuotaWindow(id: "short", title: tr("5 Stunden"), usedPercent: 30, resetsAt: now.addingTimeInterval(3 * 3600), duration: 18000)],
                         benefits: [ResetBenefit(id: "reset-demo", title: tr("Angesparter Reset"), scope: "Codex-Limits", expiresAt: now.addingTimeInterval(18 * 3600))], benefitCount: 1, benefitsChecked: true),
         AccountSnapshot(configurationID: "demo-claude", identity: "demo-claude", plan: "Max 20×", observedAt: now, source: "Beispieldaten",
                         windows: [QuotaWindow(id: "five_hour", title: tr("5 Stunden"), usedPercent: 40, resetsAt: now.addingTimeInterval(3600), duration: 18000),
                                   QuotaWindow(id: "seven_day", title: tr("Woche"), usedPercent: 82, resetsAt: now.addingTimeInterval(20 * 3600), duration: 604800)], benefitsChecked: true),
         AccountSnapshot(configurationID: "demo-go", identity: "demo-go", plan: "Go", observedAt: now, source: "Beispieldaten",
                         windows: [QuotaWindow(id: "rolling", title: tr("5 Stunden"), usedPercent: 12, resetsAt: now.addingTimeInterval(4 * 3600), duration: nil, supportsPace: false),
                                   QuotaWindow(id: "monthly", title: tr("Monat"), usedPercent: 31, resetsAt: now.addingTimeInterval(8 * 86400), duration: nil, supportsPace: false)])]
    }
    /// Codex cannot use its weekly rest before the reset; Claude's week fits, but only just.
    static let reachRatios = ["demo-codex": 0.08, "demo-claude": 0.1]
    public static func history(for snapshot: AccountSnapshot, now: Date = Date()) -> [AccountSnapshot] {
        guard let ratio = reachRatios[snapshot.configurationID],
              let short = snapshot.windows.firstIndex(where: { $0.duration == 18000 }),
              let long = snapshot.windows.firstIndex(where: { $0.duration == 604800 }),
              let reset = snapshot.windows[short].resetsAt else {
            return (0..<24).map { index in
                var past = snapshot; past.observedAt = now.addingTimeInterval(Double(index - 23) * 3600)
                past.windows = past.windows.map { window in var w = window; w.usedPercent *= Double(index + 2) / 25; return w }
                return past
            }
        }
        // Earlier short windows each ended at 50 %; the long window moves by `ratio` per short point.
        let duration = 18000.0, current = snapshot.windows[short].usedPercent
        let times = (0...60).map { now.addingTimeInterval(Double($0 - 60) * 1800) }
        let samples = times.map { time -> (end: Date, used: Double) in
            let periods = max(1, ceil(reset.timeIntervalSince(time) / duration))
            let start = reset.addingTimeInterval(-periods * duration)
            let used = periods == 1 ? current * time.timeIntervalSince(start) / now.timeIntervalSince(start)
                : 50 * time.timeIntervalSince(start) / duration
            return (start.addingTimeInterval(duration), used)
        }
        let increments = [0] + zip(samples, samples.dropFirst()).map { old, new in
            old.end == new.end ? new.used - old.used : 50 - old.used + new.used
        }
        return times.indices.map { index in
            var past = snapshot; past.observedAt = times[index]
            past.windows[short].usedPercent = samples[index].used
            past.windows[short].resetsAt = samples[index].end
            past.windows[long].usedPercent -= ratio * increments[(index + 1)...].reduce(0, +)
            return past
        }
    }
}
