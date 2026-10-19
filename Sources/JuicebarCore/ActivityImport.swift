import Foundation

/// All expensive work runs on the import worker. Archives contain only usage metadata.
public enum ActivityImport {
    /// SSH hosts are read less often than local logs; a manual refresh or an unfinished import reads them sooner.
    public static let remoteInterval: TimeInterval = 1800
    private struct Archive: Codable {
        var events: [ActivityEvent]
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
        /// Keeps a newer value for an unchanged file, for example a later observation time that is not worth a rewrite.
        func remember(_ value: Any, for url: URL) {
            let stamp = stamp(url)
            lock.withLock { values[url.path] = stamp.map { ($0, value) } }
        }
        func forget(_ url: URL) { lock.withLock { values[url.path] = nil } }
    }
    private static let decoded = Decoded()

    private static func changed(_ old: [String: ActivityEvent], _ new: [String: ActivityEvent]) -> Bool {
        old.count != new.count || new.contains { key, event in
            guard let before = old[key] else { return true }
            return before.date != event.date || before.tokens != event.tokens || before.model != event.model || before.provider != event.provider
                || before.usage?.total != event.usage?.total || before.reportedCost != event.reportedCost
                || before.responseCount != event.responseCount || before.sessionStartedAt != event.sessionStartedAt
        }
    }

