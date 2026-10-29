import Foundation

/// All expensive work runs on the import worker. Archives contain only usage metadata.
public enum ActivityImport {
    /// SSH hosts are read less often than local logs; a manual refresh or an unfinished import reads them sooner.
    public static let remoteInterval: TimeInterval = 1800
    private struct Archive: Codable {
        var events: CompactEvents
        var observedAt: Date
        var fingerprint: String?
        var notices: [String]?
        var retainedSource: ActivitySource?
        var summary: LocalUsageReport?
    }
    /// Decoded state files, reused while the file on disk is still the one this process last read or wrote.
    private final class Decoded: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: (stamp: String, value: Any)] = [:]
        private func stamp(_ url: URL) -> String? {
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path), let size = values[.size] as? NSNumber,
                  let date = values[.modificationDate] as? Date, let inode = values[.systemFileNumber] as? NSNumber else { return nil }
            return "\(inode)|\(size)|\(date.timeIntervalSince1970)"
        }
        func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
            guard let stamp = stamp(url) else { forget(url); return nil }
            if let hit = lock.withLock({ values[url.path] }), hit.stamp == stamp, let value = hit.value as? T { return value }
            guard let data = try? Data(contentsOf: url), let value = try? PropertyListDecoder().decode(T.self, from: data) else { return nil }
            lock.withLock { values[url.path] = (stamp, value) }
            return value
        }
        func save<T: Encodable>(_ value: T, to url: URL) throws {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(value).write(to: url, options: .atomic)
            remember(value, for: url)
        }
        func saveIfChanged<T: Codable & Equatable>(_ value: T, to url: URL) throws {
            if load(T.self, from: url) != value { try save(value, to: url) }
        }
        /// Keeps a newer value for an unchanged file, for example a later observation time that is not worth a rewrite.
        func remember(_ value: Any, for url: URL) {
            let stamp = stamp(url)
            lock.withLock { values[url.path] = stamp.map { ($0, value) } }
        }
        func forget(_ url: URL) { lock.withLock { values[url.path] = nil } }
        /// Only the kept value, without reading the file.
        func memory<T>(_ type: T.Type, for url: URL) -> T? {
            guard let stamp = stamp(url), let hit = lock.withLock({ values[url.path] }), hit.stamp == stamp else { return nil }
            return hit.value as? T
        }
    }
    /// An SSH host between reads: its parsers stay on disk until the host is due again.
    private struct Remote {
        var observedAt: Date?
        var archiveValid = true
        var complete: Bool
        var notices: [String]
        var events: CompactEvents
        init(_ state: SSHActivity.State, since: Date) {
            observedAt = state.observedAt; complete = state.complete; notices = state.notices
            events = CompactEvents(state.events(since: since, now: .distantFuture))
        }
    }
    private static let decoded = Decoded()

    private static func changed(_ old: [String: ActivityEvent], _ new: [String: ActivityEvent]) -> Bool {
        old.count != new.count || new.contains { key, event in
            guard let before = old[key] else { return true }
            return before.date != event.date || before.tokens != event.tokens || before.model != event.model || before.provider != event.provider
                || before.usage?.input != event.usage?.input || before.usage?.output != event.usage?.output
                || before.usage?.cacheRead != event.usage?.cacheRead || before.usage?.cacheWrite != event.usage?.cacheWrite
                || before.usage?.cacheWriteHour != event.usage?.cacheWriteHour || before.reportedCost != event.reportedCost
                || before.responseCount != event.responseCount || before.sessionStartedAt != event.sessionStartedAt
        }
    }

    /// The same request drives UI imports, command-line verification and synthetic collectors.
    public struct Request: Sendable {
        public var roots: [ActivityLogs.Root]
        public var databasePath: String?
        public var hosts: [String]
        public var directory: URL
        public var now: Date
        public var refreshRemote: Bool
        public init(roots: [ActivityLogs.Root], databasePath: String?, hosts: [String], directory: URL,
                    now: Date = Date(), refreshRemote: Bool = true) {
            self.roots = roots; self.databasePath = databasePath; self.hosts = hosts; self.directory = directory
            self.now = now; self.refreshRemote = refreshRemote
        }
    }
    public typealias Result = (ActivityReport, LocalUsageReport?)
    public typealias Publication = @Sendable (ActivityReport, LocalUsageReport?) async -> Void
    public typealias Reader = @Sendable (Request, Control, @escaping Publication) async throws -> Void
    public static let remoteConcurrency = 3

    /// Cancellation gates queued durable writes. An already accepted commit finishes on its worker; cancellation never waits for disk I/O.
    public final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        public init() {}
        public func cancel() { lock.withLock { cancelled = true } }
        public func check() throws {
            try Task.checkCancellation()
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
        public func commit<T>(_ action: () throws -> T) throws -> T {
            try check()
            // Accept under the short state lock, then perform I/O without blocking UI cancellation.
            try lock.withLock { if cancelled { throw CancellationError() } }
            return try action()
        }
    }
    // One writer per directory, including cancelled SSH checkpoint cleanup. A replacement cannot race old parsers.
    private final class Leases: @unchecked Sendable {
        let lock = NSLock()
        var paths = Set<String>()
        func acquire(_ directory: URL, control: Control) throws {
            let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
            while true {
                try control.check()
                if lock.withLock({ paths.insert(path).inserted }) { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        func release(_ directory: URL) { _ = lock.withLock { paths.remove(directory.standardizedFileURL.resolvingSymlinksInPath().path) } }
    }
    private static let leases = Leases()
    // Internal adapter uses the production cache/scheduler/publication path, without real SSH in tests.
    struct Collectors: Sendable {
        var remote: @Sendable (String, inout SSHActivity.State, Date) throws -> Void = { try SSHActivity.read(host: $0, state: &$1, now: $2) }
    }

    public static func read(roots: [ActivityLogs.Root], databasePath: String?, hosts: [String], directory: URL,
                            now: Date = Date(), refreshRemote: Bool = true, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> Result {
        let request = Request(roots: roots, databasePath: databasePath, hosts: hosts, directory: directory, now: now, refreshRemote: refreshRemote)
        let control = Control()
        try leases.acquire(directory, control: control)
        defer { leases.release(directory) }
        let session = try Session(request, control: control, progress: progress)
        try session.readLocal()
        for job in try session.prepareRemote() { session.accept(try job.read(control: control, collectors: Collectors())) }
        return try session.report()
    }

    public static func readProgressively(_ request: Request, control: Control = Control(), publish: @escaping Publication) async throws {
        try await readProgressively(request, control: control, collectors: Collectors(), publish: publish)
    }

    static func readProgressively(_ request: Request, control: Control = Control(), collectors: Collectors, publish: @escaping Publication) async throws {
        try leases.acquire(request.directory, control: control)
        defer { leases.release(request.directory) }
        let session = try Session(request, control: control)
        try session.readLocal()
        let jobs = try session.prepareRemote()
        let initial = try session.report()
        try control.check()
        await publish(initial.0, initial.1)
        try await withThrowingTaskGroup(of: RemoteResult.self) { group in
            var iterator = jobs.makeIterator()
            func enqueue() throws {
                try control.check()
                if let job = iterator.next() { group.addTask { try job.read(control: control, collectors: collectors) } }
            }
            for _ in 0..<min(remoteConcurrency, jobs.count) { try enqueue() }
            while let result = try await group.next() {
                try control.check()
                session.accept(result)
                let report = try session.report()
                try control.check()
                await publish(report.0, report.1)
                try enqueue()
            }
        }
    }

    private struct RemoteResult {
        var index: Int
        var kept: Remote
        var health: ActivitySourceHealth
    }
    private struct RemoteJob {
        var index: Int
        var host: String
        var url: URL
        var legacy: URL
        var health: ActivitySourceHealth
        var now: Date
        func load() -> (state: SSHActivity.State, valid: Bool) {
            let archive = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode(SSHActivity.State.self, from: $0) }
            var state = archive ?? SSHActivity.State()
            if state.observedAt == nil, state.carried.isEmpty, let archive = decoded.load(Archive.self, from: legacy) { state.carried = archive.events.events() }
            if let lastSuccess = health.lastSuccess { state.observedAt = lastSuccess }
            return (state, archive != nil)
        }
        func read(control: Control, collectors: Collectors) throws -> RemoteResult {
            try control.check()
            let loaded = load()
            var state = loaded.state, health = health
            let revision = state.revision
            state.complete = false
            func failedPhase() -> ActivitySourceHealth.Phase {
                health.lastSuccess == nil || (!loaded.valid && state.revision == revision) ? .unavailable : .stale
            }
            func store(checkpoint: Bool = false) throws {
                let save = {
                    if state.revision != revision || !FileManager.default.fileExists(atPath: url.path) {
                        state.prune(since: now.addingTimeInterval(-90 * 86400))
                        try decoded.save(state, to: url)
                        try? FileManager.default.removeItem(at: legacy); decoded.forget(legacy)
                    }
                    // A small sidecar persists successful observations even when no parser bytes changed.
                    try decoded.saveIfChanged(health, to: url.appendingPathExtension("health"))
                    decoded.forget(url)
                }
                if checkpoint { try save() } else { try control.commit(save) }
            }
            do {
                try collectors.remote(host, &state, now)
                try control.check()
                health.phase = .success; health.lastSuccess = state.observedAt; health.issue = nil; health.coverage = state.notices
            } catch is CancellationError {
                health.phase = failedPhase()
                // Only completed files/checkpoints survive cancellation, never a completed report publication.
                try? store(checkpoint: true)
                throw CancellationError()
            } catch {
                health.phase = failedPhase()
                health.issue = error.localizedDescription
            }
            do { try store() }
            catch is CancellationError {
                health.lastSuccess = self.health.lastSuccess
                health.phase = failedPhase()
                try? store(checkpoint: true)
                throw CancellationError()
            }
            let kept = Remote(state, since: now.addingTimeInterval(-90 * 86400))
            decoded.remember(kept, for: url)
            return RemoteResult(index: index, kept: kept, health: health)
        }
    }

    /// One compact event builder, never merged day totals. Only this task mutates it; host workers own their parser state.
    private final class Session {
        let request: Request, control: Control
        let progress: @Sendable (String) -> Void
        let archives: URL, since: Date, now: Date
        let fm = FileManager.default
        var builder: ActivityReport.Builder
        var warnings: [String] = [], notices: [String] = []
        var activeArchives = Set<String>(), activeHealth = Set<String>()
        var health: [String: ActivitySourceHealth]
        var remoteNotices: [Int: [String]] = [:]
        var local: LocalUsageReport?
        var claudeDays: [ActivityDay] = []
        init(_ request: Request, control: Control, progress: @escaping @Sendable (String) -> Void = { _ in }) throws {
            self.request = request; self.control = control; self.progress = progress
            now = request.now; since = request.now.addingTimeInterval(-90 * 86400)
            archives = request.directory.appendingPathComponent("activity-sources")
            builder = ActivityReport.Builder(now: request.now)
            try fm.createDirectory(at: archives, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            health = decoded.load([String: ActivitySourceHealth].self, from: archives.appendingPathComponent("local-health.plist")) ?? [:]
        }
        func collect(_ key: String, label: String, fingerprint: (() throws -> String)? = nil, retainedSource: ActivitySource? = nil,
                     read: () throws -> (events: [ActivityEvent], notices: [String], summary: LocalUsageReport?)) throws -> LocalUsageReport? {
            let prefix = retainedSource == .kilo ? "kilo-" : ""
            let url = archives.appendingPathComponent(prefix + stableID(key) + ".plist")
            activeArchives.insert(url.lastPathComponent)
            let sourceID = stableID(key)
            let tools: [ActivitySource] = [retainedSource ?? .opencode]
            let lastSuccess = health[sourceID]?.lastSuccess
            func status(_ phase: ActivitySourceHealth.Phase, at: Date?, issue: String? = nil) {
                health[sourceID] = ActivitySourceHealth(id: sourceID, label: label, tools: tools, phase: phase, lastSuccess: at, issue: issue, coverage: health[sourceID]?.coverage)
                activeHealth.insert(sourceID)
            }
            let previous = decoded.load(Archive.self, from: url)
            do {
                try control.check()
                let stamp = try fingerprint?()
                if let stamp, let previous, previous.fingerprint == stamp,
                   now >= previous.observedAt, now.timeIntervalSince(previous.observedAt) < 3600 {
                    warnings += previous.notices ?? []
                    var summary = previous.summary
                    summary?.observedAt = now
                    previous.events.forEach(since: since, through: now) { builder.add($0) }
                    status(.success, at: now)
                    health[sourceID]?.coverage = previous.notices
                    return summary
                }
                let result = try read()
                let retained = Dictionary((previous?.events.events(since: since, through: now) ?? []).map { ("\($0.source.rawValue)|\($0.id)", $0) }, uniquingKeysWith: ActivityEvent.preferred)
                var unique = retained
                // Retained data comes first: an equally complete reread may correct any metadata, even at equal totals.
                for event in result.events {
                    let key = "\(event.source.rawValue)|\(event.id)"
                    unique[key] = unique[key].map { ActivityEvent.preferred($0, event) } ?? event
                }
                try control.check()
                // Retained history can still contain a previously limited import. A successful retry
                // clears transport failures, not known historical coverage limits.
                let coverage = Array(Set((retained.isEmpty ? [] : previous?.notices ?? []) + result.notices)).sorted()
                var summary = result.summary
                summary?.events = []
                let events = Array(unique.values)
                let archive = Archive(events: CompactEvents(events), observedAt: now, fingerprint: stamp, notices: coverage, retainedSource: retainedSource, summary: summary)
                // Re-reading an unchanged source must not rewrite a large archive.
                if let previous, previous.notices ?? [] == coverage, previous.summary?.models == summary?.models,
                   previous.summary?.notice == summary?.notice, previous.summary?.messageCount == summary?.messageCount, !changed(retained, unique) {
                    decoded.remember(archive, for: url)
                } else { try control.commit { try decoded.save(archive, to: url) } }
                warnings += coverage
                for event in events { builder.add(event) }
                status(.success, at: now)
                health[sourceID]?.coverage = coverage
                return summary
            } catch is CancellationError { throw CancellationError() }
            catch {
                status(lastSuccess != nil || previous != nil ? .stale : .unavailable, at: lastSuccess ?? previous?.observedAt, issue: tr("Quelle konnte nicht vollständig gelesen werden."))
                if let previous {
                    health[sourceID]?.coverage = previous.notices
                    warnings += previous.notices ?? []
                    warnings.append(tr("{0}: letzter erfolgreicher Stand vom {1} bleibt erhalten. {2}", label, (lastSuccess ?? previous.observedAt).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale)), error.localizedDescription))
                    previous.events.forEach(since: since, through: now) { builder.add($0) }
                    var summary = previous.summary
                    summary?.observedAt = lastSuccess ?? previous.observedAt
                    return summary
                }
                warnings.append("\(label): \(error.localizedDescription)")
                return nil
            }
        }
        private func rootLabel(_ root: ActivityLogs.Root) -> String {
            // Configured paths already live in preferences. Usage metadata needs only an opaque identity and display ordinal.
            tr("{0} · lokale Quelle {1}", root.source.name, (request.roots.firstIndex(of: root) ?? 0) + 1)
        }
        func readLocal() throws {
            let roots = request.roots, databasePath = request.databasePath, directory = request.directory
            warnings += try ActivityLogs.read(roots: roots, cacheDirectory: directory.appendingPathComponent("activity-cache"), now: now, progress: progress, health: { root, success, issues in
                let id = stableID(root.id)
                health[id] = ActivitySourceHealth(id: id, label: rootLabel(root), tools: [root.source],
                    phase: success ? .success : health[id]?.lastSuccess == nil ? .unavailable : .stale,
                    lastSuccess: success ? now : health[id]?.lastSuccess, issue: success ? nil : issues.first, coverage: success ? issues : health[id]?.coverage)
                activeHealth.insert(id)
            }) { builder.add($0) }
            for root in roots where root.source == .kilo {
                _ = try collect("kilo|\(root.url.path)", label: rootLabel(root),
                                fingerprint: {
                                    guard self.fm.fileExists(atPath: root.url.path) else { throw ProviderFailure.unavailable(tr("Lokale Quelle nicht gefunden.")) }
                                    return try KiloHistory.fingerprint(root: root.url)
                                }, retainedSource: .kilo) {
                    let result = try KiloHistory.read(root: root.url, now: now)
                    return (result.events, result.notices, nil)
                }
            }
            local = try collect("opencode|\(databasePath ?? "default")", label: tr("OpenCode lokal"),
                                    fingerprint: { try OpenCodeHistory.fingerprint(path: databasePath) }) {
                let report = try OpenCodeHistory.read(path: databasePath, now: now, lookbackDays: 90)
                return (report.events, report.importWarnings ?? [], report)
            }
            // Removing a local folder stops reads, while already imported usage still expires after 90 days.
            for file in try fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("kilo-") && file.pathExtension == "plist" && !activeArchives.contains(file.lastPathComponent) {
                try control.check()
                guard var archive = decoded.load(Archive.self, from: file), archive.retainedSource == .kilo else { continue }
                let retained = archive.events.events(since: since, through: now)
                for event in retained { builder.add(event) }
                if !retained.isEmpty { warnings += archive.notices ?? [] }
                if retained.isEmpty { try? fm.removeItem(at: file); decoded.forget(file) }
                else if retained.count != archive.events.count {
                    archive.events = CompactEvents(retained)
                    try decoded.save(archive, to: file)
                }
            }
            for id in Array(health.keys) where !activeHealth.contains(id) {
                if let success = health[id]?.lastSuccess, success >= since { health[id]?.phase = .retained; health[id]?.issue = nil }
                else { health[id] = nil }
            }
            try control.check()
            try control.commit { try decoded.saveIfChanged(health, to: archives.appendingPathComponent("local-health.plist")) }
            var stats = ActivityReport(events: [], now: now)
            ClaudeHistory.supplement(&stats, roots: roots.filter { $0.source == .claude }.map { $0.url.deletingLastPathComponent() }, now: now)
            claudeDays = stats.days
        }
        func prepareRemote() throws -> [RemoteJob] {
            var jobs: [RemoteJob] = [], seen = Set<String>()
            for (index, host) in request.hosts.enumerated() where seen.insert(host).inserted {
                try control.check()
                let url = archives.appendingPathComponent("ssh-" + stableID("ssh|\(host)") + ".plist")
                let legacy = archives.appendingPathComponent(stableID("ssh|\(host)") + ".plist")
                let saved = decoded.load(ActivitySourceHealth.self, from: url.appendingPathExtension("health"))
                var job = RemoteJob(index: index, host: host, url: url, legacy: legacy,
                    health: saved ?? ActivitySourceHealth(id: "ssh|\(host)", label: host, phase: .cached), now: now)
                var kept = decoded.memory(Remote.self, for: url) ?? {
                    let loaded = job.load()
                    var remote = Remote(loaded.state, since: since)
                    remote.archiveValid = loaded.valid
                    return remote
                }()
                // Legacy host caches have an observation but no health sidecar.
                if saved == nil { job.health.lastSuccess = kept.observedAt }
                if let saved { kept.observedAt = saved.lastSuccess; kept.complete = kept.archiveValid && (saved.phase == .success || saved.phase == .cached) }
                let due = SSHActivity.isDue(observedAt: kept.observedAt, complete: kept.complete, now: now, force: request.refreshRemote)
                job.health.phase = due ? .checking : .cached
                health[job.health.id] = job.health
                kept.events.forEach(since: since, through: now) { builder.add($0, priority: index + 1) }
                remoteNotices[index] = kept.notices
                if due { jobs.append(job) }
            }
            if !request.hosts.isEmpty { notices.append(tr("SSH-Quellen: {0}. Bei Verbindungsfehlern bleiben bereits eingelesene Werte erhalten.", request.hosts.joined(separator: ", "))) }
            return jobs
        }
        func accept(_ result: RemoteResult) {
            health[result.health.id] = result.health
            remoteNotices[result.index] = result.kept.notices
            result.kept.events.forEach(since: since, through: now) { builder.add($0, priority: result.index + 1) }
        }
        func report() throws -> Result {
            try control.check()
            var report = builder.report(notices: notices, warnings: warnings + remoteNotices.keys.sorted().flatMap { remoteNotices[$0]! })
            report.sources = health.values.sorted { $0.id < $1.id }
            let detailedDays = Set(report.days.filter { $0.source == .claude }.map(\.day))
            let recovered = claudeDays.filter { !detailedDays.contains($0.day) }
            if !recovered.isEmpty {
                report.days += recovered
                report.days.sort { $0.day == $1.day ? $0.source.rawValue < $1.source.rawValue : $0.day < $1.day }
                report.notices.append(tr("{0} ältere Claude-Tage aus dem Statistik-Cache ergänzt. Nachrichten enthalten auch Nutzer- und Werkzeugnachrichten. Für diese Tageswerte fehlen die Token-Arten zur Kostenberechnung.", recovered.count))
            }
            local?.events = []
            return (report, local)
        }
    }
}
