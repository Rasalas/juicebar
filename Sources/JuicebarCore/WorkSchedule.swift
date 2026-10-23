import Foundation

/// Account-local hours in the user's current calendar and time zone. Disabled until explicitly enabled.
public struct WorkSchedule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Calendar weekday numbers, Sunday = 1.
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int

    public init(isEnabled: Bool = false, weekdays: Set<Int> = [2, 3, 5, 6], startMinute: Int = 480, endMinute: Int = 810) {
        self.isEnabled = isEnabled; self.weekdays = weekdays; self.startMinute = startMinute; self.endMinute = endMinute
    }
    public var isValid: Bool {
        !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) }
            && (0..<1440).contains(startMinute) && (1..<1440).contains(endMinute) && startMinute < endMinute
    }
    public func interval(on date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard isValid, weekdays.contains(calendar.component(.weekday, from: date)),
              let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: date),
              let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: date), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
    public func nextStart(from date: Date, before end: Date, calendar: Calendar = .current) -> Date? {
        guard isValid, date < end else { return nil }
        var day = calendar.startOfDay(for: date)
        for _ in 0..<9 {
            if let interval = interval(on: day, calendar: calendar) {
                let start = max(date, interval.start)
                if start < min(interval.end, end) { return start }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next < end else { break }
            day = next
        }
        return nil
    }
    func activeTime(from start: Date, until end: Date, calendar: Calendar) -> TimeInterval {
        guard start < end else { return 0 }
        var day = calendar.startOfDay(for: start), total: TimeInterval = 0
        for _ in 0..<9 {
            if let interval = interval(on: day, calendar: calendar) {
                total += max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next < end else { break }
            day = next
        }
        return total
    }
}

/// End-of-workday target, or the reserve for upcoming workdays while outside the schedule.
/// Values are always remaining percentages; display-mode conversion belongs to the caller.
public struct WorkPlanTarget: Equatable, Sendable {
    public let longWindowID: String
    public let shortWindowID: String?
    public let targetRemainingLong: Double
    public let targetRemainingShort: Double?
    public let remainingLong: Double
    public let isWorkday: Bool
    public let additionalWindows: Double?
    public var todayRemaining: Double { max(0, remainingLong - targetRemainingLong) }

    public static func assess(snapshot: AccountSnapshot, history: [AccountSnapshot], schedule: WorkSchedule,
                              now: Date, calendar: Calendar = .current) -> [WorkPlanTarget] {
        guard schedule.isEnabled, schedule.isValid, snapshot.isFresh(at: now) else { return [] }
        let recent = history.filter { $0.configurationID == snapshot.configurationID && $0.identity == snapshot.identity && $0.observedAt <= now }
            .sorted { $0.observedAt < $1.observedAt }
        let short = snapshot.windows.first { WeeklyReach.isShort($0) && $0.supportsPace && $0.usedPercent.isFinite }
        return snapshot.windows.filter { WeeklyReach.isLong($0) && $0.supportsPace && $0.usedPercent.isFinite && $0.resetsAt.map { $0 > now } == true }
            .compactMap { long in
                let ratio = short.flatMap {
                    WeeklyReach.ratio(shortID: $0.id, longID: long.id, history: recent, now: now,
                                      minimumLongPoints: WeeklyReach.isScoped(long) ? 10 : 3)
                }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                if WeeklyReach.isScoped(long), ratio == nil { return nil }
                return assess(long: long, short: short, ratio: ratio, snapshot: snapshot, history: recent,
                              schedule: schedule, now: now, calendar: calendar)
            }
    }

    public static func relevant(for windowID: String, in targets: [WorkPlanTarget]) -> WorkPlanTarget? {
        if let long = targets.first(where: { $0.longWindowID == windowID }) { return long }
        return targets.filter { $0.shortWindowID == windowID && $0.targetRemainingShort != nil }
            .min { $0.targetRemainingShort! < $1.targetRemainingShort! }
    }

    private struct Slot {
        let start: Date
        let share: Double
    }
    /// A short window can be consumed quickly; working hours constrain its start, not an agent's finish time.
    private static func slots(short: QuotaWindow, from start: Date, until end: Date, schedule: WorkSchedule, calendar: Calendar) -> [Slot]? {
        guard let duration = short.duration, duration > 0, start < end else { return [] }
        var result: [Slot] = [], cursor = start
        if let reset = short.resetsAt {
            if reset > start {
                if let begin = schedule.nextStart(from: start, before: min(reset, end), calendar: calendar) {
                    result.append(Slot(start: begin, share: max(0, min(1, (100 - short.usedPercent) / 100))))
                }
                cursor = reset
            }
        } else if short.usedPercent > 0 { return nil }
        for _ in 0..<100 {
            guard let begin = schedule.nextStart(from: cursor, before: end, calendar: calendar) else { break }
            result.append(Slot(start: begin, share: min(1, end.timeIntervalSince(begin) / duration)))
            cursor = begin.addingTimeInterval(duration)
        }
        return result
    }

    private static func assess(long: QuotaWindow, short: QuotaWindow?, ratio: Double?, snapshot: AccountSnapshot,
                               history: [AccountSnapshot], schedule: WorkSchedule, now: Date, calendar: Calendar) -> WorkPlanTarget {
        let reset = long.resetsAt!, remaining = max(0, min(100, 100 - long.usedPercent))
        let workday = schedule.interval(on: now, calendar: calendar).flatMap { now < $0.end ? $0 : nil }
        let currentSlots = short.flatMap { slots(short: $0, from: now, until: reset, schedule: schedule, calendar: calendar) }
        let capacity = ratio.flatMap { r in currentSlots.map { $0.reduce(0) { $0 + $1.share } * 100 * r } }
        let additional = capacity.flatMap { c in ratio.map { max(0, remaining - c) / (100 * $0) } }
        let target: Double
        if let workday {
            // Anchor at the start of today's work. Consuming the daily allocation must reach a stable marker.
            let weekStart = reset.addingTimeInterval(-(long.duration ?? 604800))
            let samples = history.filter { sample in
                sample.observedAt >= max(weekStart, workday.start.addingTimeInterval(-86400))
                    && sample.windows.contains { QuotaPeriod.matches(window: $0, snapshot: sample, otherWindow: long, otherSnapshot: snapshot) }
            }
            let baseline = samples.last(where: { $0.observedAt <= workday.start }) ?? samples.first ?? snapshot
            let baselineLong = baseline.windows.first { $0.id == long.id } ?? long
            let baselineRemaining = max(0, min(100, 100 - baselineLong.usedPercent))
            let origin = max(workday.start, baseline.observedAt, weekStart)
            let baselineShort = short.flatMap { current in baseline.windows.first { $0.id == current.id } }
            if let ratio, let baselineShort,
               let all = slots(short: baselineShort, from: origin, until: reset, schedule: schedule, calendar: calendar) {
                let total = all.reduce(0) { $0 + $1.share } * 100 * ratio
                let today = all.filter { $0.start < workday.end }.reduce(0) { $0 + $1.share } * 100 * ratio
                let load = total > 0 ? min(1, baselineRemaining / total) : 0
                target = max(0, baselineRemaining - today * load)
            } else {
                // Weekly-only plans still get a workday target; no claim about 5h capacity without measurements.
                let total = schedule.activeTime(from: origin, until: reset, calendar: calendar)
                let today = schedule.activeTime(from: origin, until: min(workday.end, reset), calendar: calendar)
                target = total > 0 ? max(0, baselineRemaining * (1 - today / total)) : baselineRemaining
            }
        } else {
            // Outside working hours, preserve what regular upcoming starts can consume.
            target = min(100, capacity ?? remaining)
        }
        let shortRemaining = short.map { max(0, min(100, 100 - $0.usedPercent)) }
        // Preserve overspending as well as available budget. Clamping the weekly difference to zero
        // would pin the short marker to the current fill whenever the weekly reserve is exceeded.
        let shortTarget = ratio.flatMap { r in shortRemaining.map { min(100, max(0, $0 - (remaining - target) / r)) } }
        return WorkPlanTarget(longWindowID: long.id, shortWindowID: shortTarget == nil ? nil : short?.id,
                              targetRemainingLong: target, targetRemainingShort: shortTarget,
                              remainingLong: remaining, isWorkday: workday != nil, additionalWindows: additional)
    }
}
