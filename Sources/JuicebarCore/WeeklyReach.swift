import Foundation

/// Hours of the day in which a new short window would start.
public struct UsableHours: Equatable, Sendable {
    public let hours: Set<Int>
    public init(_ hours: Set<Int>) { self.hours = hours.filter { (0..<24).contains($0) } }
    public static let all = UsableHours(Set(0..<24))
    static let minimumActiveDays = 7
    static let minimumShare = 0.2

    public static func outsideQuietHours(_ settings: MonitorSettings) -> UsableHours {
        guard settings.quietEnabled, settings.quietStart != settings.quietEnd else { return .all }
        let start = settings.quietStart, end = settings.quietEnd
        return UsableHours(Set((0..<24).filter { start < end ? !($0 >= start && $0 < end) : !($0 >= start || $0 < end) }))
    }
    /// An hour counts when it saw activity on at least 20 % of the active days; nil below seven active days.
    public static func learned(from activity: [ActivityHours], source: ActivitySource, now: Date) -> UsableHours? {
        let since = now.addingTimeInterval(-Double(ActivityReport.hourHistoryDays) * 86400)
        let days = Dictionary(activity.filter { $0.source == source && $0.day >= since && $0.day <= now && $0.hours != 0 }
            .map { ($0.day, $0.hours) }, uniquingKeysWith: |)
        guard days.count >= minimumActiveDays else { return nil }
        let hours = (0..<24).filter { hour in
            Double(days.values.filter { $0 & (1 << hour) != 0 }.count) >= minimumShare * Double(days.count)
        }
        return hours.isEmpty ? nil : UsableHours(Set(hours))
    }
    public static func resolve(activity: ActivityReport?, source: ActivitySource?, settings: MonitorSettings, now: Date) -> UsableHours {
        if let source, let hours = activity?.activeHours, let learned = learned(from: hours, source: source, now: now) { return learned }
        return outsideQuietHours(settings)
    }
    func nextStart(from date: Date, calendar: Calendar) -> Date? {
        guard !hours.isEmpty else { return nil }
        var candidate = date
        for _ in 0..<48 {
            if hours.contains(calendar.component(.hour, from: candidate)) { return candidate }
            guard let next = calendar.dateInterval(of: .hour, for: candidate)?.end else { return nil }
            candidate = next
        }
        return nil
    }
}

/// How much of a weekly quota the remaining short windows can still use, as an estimate.
public struct WeeklyReach: Equatable, Sendable {
    public var shortWindowID: String
    public var longWindowID: String
    /// Long-window percentage points per short-window point, learned from history.
    public var ratio: Double
    public var remainingShort: Double
    public var remainingLong: Double
    /// Rest of the current short window plus future windows that start before the long reset.
    public var windowsAvailable: Double

    public static let relevantLoad = 0.7
    static let historySpan: TimeInterval = 14 * 86400
    static let minimumShortPoints = 60.0

    public var capacity: Double { windowsAvailable * 100 * ratio }
    public var windowsNeeded: Double { remainingLong / (100 * ratio) }
    public var expiring: Double { max(0, remainingLong - capacity) }
    /// Share of the reachable capacity the week needs; above 1 part of it expires.
    public var load: Double { capacity > 0 ? remainingLong / capacity : .infinity }
    /// Short-window percentage to leave unused so the week ends evenly spread across the usable windows.
    public var targetRemainingShort: Double { load >= 1 ? 0 : remainingShort * (1 - load) }
    public var isRelevant: Bool { load >= Self.relevantLoad }

