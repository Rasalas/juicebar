import Foundation

/// Retry and history cadence are independent for each account.
public struct AccountRefreshPolicy {
    private var nextFetch: [String: Date] = [:]
    private var rateLimitedUntil: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var lastHistory: [String: Date] = [:]
    public init() {}

    public func isDue(id: String, force: Bool, now: Date) -> Bool {
        if let until = rateLimitedUntil[id], until > now { return false }
        return force || (nextFetch[id] ?? .distantPast) <= now
    }
    public func includesHistory(id: String, now: Date) -> Bool {
        lastHistory[id].map { now.timeIntervalSince($0) > 1800 } ?? true
    }
    public mutating func succeeded(account: AccountConfiguration, refreshSeconds: Double, includedHistory: Bool, now: Date) {
        failures[account.id] = nil
        if includedHistory { lastHistory[account.id] = now }
        let minimum: Double = account.provider == .anthropicAPI || account.provider == .openaiAPI ? 300 : 60
        nextFetch[account.id] = now.addingTimeInterval(max(refreshSeconds, minimum))
    }
    public mutating func failed(id: String, error: Error, refreshSeconds: Double, now: Date) {
        let count = min((failures[id] ?? 0) + 1, 5)
        failures[id] = count
        var delay = max(60, refreshSeconds) * pow(2, Double(count - 1))
        if case ProviderFailure.rateLimited(let retry) = error {
            delay = retry
            rateLimitedUntil[id] = now.addingTimeInterval(retry)
        }
        nextFetch[id] = now.addingTimeInterval(min(delay, 86400))
        if case ProviderFailure.needsSetup = error { nextFetch[id] = .distantFuture }
    }
    public mutating func remove(id: String) {
        nextFetch[id] = nil; rateLimitedUntil[id] = nil
        failures[id] = nil; lastHistory[id] = nil
    }
}
