import Foundation

/// Reads usage metadata from JSONL. Conversation text is discarded in memory, never cached.
public enum ActivityLogs {
    public struct Root: Sendable {
        public var source: ActivitySource
        public var url: URL
        public init(source: ActivitySource, url: URL) { self.source = source; self.url = url }
    }
    private struct CachedFile: Codable {
        var version = 2
        var size: Int
        var modified: Date
        var events: [ActivityEvent]
        var skipped: Int
    }
    public static func defaultRoots(accounts: [AccountConfiguration]) -> [Root] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [Root(source: .codex, url: home.appendingPathComponent(".codex/sessions")),
                     Root(source: .codex, url: home.appendingPathComponent(".codex/archived_sessions")),
                     Root(source: .claude, url: home.appendingPathComponent(".claude/projects"))]
        for account in accounts where !account.profileDirectory.isEmpty && (account.provider == .codex || account.provider == .claude) {
            let root = URL(fileURLWithPath: (account.profileDirectory as NSString).expandingTildeInPath)
            roots.append(Root(source: account.provider == .codex ? .codex : .claude, url: root.appendingPathComponent(account.provider == .codex ? "sessions" : "projects")))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }
    public static func read(roots: [Root], cacheDirectory: URL?, now: Date = Date(),
                            progress: @Sendable (String) -> Void = { _ in }) throws -> (events: [ActivityEvent], notices: [String]) {
        let fm = FileManager.default, since = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        if let cacheDirectory { try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var events: [ActivityEvent] = [], notices: [String] = [], seen = Set<String>(), activeCache = Set<String>()
        let decoder = PropertyListDecoder(), encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var filesRead = 0, skipped = 0
        for root in roots {
            guard fm.fileExists(atPath: root.url.path) else { continue }
            var readErrors = 0
            let enumerator = fm.enumerator(at: root.url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in readErrors += 1; return true })
            while let file = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                guard file.pathExtension == "jsonl", seen.insert(file.standardizedFileURL.path).inserted else { continue }
                do {
                    let resource = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard resource.isRegularFile == true, resource.isSymbolicLink != true,
                          let modified = resource.contentModificationDate, modified >= since, let size = resource.fileSize else { continue }
                    let key = stableID("v2|\(root.source.rawValue)|\(file.path)") + ".plist"
                    activeCache.insert(key)
                    let cacheURL = cacheDirectory?.appendingPathComponent(key)
                    let result: CachedFile = try autoreleasepool {
                        if let cached = cacheURL.flatMap({ try? Data(contentsOf: $0) }).flatMap({ try? decoder.decode(CachedFile.self, from: $0) }),
                           cached.version == 2, cached.size == size, cached.modified == modified { return cached }
                        let parsed = try parseFile(file, source: root.source, since: since)
                        let result = CachedFile(size: size, modified: modified, events: parsed.events, skipped: parsed.skipped)
                        if let cacheURL { try encoder.encode(result).write(to: cacheURL, options: .atomic) }
                        return result
                    }
                    events.append(contentsOf: result.events.filter { $0.date >= since && $0.date <= now })
                    skipped += result.skipped; filesRead += 1
                    if filesRead % 10 == 0 { progress("\(filesRead) Logdateien gelesen · \(root.source.name)") }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    readErrors += 1
                    if let cacheURL = cacheDirectory?.appendingPathComponent(stableID("v2|\(root.source.rawValue)|\(file.path)") + ".plist"),
                       let data = try? Data(contentsOf: cacheURL), let cached = try? decoder.decode(CachedFile.self, from: data), cached.version == 2 {
                        events += cached.events.filter { $0.date >= since && $0.date <= now }
                    }
                }
            }
            if readErrors > 0 { notices.append("\(root.source.name): \(readErrors) Dateien konnten nicht gelesen werden.") }
        }
        if skipped > 0 { notices.append("\(skipped) Nutzungszeilen konnten nicht gelesen werden. Sie werden bei Änderungen erneut geprüft.") }
        if let cacheDirectory {
            for file in (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "plist" && !activeCache.contains(file.lastPathComponent) {
                if let data = try? Data(contentsOf: file), let cached = try? decoder.decode(CachedFile.self, from: data), cached.version == 2 {
                    let retained = cached.events.filter { $0.date >= since && $0.date <= now }
                    if !retained.isEmpty { events += retained; continue }
                }
                try? fm.removeItem(at: file)
            }
        }
        return (events, notices)
    }
    private static func knownNonUsagePrefix(_ data: Data, source: ActivitySource) -> Bool {
        let text = String(decoding: data.prefix(1024), as: UTF8.self)
        let kinds = source == .codex ? "response_item|compacted" : "user|progress|file-history-snapshot"
        // Anchored to the envelope. A type mentioned in conversation text never qualifies.
        let pattern = #"^\s*\{\s*(?:"timestamp"\s*:\s*"[^"\\]*"\s*,\s*)?"type"\s*:\s*"("# + kinds + #")""#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    private static func parseFile(_ file: URL, source: ActivitySource, since: Date) throws -> (events: [ActivityEvent], skipped: Int) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parser = UsageLogParser(source: source, fileID: stableID(file.path))
        var buffer = Data(), discardLine = false, skipped = 0, searchOffset = 0
        let markers = (source == .codex ? ["\"token_count\"", "\"token_usage_record\"", "\"turn_context\"", "\"session_meta\""] : ["\"usage\""]).map { Data($0.utf8) }
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[max(start, searchOffset)...].firstIndex(of: 10) {
                if !discardLine {
                    let line = buffer[start..<newline]
                    if markers.contains(where: { line.range(of: $0) != nil }) {
                        autoreleasepool {
                            if let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { parser.consume(record) }
                            else { skipped += 1 }
                        }
                    }
                }
                discardLine = false; start = newline + 1
            }
            if start > buffer.startIndex { buffer = Data(buffer[start...]) }
            searchOffset = buffer.count
            if buffer.count > 32 * 1024 * 1024 {
                if !discardLine && !knownNonUsagePrefix(buffer, source: source) { skipped += 1 }
                buffer.removeAll(keepingCapacity: false); discardLine = true; searchOffset = 0
            }
        }
        // An unfinished trailing line belongs to an active writer; retry it on the next scan.
        return (parser.events.filter { $0.date >= since }, skipped)
    }
}

