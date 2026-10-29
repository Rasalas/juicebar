import Foundation

/// Evidence belongs to a collection/root or host, not to every tool that it might contain.
public struct ActivitySourceHealth: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case checking, success, cached, stale, unavailable, retained }
    public var id: String
    public var label: String
    /// nil for an SSH host, which can feed multiple tool kinds.
    public var tools: [ActivitySource]?
    public var phase: Phase
    public var lastSuccess: Date?
    public var issue: String?
    /// Stable coverage limits survive retries and removal; transient transport errors do not.
    public var coverage: [String]?
    public init(id: String, label: String, tools: [ActivitySource]? = nil, phase: Phase, lastSuccess: Date? = nil, issue: String? = nil, coverage: [String]? = nil) {
        self.id = id; self.label = label; self.tools = tools; self.phase = phase; self.lastSuccess = lastSuccess; self.issue = issue; self.coverage = coverage
    }
    public func includes(_ tool: ActivitySource?) -> Bool { tool == nil || tools == nil || tools!.contains(tool!) }
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
