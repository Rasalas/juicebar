import Foundation

/// Retry and history cadence are independent for each account.
public struct AccountRefreshPolicy {
    /// Longest delay after a success; snapshot freshness depends on it.
    public static let maximumInterval: TimeInterval = 900
    private struct Deadline { var at: Date; var delay: TimeInterval }
    private var nextFetch: [String: Deadline] = [:]
    private var rateLimitedUntil: [String: Deadline] = [:]
    private var failures: [String: Int] = [:]
    private var unchangedResults: [String: Int] = [:]
    private var lastHistory: [String: Date] = [:]
    public var lowPowerMode = false
    public init() {}

    public func isDue(id: String, force: Bool, now: Date) -> Bool {
        if let until = rateLimitedUntil[id], until.at > now { return false }
        return force || (nextFetch[id]?.at ?? .distantPast) <= now
    }
    /// A manual retry may bypass ordinary backoff, but never the provider's cooldown.
    public func retryAllowedAt(id: String, now: Date) -> Date? {
        guard let until = rateLimitedUntil[id]?.at, until > now else { return nil }
        return until
    }
    public func includesHistory(id: String, now: Date) -> Bool {
        lastHistory[id].map { now.timeIntervalSince($0) > 1800 } ?? true
    }
    /// Pass `unchanged` only for automatic checks; a manual or wake refresh resets the backoff.
    public mutating func succeeded(account: AccountConfiguration, refreshSeconds: Double, includedHistory: Bool, unchanged: Bool = false, now: Date) {
        failures[account.id] = nil
        if includedHistory { lastHistory[account.id] = now }
        let streak = unchanged ? (unchangedResults[account.id] ?? 0) + 1 : 0
        unchangedResults[account.id] = streak
        let minimum: Double = account.provider == .anthropicAPI || account.provider == .openaiAPI ? 300 : 60
        let base = max(refreshSeconds, minimum)
        let stretch = min(3, (1 + Double(streak) / 2) * (lowPowerMode ? 2 : 1))
        let delay = min(base * stretch, max(base, Self.maximumInterval))
        nextFetch[account.id] = Deadline(at: now.addingTimeInterval(delay), delay: delay)
    }
    public mutating func failed(id: String, error: Error, refreshSeconds: Double, now: Date) {
        let count = min((failures[id] ?? 0) + 1, 5)
        failures[id] = count
        var delay = max(60, refreshSeconds) * pow(2, Double(count - 1))
        if case ProviderFailure.rateLimited(let retry) = error {
            delay = retry
            rateLimitedUntil[id] = Deadline(at: now.addingTimeInterval(retry), delay: retry)
        }
        delay = min(delay, 86400)
        nextFetch[id] = Deadline(at: now.addingTimeInterval(delay), delay: delay)
        if case ProviderFailure.needsSetup = error { nextFetch[id] = Deadline(at: .distantFuture, delay: .infinity) }
    }
    /// A clock set backwards must not postpone checks by more than their own delay.
    public mutating func clamp(now: Date) {
        for (id, deadline) in nextFetch where deadline.at.timeIntervalSince(now) > deadline.delay {
            nextFetch[id]?.at = now.addingTimeInterval(deadline.delay)
        }
        for (id, deadline) in rateLimitedUntil where deadline.at.timeIntervalSince(now) > deadline.delay {
            rateLimitedUntil[id]?.at = now.addingTimeInterval(deadline.delay)
        }
        for (id, date) in lastHistory where date > now { lastHistory[id] = now }
    }
    public mutating func remove(id: String) {
        nextFetch[id] = nil; rateLimitedUntil[id] = nil
        failures[id] = nil; lastHistory[id] = nil; unchangedResults[id] = nil
    }
    /// Only the reported quota counts; reset times may drift by seconds between polls.
    public static func quotaUnchanged(from previous: AccountSnapshot?, to current: AccountSnapshot) -> Bool {
        guard let previous, previous.identity == current.identity else { return false }
        return previous.windows.map { [$0.id: $0.usedPercent] } == current.windows.map { [$0.id: $0.usedPercent] }
            && previous.money.map(\.amount) == current.money.map(\.amount)
    }
}
