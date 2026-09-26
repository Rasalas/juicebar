import Foundation

/// A description of quota health, independent of notification preferences and display direction.
public enum QuotaStatus: Equatable, Sendable {
    case unavailable, exhausted
    case projectedPaceCrossing(Date)
    case projectedExhaustion(Date)

    public static func assess(window: QuotaWindow, snapshot: AccountSnapshot, history: [AccountSnapshot],
                              now: Date, hasFailure: Bool = false) -> QuotaStatus {
        guard !hasFailure, snapshot.isFresh(at: now), window.resetsAt.map({ $0 > now }) ?? true else { return .unavailable }
        if window.usedPercent >= 100 { return .exhausted }
        // Recent activity is useful for an imminent limit, not a multi-day extrapolation.
        guard let projection = WarningEngine.projection(window: window, snapshot: snapshot, history: history, now: now) else {
            return .unavailable
        }
        if projection.reachesLimitAt.timeIntervalSince(now) <= 2 * 3600 {
            return .projectedExhaustion(projection.reachesLimitAt)
        }
        guard let ideal = window.idealPercent(at: now), ideal >= 5,
              let duration = window.duration, let reset = window.resetsAt else { return .unavailable }
        let headroom = ideal - window.usedPercent
        // Both usage and the target advance. Only their relative speed consumes the headroom.
        let closingRate = projection.percentPerHour - 100 * 3600 / duration
        guard headroom > 0, closingRate > 0 else { return .unavailable }
        let seconds = headroom / closingRate * 3600
        let crossing = now.addingTimeInterval(seconds)
        guard seconds.isFinite, seconds > 0, seconds <= 2 * 3600, crossing < reset else { return .unavailable }
        return .projectedPaceCrossing(crossing)
    }
}