    public static func assess(snapshot: AccountSnapshot, history: [AccountSnapshot], hours: UsableHours, now: Date,
                              calendar: Calendar = .current) -> [WeeklyReach] {
        guard snapshot.isFresh(at: now) else { return [] }
        let paced = snapshot.windows.filter { $0.hasValidUsage && $0.supportsPace && QuotaNumbers.date($0.resetsAt).map { $0 > now } == true }
        guard let short = paced.first(where: { isShort($0) }), let shortReset = short.resetsAt, let duration = short.duration else { return [] }
        let history = history.filter { $0.configurationID == snapshot.configurationID && $0.identity == snapshot.identity }
        return paced.filter(isLong).compactMap { long in
            guard let longReset = long.resetsAt, long.usedPercent < 100,
                  let ratio = ratio(shortID: short.id, longID: long.id, history: history, now: now,
                                    minimumLongPoints: isScoped(long) ? 10 : 3) else { return nil }
            let remainingShort = min(100, max(0, 100 - short.usedPercent))
            let future = futureWindows(from: shortReset, until: longReset, duration: duration, hours: hours, calendar: calendar)
            let reach = WeeklyReach(shortWindowID: short.id, longWindowID: long.id, ratio: ratio, remainingShort: remainingShort,
                               remainingLong: 100 - max(0, long.usedPercent), windowsAvailable: remainingShort / 100 + future)
            guard reach.capacity.isFinite, reach.windowsNeeded.isFinite else { return nil }
            return reach
        }
    }
    /// The most demanding relevant weekly target, shown on the short bar.
    public static func shortTarget(in reaches: [WeeklyReach]) -> WeeklyReach? {
        reaches.filter(\.isRelevant).min { $0.targetRemainingShort == $1.targetRemainingShort ? $0.load > $1.load : $0.targetRemainingShort < $1.targetRemainingShort }
    }
    public static func relevant(for windowID: String, in reaches: [WeeklyReach]) -> WeeklyReach? {
        if let target = shortTarget(in: reaches), target.shortWindowID == windowID { return target }
        return reaches.first { $0.longWindowID == windowID && $0.isRelevant }
    }

    static func isShort(_ window: QuotaWindow) -> Bool { QuotaNumbers.duration(window.duration).map { abs($0 - 18000) <= 1800 } ?? false }
    static func isLong(_ window: QuotaWindow) -> Bool { QuotaNumbers.duration(window.duration).map { abs($0 - 604800) <= 3600 } ?? false }
    /// Model/app weeks need more evidence. Unknown scopes keep that conservative threshold.
    static func isScoped(_ window: QuotaWindow) -> Bool {
        window.scope != .account
    }

    /// Sums rather than per-pair ratios, because providers report whole percentages.
    static func ratio(shortID: String, longID: String, history: [AccountSnapshot], now: Date, minimumLongPoints: Double) -> Double? {
        let recent = history.filter { $0.observedAt <= now && now.timeIntervalSince($0.observedAt) <= historySpan }
            .sorted { $0.observedAt < $1.observedAt }
        var shortPoints = 0.0, longPoints = 0.0
        for (old, new) in zip(recent, recent.dropFirst()) {
            guard let oldShort = old.windows.first(where: { $0.id == shortID }), let newShort = new.windows.first(where: { $0.id == shortID }),
                  let oldLong = old.windows.first(where: { $0.id == longID }), let newLong = new.windows.first(where: { $0.id == longID }),
                  QuotaPeriod.matches(window: newShort, snapshot: new, otherWindow: oldShort, otherSnapshot: old),
                  QuotaPeriod.matches(window: newLong, snapshot: new, otherWindow: oldLong, otherSnapshot: old) else { continue }
            let short = newShort.usedPercent - oldShort.usedPercent, long = newLong.usedPercent - oldLong.usedPercent
            // Keep pairs where only the long value ticked; dropping them would bias the ratio low through rounding.
            guard short >= 0, long >= 0 else { continue }
            shortPoints += short; longPoints += long
        }
        guard shortPoints.isFinite, longPoints.isFinite, shortPoints >= minimumShortPoints, longPoints >= minimumLongPoints else { return nil }
        let ratio = longPoints / shortPoints
        guard ratio.isFinite, ratio > 0, (100 * ratio).isFinite else { return nil }
        return ratio
    }

    /// A window starts at the next usable hour and the next one when it ends; the last one counts until the long reset.
    static func futureWindows(from start: Date, until end: Date, duration: TimeInterval, hours: UsableHours, calendar: Calendar) -> Double {
        guard duration > 0 else { return 0 }
        var cursor = start, count = 0.0
        for _ in 0..<100 {
            guard let begin = hours.nextStart(from: cursor, calendar: calendar), begin < end else { break }
            count += min(1, end.timeIntervalSince(begin) / duration)
            cursor = begin.addingTimeInterval(duration)
        }
        return count
    }
}
