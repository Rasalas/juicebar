import Foundation

/// Bounds provider work without making a slow account block every other account.
/// Generations invalidate both successful and failed results after edits or removal.
@MainActor
public final class AccountRefreshScheduler {
    private struct Job {
        var generation: UUID
        var operation: () async -> Void
    }
    private let limit: Int
    private var queue: [String] = []
    private var pending: [String: Job] = [:]
    private var running: [String: (UUID, Task<Void, Never>)] = [:]
    private var generations: [String: UUID] = [:]
    public var onChange: ((Set<String>) -> Void)?
    public var activeIDs: Set<String> {
        Set(pending.keys).union(running.compactMap { id, job in generations[id] == job.0 ? id : nil })
    }

    public init(maxConcurrent: Int = 3) { limit = max(1, maxConcurrent) }

    public func enqueue(id: String, replacingPending: Bool = false, operation: @escaping (UUID) async -> Void) {
        if pending[id] != nil && !replacingPending { return }
        guard running[id] == nil || generations[id] == nil || pending[id] != nil else { return }
        let generation = generation(for: id)
        let alreadyQueued = pending[id] != nil
        pending[id] = Job(generation: generation, operation: { await operation(generation) })
        if !alreadyQueued { queue.append(id) }
        drain()
    }

    public func generation(for id: String) -> UUID {
        if let value = generations[id] { return value }
        let value = UUID()
        generations[id] = value
        return value
    }

    public func isCurrent(id: String, generation: UUID) -> Bool {
        generations[id] == generation && !Task.isCancelled
    }

    public func invalidate(id: String) {
        generations[id] = nil
        pending[id] = nil
        queue.removeAll { $0 == id }
        // Keep cancelled work counted until the provider actually exits.
        running[id]?.1.cancel()
        onChange?(activeIDs)
    }

    public func cancelAll() {
        for id in Set(generations.keys).union(activeIDs) { invalidate(id: id) }
    }

    public func waitUntilIdle() async {
        while let task = running.values.first?.1 { await task.value }
    }

    private func drain() {
        while running.count < limit, let index = queue.firstIndex(where: { running[$0] == nil }) {
            let id = queue.remove(at: index)
            guard let job = pending.removeValue(forKey: id) else { continue }
            let task = Task {
                await job.operation()
                self.running[id] = nil
                self.drain()
            }
            running[id] = (job.generation, task)
        }
        onChange?(activeIDs)
    }
}
