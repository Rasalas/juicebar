import Foundation

/// All expensive work runs on the import worker. Archives contain only usage metadata.
public enum ActivityImport {
    private struct Archive: Codable { var events: [ActivityEvent]; var observedAt: Date }
    public static func read(roots: [ActivityLogs.Root], databasePath: String?, hosts: [String], directory: URL,
                            now: Date = Date(), progress: @Sendable (String) -> Void = { _ in }) throws -> (ActivityReport, LocalUsageReport?) {
        let fm = FileManager.default
        let archives = directory.appendingPathComponent("activity-sources")
        try fm.createDirectory(at: archives, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var warnings: [String] = [], notices: [String] = []
        let since = now.addingTimeInterval(-90 * 86400)
        func collect(_ key: String, label: String, read: () throws -> (events: [ActivityEvent], notices: [String])) throws -> [ActivityEvent] {
            let url = archives.appendingPathComponent(stableID(key) + ".plist")
            let previous = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode(Archive.self, from: $0) }
            do {
                let result = try read()
                var unique = Dictionary((previous?.events ?? []).filter { $0.date >= since && $0.date <= now }.map { ("\($0.source.rawValue)|\($0.id)", $0) }, uniquingKeysWith: { $0.tokens >= $1.tokens ? $0 : $1 })
                for event in result.events {
                    let key = "\(event.source.rawValue)|\(event.id)"
                    if let old = unique[key], old.tokens > event.tokens { continue }
                    unique[key] = event
                }
                let events = Array(unique.values)
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try Task.checkCancellation()
                try encoder.encode(Archive(events: events, observedAt: now)).write(to: url, options: .atomic)
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
        events += try collect("opencode|\(databasePath ?? "default")", label: tr("OpenCode lokal")) {
            local = try OpenCodeHistory.read(path: databasePath, now: now, lookbackDays: 90)
            return (local?.events ?? [], [])
        }
        for host in hosts {
            try Task.checkCancellation(); progress(tr("SSH · {0} wird gelesen …", host))
            events += try collect("ssh|\(host)", label: host) { try SSHActivity.read(host: host, now: now) }
        }
        if !hosts.isEmpty { notices.append(tr("SSH-Quellen: {0}. Bei Verbindungsfehlern bleiben bereits eingelesene Werte erhalten.", hosts.joined(separator: ", "))) }
        var report = ActivityReport(events: events, notices: notices, warnings: warnings, now: now)
        ClaudeHistory.supplement(&report, roots: roots.filter { $0.source == .claude }.map { $0.url.deletingLastPathComponent() }, now: now)
        // UI only needs local model/day summaries; events stay on the background worker.
        local?.events = []
        return (report, local)
    }
}
