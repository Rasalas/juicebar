import Foundation

public enum SSHActivity {
    /// Per-host import state with usage metadata only. Remote logs are keyed by a digest of their path,
    /// so the collector skips unchanged files and resumes grown ones.
    struct State: Codable {
        struct RemoteFile: Codable {
            var size: Int64
            var modified: Int64
            var inode: Int64
            var offset: Int64?
            var tail: String?
            var parser: UsageLogParser
        }
        struct RemoteDatabase: Codable {
            var fingerprint: String
            var events: [ActivityEvent]
        }
        var files: [String: RemoteFile] = [:]
        var databases: [String: RemoteDatabase] = [:]
        var carried: [ActivityEvent] = []
        var notices: [String] = []
        var observedAt: Date?
        var complete = false
        var revision = 0

        func isDue(now: Date, force: Bool) -> Bool { SSHActivity.isDue(observedAt: observedAt, complete: complete, now: now, force: force) }
        func events(since: Date, now: Date) -> [ActivityEvent] {
            var result = carried.filter { $0.date >= since && $0.date <= now }
            for file in files.values { result += file.parser.events.lazy.filter { $0.date >= since && $0.date <= now } }
            for database in databases.values { result += database.events.lazy.filter { $0.date >= since && $0.date <= now } }
            return result
        }
        /// Vanished remote logs keep their usage until it leaves the import window, like local logs.
        mutating func prune(since: Date) {
            carried.removeAll { $0.date < since }
            for key in Array(files.keys) {
                files[key]?.parser.prune(before: since)
                if files[key]?.parser.events.isEmpty == true, (files[key]?.modified ?? 0) < Int64(since.timeIntervalSince1970 * 1e9) { files[key] = nil }
            }
            for key in Array(databases.keys) { databases[key]?.events.removeAll { $0.date < since } }
        }
    }

    static func isDue(observedAt: Date?, complete: Bool, now: Date, force: Bool) -> Bool {
        force || !complete || observedAt.map { now < $0 || now.timeIntervalSince($0) >= ActivityImport.remoteInterval } ?? true
    }

    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 200 && !host.hasPrefix("-") &&
        host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@").contains($0) }
    }

    private static func integer(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

    /// Collector input: what this Mac already holds for each remote file and database.
    static func script(_ state: State, collector: Data) throws -> Data {
        let known: [String: Any] = [
            "files": state.files.mapValues { [$0.size, $0.modified, $0.inode, $0.offset ?? -1, $0.tail ?? ""] as [Any] },
            "databases": state.databases.mapValues(\.fingerprint)]
        let encoded = try JSONSerialization.data(withJSONObject: known).base64EncodedString()
        return Data("import base64, json\nKNOWN = json.loads(base64.b64decode('\(encoded)'))\n".utf8) + collector
    }

    /// Commits every finished file, so a run stopped by the time or size limit still makes progress.
    /// The limits apply to the data transferred in one run; the next run continues after the last committed file.
    static func read(host: String, state: inout State, now: Date = Date()) throws {
        guard isValidHost(host) else { throw ProviderFailure.invalidData(tr("Ein SSH-Alias darf nur Buchstaben, Zahlen, Punkt, Bindestrich, Unterstrich und @ enthalten.")) }
        guard let scriptURL = Bundle.module.url(forResource: "ssh-usage", withExtension: "py") else { throw ProviderFailure.unavailable(tr("SSH-Collector fehlt im App-Bundle.")) }
        let input = try script(state, collector: Data(contentsOf: scriptURL))
        let process = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-T", "-a", "-x", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "--", host, "python3", "-"], timeout: 180, maximumResponseBytes: 128 * 1024 * 1024)
        defer { process.close() }
        try process.sendInput(input, finish: true)
        try consume(host: host, state: &state, now: now) { try process.receive { _ in true } }
    }

    static func consume(host: String, state: inout State, now: Date, next: () throws -> [String: Any]) throws {
        let since = now.addingTimeInterval(-90 * 86400)
        var file: (key: String, value: State.RemoteFile, checkpoints: Bool)?
        var database: (key: String, fingerprint: String, events: [ActivityEvent])?
        var notices: [String] = []
        state.complete = false
        do {
            while true {
                let row = try next()
                if row["done"] as? Bool == true { break }
                if let key = row["key"] as? String, let id = row["file"] as? String, let name = row["source"] as? String, let source = ActivitySource(rawValue: name),
                   let size = integer(row["size"]), let modified = integer(row["mtime"]), let inode = integer(row["ino"]) {
                    let resumed = row["resume"] as? Bool == true ? state.files[key]?.parser : nil
                    // A full re-read of a known file keeps the old result until the file is complete.
                    file = (key, State.RemoteFile(size: size, modified: modified, inode: inode, parser: resumed ?? UsageLogParser(source: source, fileID: id)),
                            resumed != nil || state.files[key] == nil)
                } else if let record = row["record"] as? [String: Any] { file?.value.parser.consume(record) }
                else if let offset = integer(row["checkpoint"]), var current = file, current.checkpoints {
                    current.value.size = -1; current.value.offset = offset; current.value.tail = row["tail"] as? String
                    state.files[current.key] = current.value; state.revision += 1
                } else if row["endFile"] as? Bool == true, var current = file {
                    current.value.offset = integer(row["offset"]); current.value.tail = row["tail"] as? String
                    current.value.parser.prune(before: since)
                    state.files[current.key] = current.value; state.revision += 1; file = nil
                } else if let key = row["database"] as? String {
                    database = row["unchanged"] as? Bool == true ? nil : (key, row["fingerprint"] as? String ?? "", [])
                } else if let event = row["event"] as? [String: Any], let id = event["id"] as? String,
                          let date = JSONValue.date(event["date"]), let tokens = JSONValue.number(event["tokens"]), date >= since, date <= now, tokens > 0 {
                    guard let name = event["source"] as? String, let source = ActivitySource(rawValue: name), source == .opencode || source == .kilo else { continue }
                    database?.events.append(ActivityEvent(id: id, source: source, date: date, model: event["model"] as? String ?? tr("Unbekannt"), provider: event["provider"] as? String ?? "", tokens: tokens, usage: (event["tokenBreakdown"] as? [String: Any]).flatMap(TokenBreakdown.opencode), reportedCost: source == .kilo ? JSONValue.number(event["reportedCost"]) : nil))
                } else if row["endDatabase"] as? Bool == true, let current = database {
                    // Rows deleted on the host stay imported, as with the local OpenCode archive.
                    // Reread observations follow retained ones so equal-total metadata corrections can replace them.
                    var unique = Dictionary((state.databases[current.key]?.events ?? []).map { ("\($0.source.rawValue)|\($0.id)", $0) }, uniquingKeysWith: ActivityEvent.preferred)
                    for event in current.events {
                        let key = "\(event.source.rawValue)|\(event.id)"
                        unique[key] = unique[key].map { ActivityEvent.preferred($0, event) } ?? event
                    }
                    state.databases[current.key] = State.RemoteDatabase(fingerprint: current.fingerprint, events: Array(unique.values))
                    state.revision += 1; database = nil
                } else if let notice = row["notice"] as? String { notices.append("\(host): \(notice)") }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ProviderFailure.unavailable(tr("{0}: SSH-Import nicht abgeschlossen. Verbindung, bekannten Host-Schlüssel, Schlüsselanmeldung und Python 3 prüfen. Übertragene Dateien bleiben erhalten, der nächste Import setzt fort.", host)) }
        if state.notices != notices { state.notices = notices; state.revision += 1 }
        state.observedAt = now; state.complete = true
    }
}