    public static func read(roots: [ActivityLogs.Root], databasePath: String?, hosts: [String], directory: URL,
                            now: Date = Date(), refreshRemote: Bool = true, progress: @Sendable (String) -> Void = { _ in }) throws -> (ActivityReport, LocalUsageReport?) {
        let fm = FileManager.default
        let archives = directory.appendingPathComponent("activity-sources")
        try fm.createDirectory(at: archives, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var warnings: [String] = [], notices: [String] = []
        var activeArchives = Set<String>()
        let since = now.addingTimeInterval(-90 * 86400)
        func collect(_ key: String, label: String, fingerprint: (() throws -> String)? = nil, retainedSource: ActivitySource? = nil,
                     read: () throws -> (events: [ActivityEvent], notices: [String], summary: LocalUsageReport?)) throws -> (events: [ActivityEvent], summary: LocalUsageReport?) {
            let prefix = retainedSource == .kilo ? "kilo-" : ""
            let url = archives.appendingPathComponent(prefix + stableID(key) + ".plist")
            activeArchives.insert(url.lastPathComponent)
            let previous = decoded.load(Archive.self, from: url)
            do {
                try Task.checkCancellation()
                let stamp = try fingerprint?()
                if let stamp, let previous, previous.fingerprint == stamp,
                   now >= previous.observedAt, now.timeIntervalSince(previous.observedAt) < 3600 {
                    warnings += previous.notices ?? []
                    var summary = previous.summary
                    summary?.observedAt = now
                    return (previous.events.filter { $0.date >= since && $0.date <= now }, summary)
                }
                let result = try read()
                let retained = Dictionary((previous?.events ?? []).filter { $0.date >= since && $0.date <= now }.map { ("\($0.source.rawValue)|\($0.id)", $0) }, uniquingKeysWith: ActivityEvent.preferred)
                var unique = retained
                for event in result.events {
                    let key = "\(event.source.rawValue)|\(event.id)"
                    unique[key] = unique[key].map { ActivityEvent.preferred($0, event) } ?? event
                }
                try Task.checkCancellation()
                var summary = result.summary
                summary?.events = []
                let archive = Archive(events: Array(unique.values), observedAt: now, fingerprint: stamp, notices: result.notices, retainedSource: retainedSource, summary: summary)
                // Re-reading an unchanged source must not rewrite a large archive.
                if let previous, previous.notices ?? [] == result.notices, (previous.summary == nil) == (summary == nil), !changed(retained, unique) {
                    decoded.remember(archive, for: url)
                } else { try decoded.save(archive, to: url) }
                warnings += result.notices
                return (archive.events, summary)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if let previous {
                    warnings += previous.notices ?? []
                    warnings.append(tr("{0}: letzter erfolgreicher Stand vom {1} bleibt erhalten. {2}", label, previous.observedAt.formatted(date: .abbreviated, time: .shortened), error.localizedDescription))
                    return (previous.events.filter { $0.date >= since && $0.date <= now }, nil)
                }
                warnings.append("\(label): \(error.localizedDescription)")
                return ([], nil)
            }
        }
        let logs = try ActivityLogs.read(roots: roots, cacheDirectory: directory.appendingPathComponent("activity-cache"), now: now, progress: progress)
        warnings += logs.notices
        var events = logs.events
        for root in roots where root.source == .kilo {
            events += try collect("kilo|\(root.url.path)", label: "Kilo",
                                  fingerprint: { try KiloHistory.fingerprint(root: root.url) }, retainedSource: .kilo) {
                let result = try KiloHistory.read(root: root.url, now: now)
                return (result.events, result.notices, nil)
            }.events
        }
        let opencode = try collect("opencode|\(databasePath ?? "default")", label: tr("OpenCode lokal"),
                                   fingerprint: { try OpenCodeHistory.fingerprint(path: databasePath) }) {
            let report = try OpenCodeHistory.read(path: databasePath, now: now, lookbackDays: 90)
            return (report.events, report.importWarnings ?? [], report)
        }
        events += opencode.events
        var local = opencode.summary
        for host in hosts {
            try Task.checkCancellation()
            let url = archives.appendingPathComponent("ssh-" + stableID("ssh|\(host)") + ".plist")
            let legacy = archives.appendingPathComponent(stableID("ssh|\(host)") + ".plist")
            activeArchives.insert(url.lastPathComponent)
            var state = decoded.load(SSHActivity.State.self, from: url) ?? SSHActivity.State()
            // Earlier versions kept one merged archive per host. Keep its usage until it expires.
            if state.observedAt == nil, state.carried.isEmpty, let archive = decoded.load(Archive.self, from: legacy) { state.carried = archive.events }
            if state.isDue(now: now, force: refreshRemote) {
                progress(tr("SSH · {0} wird gelesen …", host))
                let revision = state.revision, observed = state.observedAt
                do {
                    try SSHActivity.read(host: host, state: &state, now: now)
                } catch is CancellationError {
                    decoded.remember(state, for: url)
                    throw CancellationError()
                } catch {
                    if let observed {
                        warnings.append(tr("{0}: letzter erfolgreicher Stand vom {1} bleibt erhalten. {2}", host, observed.formatted(date: .abbreviated, time: .shortened), error.localizedDescription))
                    } else { warnings.append(error.localizedDescription) }
                }
                if state.revision != revision || !fm.fileExists(atPath: url.path) {
                    state.prune(since: since)
                    try decoded.save(state, to: url)
                    try? fm.removeItem(at: legacy); decoded.forget(legacy)
                } else { decoded.remember(state, for: url) }
            }
            warnings += state.notices
            events += state.events(since: since, now: now)
        }
        // Removing a local folder stops reads, while already imported usage still expires after 90 days.
        for file in try fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("kilo-") && file.pathExtension == "plist" && !activeArchives.contains(file.lastPathComponent) {
            try Task.checkCancellation()
            guard var archive = decoded.load(Archive.self, from: file), archive.retainedSource == .kilo else { continue }
            let retained = archive.events.filter { $0.date >= since && $0.date <= now }
            events += retained
            if !retained.isEmpty { warnings += archive.notices ?? [] }
            if retained.isEmpty { try? fm.removeItem(at: file); decoded.forget(file) }
            else if retained.count != archive.events.count {
                archive.events = retained
                try decoded.save(archive, to: file)
            }
        }
        if !hosts.isEmpty { notices.append(tr("SSH-Quellen: {0}. Bei Verbindungsfehlern bleiben bereits eingelesene Werte erhalten.", hosts.joined(separator: ", "))) }
        var report = ActivityReport(events: events, notices: notices, warnings: warnings, now: now)
        ClaudeHistory.supplement(&report, roots: roots.filter { $0.source == .claude }.map { $0.url.deletingLastPathComponent() }, now: now)
        // UI only needs local model/day summaries; events stay on the background worker.
        local?.events = []
        return (report, local)
    }
}