/// Stateful per-file normalizer. Modern Codex response records replace their repeated legacy counters.
struct UsageLogParser {
    let source: ActivitySource
    let fileID: String
    private var model = "Unbekannt"
    private var session = ""
    private var sawMeta = false
    private var forkAnchor: Date?
    private var cumulative: Double?
    private var lastSignature = ""
    private var modernSince: Date?
    private var legacy: [ActivityEvent] = []
    private var responses: [ActivityEvent] = []
    private let dates = LogDateParser()
    init(source: ActivitySource, fileID: String) { self.source = source; self.fileID = fileID }
    var events: [ActivityEvent] { responses + legacy.filter { event in modernSince.map { event.date < $0 } ?? true } }
    mutating func consume(_ record: [String: Any]) {
        if source == .claude { consumeClaude(record); return }
        guard let payload = record["payload"] as? [String: Any], let type = record["type"] as? String else { return }
        if type == "session_meta", !sawMeta {
            sawMeta = true; session = payload["id"] as? String ?? payload["session_id"] as? String ?? fileID
            if payload["forked_from_id"] != nil || (payload["source"] as? [String: Any])?["subagent"] != nil { forkAnchor = dates.parse(record["timestamp"]) }
            return
        }
        if type == "turn_context" { model = payload["model"] as? String ?? model; return }
        guard let date = dates.parse(record["timestamp"]) else { return }
        if type == "token_usage_record", let usage = payload["usage"] as? [String: Any], let id = payload["response_id"] as? String {
            let tokens = number(usage, "input_tokens") + number(usage, "output_tokens")
            guard tokens > 0 else { return }
            modernSince = min(modernSince ?? date, date)
            responses.append(ActivityEvent(id: stableID(id), source: .codex, date: date, model: model, tokens: tokens, usage: TokenBreakdown.codex(usage)))
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] else { return }
        let total = (info["total_token_usage"] as? [String: Any]).flatMap { JSONValue.number($0["total_tokens"]) }
        let lastTotal = number(last, "input_tokens") + number(last, "output_tokens")
        let signature = "\(total ?? -1)|\(lastTotal)|\(number(last, "cached_input_tokens"))"
        let duplicate = signature == lastSignature
        lastSignature = signature
        let previous = cumulative; cumulative = total ?? cumulative
        if let anchor = forkAnchor {
            if date.timeIntervalSince(anchor) < 1 { forkAnchor = date; return }
            forkAnchor = nil
        }
        guard !duplicate else { return }
        let tokens: Double
        if let total, let previous, total >= previous { tokens = total - previous }
        else { tokens = lastTotal }
        guard tokens > 0 else { return }
        legacy.append(ActivityEvent(id: stableID("\(session.isEmpty ? fileID : session)|\(date.timeIntervalSince1970)|\(signature)"), source: .codex, date: date, model: model, tokens: tokens, usage: abs(tokens - lastTotal) < 0.5 ? TokenBreakdown.codex(last) : nil))
    }
    private mutating func consumeClaude(_ record: [String: Any]) {
        guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any], let date = dates.parse(record["timestamp"]),
              let id = message["id"] as? String ?? record["requestId"] as? String else { return }
        let tokens = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + number(usage, $1) }
        guard tokens > 0 else { return }
        responses.append(ActivityEvent(id: stableID("\(id)|\(record["requestId"] as? String ?? "")"), source: .claude, date: date, model: message["model"] as? String ?? "Unbekannt", tokens: tokens, usage: TokenBreakdown.claude(usage)))
    }
    private func number(_ object: [String: Any], _ key: String) -> Double { max(0, JSONValue.number(object[key]) ?? 0) }
}

private final class LogDateParser {
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    init() { fractional.formatOptions.insert(.withFractionalSeconds) }
    func parse(_ value: Any?) -> Date? {
        if let seconds = JSONValue.number(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let value = value as? String else { return nil }
        return fractional.date(from: value) ?? whole.date(from: value)
    }
}
