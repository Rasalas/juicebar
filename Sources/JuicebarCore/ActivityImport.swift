import Foundation

/// All expensive work runs on the import worker. Archives contain only usage metadata.
public enum ActivityImport {
    private struct Archive: Codable {
        var events: [ActivityEvent]
        var observedAt: Date
        var fingerprint: String?
        var notices: [String]?
        var retainedSource: ActivitySource?
    }
    public static func read(roots: [ActivityLogs.Root], databasePath: String?, hosts: [String], directory: URL,
                            now: Date = Date(), progress: @Sendable (String) -> Void = { _ in }) throws -> (ActivityReport, LocalUsageReport?) {
        let fm = FileManager.default
        let archives = directory.appendingPathComponent("activity-sources")
        try fm.createDirectory(at: archives, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var warnings: [String] = [], notices: [String] = []
        var activeArchives = Set<String>()
        let since = now.addingTimeInterval(-90 * 86400)
        func collect(_ key: String, label: String, fingerprint: (() throws -> String)? = nil, retainedSource: ActivitySource? = nil,
                     read: () throws -> (events: [ActivityEvent], notices: [String])) throws -> [ActivityEvent] {
            let prefix = retainedSource == .kilo ? "kilo-" : ""
            let url = archives.appendingPathComponent(prefix + stableID(key) + ".plist")
            activeArchives.insert(url.lastPathComponent)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let previous = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode(Archive.self, from: $0) }
            do {
                try Task.checkCancellation()
                let stamp = try fingerprint?()
                if let stamp, let previous, previous.fingerprint == stamp,
                   now >= previous.observedAt, now.timeIntervalSince(previous.observedAt) < 3600 {
                    warnings += previous.notices ?? []
                    let retained = previous.events.filter { $0.date >= since && $0.date <= now }
                    if retained.count != previous.events.count {
                        try encoder.encode(Archive(events: retained, observedAt: previous.observedAt, fingerprint: stamp, notices: previous.notices, retainedSource: retainedSource)).write(to: url, options: .atomic)
                    }
                    return retained
                }
                let result = try read()
                var unique = Dictionary((previous?.events ?? []).filter { $0.date >= since && $0.date <= now }.map { ("\($0.source.rawValue)|\($0.id)", $0) }, uniquingKeysWith: ActivityEvent.preferred)
                for event in result.events {
                    let key = "\(event.source.rawValue)|\(event.id)"
                    unique[key] = unique[key].map { ActivityEvent.preferred($0, event) } ?? event
                }
                let events = Array(unique.values)
                try Task.checkCancellation()
                try encoder.encode(Archive(events: events, observedAt: now, fingerprint: stamp, notices: result.notices, retainedSource: retainedSource)).write(to: url, options: .atomic)
                warnings += result.notices
                return events
            } catch is CancellationError { throw CancellationError() }
            catch {
                if let previous {
                    warnings.append(tr("{0}: letzter erfolgreicher Stand vom {1} bleibt erhalten. {2}", label, previous.observedAt.formatted(date: .abbreviated, time: .shortened), error.localizedDescription))
                    return previous.events.filter { $0.date >= since && $0.date <= now }
                }
                warnings.append("\(label): \(error.localizedDescription)")
                return []
            }
        }
        let logs = try ActivityLogs.read(roots: roots, cacheDirectory: directory.appendingPathComponent("activity-cache"), now: now, progress: progress)
        warnings += logs.notices
        var local: LocalUsageReport?
        var events = logs.events
        for root in roots where root.source == .kilo {
            events += try collect("kilo|\(root.url.path)", label: "Kilo",
                                  fingerprint: { try KiloHistory.fingerprint(root: root.url) }, retainedSource: .kilo) {
                try KiloHistory.read(root: root.url, now: now)
            }
        }
        events += try collect("opencode|\(databasePath ?? "default")", label: tr("OpenCode lokal")) {
            local = try OpenCodeHistory.read(path: databasePath, now: now, lookbackDays: 90)
            return (local?.events ?? [], [])
        }
        for host in hosts {
            try Task.checkCancellation(); progress(tr("SSH · {0} wird gelesen …", host))
            events += try collect("ssh|\(host)", label: host) { try SSHActivity.read(host: host, now: now) }
        }
        // Removing a local folder stops reads, while already imported usage still expires after 90 days.
        for file in try fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("kilo-") && file.pathExtension == "plist" && !activeArchives.contains(file.lastPathComponent) {
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: file), var archive = try? PropertyListDecoder().decode(Archive.self, from: data),
                  archive.retainedSource == .kilo else { continue }
            let retained = archive.events.filter { $0.date >= since && $0.date <= now }
            events += retained
            if retained.isEmpty { try? fm.removeItem(at: file) }
            else if retained.count != archive.events.count {
                archive.events = retained
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(archive).write(to: file, options: .atomic)
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
