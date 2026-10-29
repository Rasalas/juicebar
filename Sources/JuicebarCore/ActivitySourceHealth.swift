import Foundation

/// Evidence belongs to a collection/root or host, not to every tool that it might contain.
public struct ActivitySourceHealth: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case checking, success, cached, stale, unavailable, retained, unknown }
    public var id: String
    public var label: String
    /// nil for an SSH host, which can feed multiple tool kinds.
    public var tools: [ActivitySource]?
    public var phase: Phase
    public var lastSuccess: Date?
    public var issue: String?
    /// Stable coverage limits survive retries and removal; transient transport errors do not.
    public var coverage: [String]?
    /// SSH limits expire with the affected 90-day history, not with later successful checks.
    public var coverageObservedAt: [String: Date]?
    public init(id: String, label: String, tools: [ActivitySource]? = nil, phase: Phase, lastSuccess: Date? = nil, issue: String? = nil, coverage: [String]? = nil) {
        self.id = id; self.label = label; self.tools = tools; self.phase = phase; self.lastSuccess = lastSuccess; self.issue = issue; self.coverage = coverage
    }
    public func includes(_ tool: ActivitySource?) -> Bool { tool == nil || tools == nil || tools!.contains(tool!) }
    mutating func expireCoverage(before date: Date) {
        guard let observed = coverageObservedAt else { return }
        let retained = observed.filter { $0.value >= date }
        coverageObservedAt = retained
        coverage = retained.keys.sorted()
    }
}

extension ActivityReport {
    /// A report loaded from disk has not been verified during this run. In-flight checks did not finish.
    public mutating func markCached() {
        sources = sources?.map { source in
            var source = source
            if source.phase == .success || source.phase == .checking { source.phase = .cached }
            return source
        }
    }
}
