import Foundation

/// Reads usage metadata from supported logs. Conversation text is discarded in memory, never cached.
public enum ActivityLogs {
    public struct Root: Codable, Identifiable, Equatable, Sendable {
        public var source: ActivitySource
        public var url: URL
        public init(source: ActivitySource, url: URL) { self.source = source; self.url = url }
        public var id: String { "\(source.rawValue)|\(url.standardizedFileURL.resolvingSymlinksInPath().path)" }
    }
    /// Version 3 stores the parser, which owns the events, so a grown log resumes after its last complete line.
    /// Version 2 entries only carry `events`; they stay valid for unchanged and vanished logs.
    private struct CachedFile: Codable {
        var version = 3
        var size: Int
        var modified: Date
        var events: [ActivityEvent] = []
        var skipped: Int
        var inode: UInt64?
        var resume: Resume?
        var parser: UsageLogParser?
        var rootID: String?
        var usage: [ActivityEvent] { parser?.events ?? events }
        func matches(size: Int, modified: Date, inode: UInt64?) -> Bool {
            self.size == size && self.modified == modified && (self.inode == nil || self.inode == inode)
        }
    }
    private struct Resume: Codable {
        var offset: UInt64
        var tail: String
        var discarding: Bool
    }
    /// What an import keeps of a log: its identity and compact events. Parser state is read from disk only when the log grows.
    private struct Entry {
        var key: String
        var size: Int
        var modified: Date
        var inode: UInt64?
        var skipped: Int
        var events: CompactEvents
        var rootID: String?
        var retained: RetainedUsage { RetainedUsage(rootID: rootID, events: events) }
        init(key: String, file: CachedFile, rootID: String? = nil) {
            self.key = key; size = file.size; modified = file.modified; inode = file.inode; skipped = file.skipped
            events = CompactEvents(file.usage)
            self.rootID = rootID ?? file.rootID
        }
    }
    private struct RetainedUsage {
        var rootID: String?
        var events: CompactEvents
    }
    struct RootObservation {
        var root: Root
        var succeeded: Bool
        var hasRetainedUsage = false
        var issues: [String]
    }
    /// Parsed results outlive one import, so unchanged logs never touch their cache files again.
    private struct Memory {
        var files: [String: Entry] = [:]
        var orphans: [String: RetainedUsage] = [:]
    }
    private final class MemoryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Memory] = [:]
        func take(_ key: String) -> Memory { lock.withLock { values.removeValue(forKey: key) ?? Memory() } }
        func put(_ key: String, _ value: Memory) { lock.withLock { values[key] = value } }
    }
    private static let memory = MemoryStore()
    public static func defaultRoots(accounts: [AccountConfiguration], additional: [Root] = [],
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> [Root] {
        func path(_ key: String, fallback: URL) -> URL {
            guard let value = environment[key], !value.isEmpty else { return fallback }
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
            return URL(fileURLWithPath: value)
        }
        let codex = path("CODEX_HOME", fallback: home.appendingPathComponent(".codex"))
        let claude = path("CLAUDE_CONFIG_DIR", fallback: home.appendingPathComponent(".claude"))
        let pi = path("PI_CODING_AGENT_DIR", fallback: home.appendingPathComponent(".pi/agent"))
        let geminiHome = path("GEMINI_CLI_HOME", fallback: home)
        let qwen = path("QWEN_RUNTIME_DIR", fallback: path("QWEN_HOME", fallback: home.appendingPathComponent(".qwen")))
        let kilo = path("XDG_DATA_HOME", fallback: home.appendingPathComponent(".local/share")).appendingPathComponent("kilo")
        var roots = [Root(source: .codex, url: codex.appendingPathComponent("sessions")),
                     Root(source: .codex, url: codex.appendingPathComponent("archived_sessions")),
                     Root(source: .claude, url: claude.appendingPathComponent("projects")),
                     Root(source: .pi, url: path("PI_CODING_AGENT_SESSION_DIR", fallback: pi.appendingPathComponent("sessions")))]
        roots += [Root(source: .gemini, url: geminiHome.appendingPathComponent(".gemini/tmp")),
                  Root(source: .gemini, url: geminiHome.appendingPathComponent(".cache/.gemini/tmp")),
                  Root(source: .cline, url: home.appendingPathComponent(".cline/data/sessions")),
                  Root(source: .qwen, url: qwen.appendingPathComponent("projects"))]
        if let database = environment["KILO_DB"], !database.isEmpty {
            if database != ":memory:" { roots.append(Root(source: .kilo, url: database.hasPrefix("/") ? URL(fileURLWithPath: database) : kilo.appendingPathComponent(database))) }
        } else { roots.append(Root(source: .kilo, url: kilo)) }
        for editor in ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf"] {
            roots.append(Root(source: .roo, url: home.appendingPathComponent("Library/Application Support/\(editor)/User/globalStorage/rooveterinaryinc.roo-cline/tasks")))
        }
        for account in accounts where !account.profileDirectory.isEmpty && (account.provider == .codex || account.provider == .claude) {
            let root = URL(fileURLWithPath: (account.profileDirectory as NSString).expandingTildeInPath)
            roots.append(Root(source: account.provider == .codex ? .codex : .claude, url: root.appendingPathComponent(account.provider == .codex ? "sessions" : "projects")))
            if account.provider == .codex { roots.append(Root(source: .codex, url: root.appendingPathComponent("archived_sessions"))) }
        }
        roots += additional.filter { ActivitySource.logFormats.contains($0.source) }
        var seen = Set<String>()
        return roots.map { Root(source: $0.source, url: $0.url.standardizedFileURL.resolvingSymlinksInPath()) }
            .filter { seen.insert($0.url.path).inserted }
    }
    public static func read(roots: [Root], cacheDirectory: URL?, now: Date = Date(),
                            progress: @Sendable (String) -> Void = { _ in }) throws -> (events: [ActivityEvent], notices: [String]) {
        var events: [ActivityEvent] = []
        let notices = try read(roots: roots, cacheDirectory: cacheDirectory, now: now, progress: progress) { events.append($0) }
        return (events, notices)
    }
    /// Passes each event in the window to `each` instead of collecting them, in the order `read` returns them.
    static func read(roots: [Root], cacheDirectory: URL?, now: Date, progress: @Sendable (String) -> Void,
                     health: (RootObservation) -> Void = { _ in },
                     unattributed: (ActivitySource) -> Void = { _ in },
                     each: (ActivityEvent) -> Void) throws -> [String] {
        let fm = FileManager.default, since = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        if let cacheDirectory { try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var notices: [String] = [], seen = Set<String>(), activeCache = Set<String>(), liveFiles = Set<String>()
        let decoder = PropertyListDecoder(), encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        func cached(_ url: URL?) -> CachedFile? {
            guard let url, let data = try? Data(contentsOf: url), let file = try? decoder.decode(CachedFile.self, from: data),
                  file.version == 2 || file.version == 3 else { return nil }
            return file
        }
        // Taken out of the store so updates do not copy it; put back even when cancelled.
        var previous = cacheDirectory.map { memory.take($0.path) } ?? Memory(), current = Memory(), completed = false
        defer {
            if let cacheDirectory {
                if !completed { current.files.merge(previous.files) { new, _ in new }; current.orphans.merge(previous.orphans) { new, _ in new } }
                memory.put(cacheDirectory.path, current)
            }
        }
        var filesRead = 0, skipped = 0
        var unattributedSources = Set<ActivitySource>()
        var observations: [RootObservation] = [], retainedRoots = Set<String>()
        @discardableResult func emit(_ usage: RetainedUsage, orphan: Bool = false) -> Bool {
            var retained = false
            usage.events.forEach(since: since, through: now) {
                retained = true
                if orphan { unattributedSources.insert($0.source) }
                each($0)
            }
            if retained, let id = usage.rootID { retainedRoots.insert(id) }
            return retained
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileIdentifierKey]
        for root in roots where root.source != .kilo {
            let rootID = stableID(root.id)
            guard fm.fileExists(atPath: root.url.path) else {
                observations.append(RootObservation(root: root, succeeded: false, issues: [])); continue
            }
            var readErrors = 0
            let skippedBefore = skipped
            let enumerator = fm.enumerator(at: root.url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in readErrors += 1; return true })
            if enumerator == nil { readErrors += 1 }
            while let file = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                guard root.source.acceptsLog(file), seen.insert(file.standardizedFileURL.path).inserted else { continue }
                let id = "\(root.source.rawValue)|\(file.path)"
                let known = previous.files.removeValue(forKey: id)
                // Keeps the v2 name so existing caches stay addressable.
                let key = known?.key ?? stableID("v2|\(id)") + ".plist"
                let cacheURL = cacheDirectory?.appendingPathComponent(key)
                do {
                    let resource = try file.resourceValues(forKeys: keys)
                    guard resource.isRegularFile == true, resource.isSymbolicLink != true,
                          let modified = resource.contentModificationDate, modified >= since, let size = resource.fileSize else {
                        if let known { previous.files[id] = known }
                        continue
                    }
                    activeCache.insert(key)
                    let inode = resource.fileIdentifier
                    if let known, known.size == size, known.modified == modified, known.inode == nil || known.inode == inode {
                        var entry = known; entry.rootID = rootID
                        current.files[id] = entry
                        if cacheDirectory == nil { emit(entry.retained) }
                        skipped += known.skipped
                    } else {
                        let result: CachedFile = try autoreleasepool {
                            let base = cached(cacheURL)
                            if let base, base.matches(size: size, modified: modified, inode: inode) { return base }
                            var parsed = try parseFile(file, source: root.source, since: since, size: size, modified: modified, inode: inode, previous: base)
                            parsed.rootID = rootID
                            if let cacheURL { try encoder.encode(parsed).write(to: cacheURL, options: .atomic) }
                            return parsed
                        }
                        if cacheDirectory != nil { current.files[id] = Entry(key: key, file: result, rootID: rootID) }
                        if cacheDirectory == nil {
                            for event in result.usage where event.date >= since && event.date <= now { each(event) }
                        }
                        skipped += result.skipped
                    }
                    liveFiles.insert(id)
                    filesRead += 1
                    if filesRead % 10 == 0 { progress(tr("{0} Logdateien gelesen · {1}", filesRead, root.source.name)) }
                } catch is CancellationError {
                    if let known { previous.files[id] = known }
                    throw CancellationError()
                } catch {
                    readErrors += 1
                    if var last = known ?? cached(cacheURL).map({ Entry(key: key, file: $0) }) {
                        last.rootID = rootID
                        activeCache.insert(key)
                        current.files[id] = last
                        if cacheDirectory == nil { emit(last.retained) }
                    }
                }
            }
            var issues = readErrors > 0 ? [tr("{0}: {1} Dateien konnten nicht gelesen werden.", root.source.name, readErrors)] : []
            notices += issues
            if skipped > skippedBefore { issues.append(tr("{0} Nutzungszeilen konnten nicht gelesen werden. Sie werden bei Änderungen erneut geprüft.", skipped - skippedBefore)) }
            observations.append(RootObservation(root: root, succeeded: readErrors == 0, issues: issues))
        }
        if skipped > 0 { notices.append(tr("{0} Nutzungszeilen konnten nicht gelesen werden. Sie werden bei Änderungen erneut geprüft.", skipped)) }
        if let cacheDirectory {
            // Vanished logs keep their usage until it leaves the 90-day window.
            var vanished = previous.orphans
            for entry in previous.files.values { vanished[entry.key] = entry.retained }
            for name in ((try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []).sorted() where name.hasSuffix(".plist") && !activeCache.contains(name) {
                try Task.checkCancellation()
                let url = cacheDirectory.appendingPathComponent(name)
                if let usage = vanished[name] ?? cached(url).map({ RetainedUsage(rootID: $0.rootID, events: CompactEvents($0.usage)) }) {
                    if emit(usage, orphan: true) { current.orphans[name] = usage; continue }
                }
                try? fm.removeItem(at: url)
            }
            // Retained observations precede live files so a moved/archived log can correct them.
            // Reuse the compact entries already kept for the next scan; do not buffer another event list.
            let files = current.files.keys.sorted()
            for id in files where !liveFiles.contains(id) {
                try Task.checkCancellation()
                if let entry = current.files[id] { emit(entry.retained) }
            }
            for id in files where liveFiles.contains(id) {
                try Task.checkCancellation()
                if let entry = current.files[id] { emit(entry.retained) }
            }
        }
        // A previous success alone cannot prove that any fallback is still readable.
        for var observation in observations {
            observation.hasRetainedUsage = retainedRoots.contains(stableID(observation.root.id))
            health(observation)
        }
        // Retention does not revalidate vanished files, even when their original root is known.
        for source in unattributedSources { unattributed(source) }
        completed = true
        return notices
    }
    private static func knownNonUsagePrefix(_ data: Data, source: ActivitySource) -> Bool {
        let text = String(decoding: data.prefix(1024), as: UTF8.self)
        let kinds = source == .codex ? "response_item|compacted" : source == .pi ? "custom|label|session_info" : "user|progress|file-history-snapshot"
        // Anchored to the envelope. A type mentioned in conversation text never qualifies.
        let pattern = #"^\s*\{\s*(?:"timestamp"\s*:\s*"[^"\\]*"\s*,\s*)?"type"\s*:\s*"("# + kinds + #")""#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    /// Digest of the bytes before `end`; detects a log that was rewritten rather than appended.
    static func tailDigest(_ handle: FileHandle, end: UInt64) throws -> String {
        let start = end - min(end, 4096)
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(end - start)) ?? Data()
        return data.withUnsafeBytes(hexDigest)
    }
    private static func parseFile(_ file: URL, source: ActivitySource, since: Date, size: Int, modified: Date, inode: UInt64?,
                                  previous: CachedFile?) throws -> CachedFile {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parser = UsageLogParser(source: source, fileID: source.fileIdentity(file))
        if file.pathExtension == "json" {
            // Whole-document formats are rewritten by their owner. A partial write must keep the previous cache.
            let maximum = 32 * 1024 * 1024
            let data = try handle.read(upToCount: maximum + 1) ?? Data()
            guard data.count <= maximum else { throw ProviderFailure.invalidData(tr("Logdatei überschreitet 32 MiB.")) }
            try parser.consumeDocument(JSONSerialization.jsonObject(with: data))
            parser.prune(before: since)
            return CachedFile(size: size, modified: modified, skipped: 0, inode: inode, parser: parser)
        }
        var offset: UInt64 = 0, discardLine = false, skipped = 0
        // Resume only a grown file with the same identity and unchanged bytes before the resume point.
        if let previous, previous.version == 3, let resume = previous.resume, let state = previous.parser,
           inode != nil, previous.inode == inode, size > previous.size, UInt64(size) >= resume.offset,
           try tailDigest(handle, end: resume.offset) == resume.tail {
            parser = state; offset = resume.offset; discardLine = resume.discarding; skipped = previous.skipped
        }
        try handle.seek(toOffset: offset)
        var buffer = Data(), searchOffset = 0
        let markers = source.logMarkers, required = source.requiredLogMarker
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[max(start, searchOffset)...].firstIndex(of: 10) {
                if !discardLine {
                    let line = buffer[start..<newline]
                    if markers.contains(where: { line.range(of: $0) != nil }), required.map({ line.range(of: $0) != nil }) ?? true {
                        autoreleasepool {
                            if let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { parser.consume(record) }
                            else { skipped += 1 }
                        }
                    }
                }
                discardLine = false; start = newline + 1
            }
            offset += UInt64(start - buffer.startIndex)
            if start > buffer.startIndex { buffer = Data(buffer[start...]) }
            searchOffset = buffer.count
            if buffer.count > 32 * 1024 * 1024 {
                if !discardLine && !knownNonUsagePrefix(buffer, source: source) { skipped += 1 }
                offset += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: false); discardLine = true; searchOffset = 0
            }
        }
        // An unfinished trailing line belongs to an active writer; the next scan resumes before it.
        parser.prune(before: since)
        let resume = Resume(offset: offset, tail: try tailDigest(handle, end: offset), discarding: discardLine)
        return CachedFile(size: size, modified: modified, skipped: skipped, inode: inode, resume: resume, parser: parser)
    }
}

/// Stateful per-file normalizer. Modern Codex response records replace their repeated legacy counters.
/// Its state is cached so a grown log continues where the last import stopped; it holds usage metadata only.
struct UsageLogParser: Codable {
    private enum CodingKeys: String, CodingKey {
        case source, fileID, model, session, sawMeta, forkAnchor, cumulative, lastSignature, modernSince, legacy, responses, pi
    }
    let source: ActivitySource
    let fileID: String
    private var model = tr("Unbekannt")
    private var session = ""
    private var sawMeta = false
    private var forkAnchor: Date?
    private var cumulative: Double?
    private var lastSignature = ""
    private var modernSince: Date?
    private var legacy: [ActivityEvent] = []
    private var responses: [ActivityEvent] = []
    private let dates = LogDateParser()
    private var pi: PiUsageParser
    init(source: ActivitySource, fileID: String) { self.source = source; self.fileID = fileID; pi = PiUsageParser(fileID: fileID) }
    var events: [ActivityEvent] {
        if source == .pi { return pi.events }
        return legacy.isEmpty ? responses : responses + legacy.filter { event in modernSince.map { event.date < $0 } ?? true }
    }
    /// Drops events outside the import window; counters and identity stay for later lines.
    mutating func prune(before date: Date) {
        legacy.removeAll { $0.date < date }; responses.removeAll { $0.date < date }; pi.prune(before: date)
    }
    mutating func consume(_ record: [String: Any]) {
        switch source {
        case .pi: pi.consume(record); return
        case .gemini: responses += GeminiUsage.events(record); return
        case .qwen:
            if let event = QwenUsage.event(record) { responses.append(event) }
            return
        case .cline:
            if let event = ClineUsage.event(record) { responses.append(event) }
            return
        case .roo:
            if let event = RooUsage.event(record, taskID: fileID) { responses.append(event) }
            return
        case .claude: consumeClaude(record); return
        case .opencode, .kilo: return
        case .codex: break
        }
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
        responses.append(ActivityEvent(id: stableID("\(id)|\(record["requestId"] as? String ?? "")"), source: .claude, date: date, model: message["model"] as? String ?? tr("Unbekannt"), tokens: tokens, usage: TokenBreakdown.claude(usage)))
    }
    private func number(_ object: [String: Any], _ key: String) -> Double { max(0, JSONValue.number(object[key]) ?? 0) }
}

/// Usage events kept between imports in 80 bytes each instead of about 400. SHA-256 hex IDs are stored as their
/// 32 bytes and re-encoded identically; model labels are interned. Values that do not fit go to a side table.
struct CompactEvents {
    private struct Item {
        var id: (UInt64, UInt64, UInt64, UInt64)
        var date: Double
        var usage: (UInt32, UInt32, UInt32, UInt32, UInt32)
        var tokens: UInt32
        var label: UInt32
        var extra: Int32
        var source: UInt8
        var flags: UInt8
    }
    private struct Extra {
        var id: String?
        var tokens: Double?
        var usage: TokenBreakdown?
        var responseCount: Int?
        var reportedCost: Double?
        var sessionStartedAt: Date?
    }
    private struct Label: Hashable { var model: String; var provider: String }
    private final class Labels: @unchecked Sendable {
        private let lock = NSLock()
        private var index: [Label: UInt32] = [:]
        private var values: [Label] = []
        func id(_ label: Label) -> UInt32 {
            lock.withLock {
                if let id = index[label] { return id }
                values.append(label); index[label] = UInt32(values.count - 1)
                return UInt32(values.count - 1)
            }
        }
        func label(_ id: UInt32) -> Label { lock.withLock { values[Int(id)] } }
    }
    private static let labels = Labels()
    private static let hexID: UInt8 = 1, inlineUsage: UInt8 = 2, inlineTokens: UInt8 = 4
    private var items: [Item] = []
    private var extras: [Extra] = []
    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    init(_ events: [ActivityEvent]) {
        items.reserveCapacity(events.count)
        for event in events {
            var item = Item(id: (0, 0, 0, 0), date: event.date.timeIntervalSinceReferenceDate, usage: (0, 0, 0, 0, 0), tokens: 0,
                            label: Self.labels.id(Label(model: event.model, provider: event.provider)), extra: -1,
                            source: UInt8(ActivitySource.allCases.firstIndex(of: event.source)!), flags: 0)
            var extra = Extra(responseCount: event.responseCount, reportedCost: event.reportedCost, sessionStartedAt: event.sessionStartedAt)
            if let digest = Self.digest(event.id) { item.id = digest; item.flags |= Self.hexID } else { extra.id = event.id }
            if let tokens = UInt32(exactly: event.tokens) { item.tokens = tokens; item.flags |= Self.inlineTokens } else { extra.tokens = event.tokens }
            if let usage = event.usage {
                if let input = UInt32(exactly: usage.input), let output = UInt32(exactly: usage.output), let read = UInt32(exactly: usage.cacheRead),
                   let write = UInt32(exactly: usage.cacheWrite), let hour = UInt32(exactly: usage.cacheWriteHour) {
                    item.usage = (input, output, read, write, hour); item.flags |= Self.inlineUsage
                } else { extra.usage = usage }
            }
            if extra.id != nil || extra.tokens != nil || extra.usage != nil || extra.responseCount != nil || extra.reportedCost != nil || extra.sessionStartedAt != nil {
                item.extra = Int32(extras.count); extras.append(extra)
            }
            items.append(item)
        }
    }

    func forEach(since: Date, through now: Date, _ body: (ActivityEvent) -> Void) {
        let lower = since.timeIntervalSinceReferenceDate, upper = now.timeIntervalSinceReferenceDate
        for item in items where item.date >= lower && item.date <= upper {
            let extra = item.extra >= 0 ? extras[Int(item.extra)] : nil, label = Self.labels.label(item.label)
            let usage = item.flags & Self.inlineUsage != 0
                ? TokenBreakdown(input: Double(item.usage.0), output: Double(item.usage.1), cacheRead: Double(item.usage.2), cacheWrite: Double(item.usage.3), cacheWriteHour: Double(item.usage.4))
                : extra?.usage
            body(ActivityEvent(id: item.flags & Self.hexID != 0 ? Self.hex(item.id) : extra?.id ?? "", source: ActivitySource.allCases[Int(item.source)],
                               date: Date(timeIntervalSinceReferenceDate: item.date), model: label.model, provider: label.provider,
                               tokens: item.flags & Self.inlineTokens != 0 ? Double(item.tokens) : extra?.tokens ?? 0, usage: usage,
                               responseCount: extra?.responseCount, reportedCost: extra?.reportedCost, sessionStartedAt: extra?.sessionStartedAt))
        }
    }
    func events(since: Date = .distantPast, through now: Date = .distantFuture) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        forEach(since: since, through: now) { events.append($0) }
        return events
    }

    static func digest(_ id: String) -> (UInt64, UInt64, UInt64, UInt64)? {
        var id = id
        return id.withUTF8 { bytes -> (UInt64, UInt64, UInt64, UInt64)? in
            guard bytes.count == 64 else { return nil }
            func word(_ start: Int) -> UInt64? {
                var value: UInt64 = 0
                for byte in bytes[start..<(start + 16)] {
                    switch byte {
                    case 48...57: value = value << 4 | UInt64(byte - 48)
                    case 97...102: value = value << 4 | UInt64(byte - 87)
                    default: return nil
                    }
                }
                return value
            }
            guard let a = word(0), let b = word(16), let c = word(32), let d = word(48) else { return nil }
            return (a, b, c, d)
        }
    }
    private static func hex(_ id: (UInt64, UInt64, UInt64, UInt64)) -> String {
        String(unsafeUninitializedCapacity: 64) { buffer in
            let digits: StaticString = "0123456789abcdef"
            func write(_ value: UInt64, at start: Int) {
                for nibble in 0..<16 { buffer[start + nibble] = digits.utf8Start[Int(value >> UInt64(60 - nibble * 4) & 15)] }
            }
            write(id.0, at: 0); write(id.1, at: 16); write(id.2, at: 32); write(id.3, at: 48)
            return 64
        }
    }
}

/// Archives store plain event arrays; only the in-memory form is compact.
extension CompactEvents: Codable {
    init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode([ActivityEvent].self)) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(events())
    }
}

final class LogDateParser {
    private let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let wholeStyle = Date.ISO8601FormatStyle()
    private lazy var fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()
    private lazy var whole = ISO8601DateFormatter()

    func parse(_ value: Any?) -> Date? {
        if let seconds = JSONValue.number(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let value = value as? String else { return nil }
        // Log writers normally emit UTC with whole seconds or exactly three decimal places.
        // Keep the legacy formatter for other precisions, offsets, and permissive inputs.
        if let hasFraction = canonicalUTC(value),
           let date = try? (hasFraction ? fractionalStyle : wholeStyle).parse(value) {
            // ISO8601DateFormatter returns millisecond precision using the Unix epoch.
            return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        }
        return fractional.date(from: value) ?? whole.date(from: value)
    }

    private func canonicalUTC(_ value: String) -> Bool? {
        let bytes = value.utf8
        guard bytes.count == 20 || bytes.count == 24 else { return nil }
        return bytes.withContiguousStorageIfAvailable { bytes -> Bool? in
            for index in bytes.indices {
                let expected: UInt8?
                switch index {
                case 4, 7: expected = 45
                case 10: expected = 84
                case 13, 16: expected = 58
                case bytes.count - 1: expected = 90
                case 19: expected = 46
                default: expected = nil
                }
                if let expected {
                    guard bytes[index] == expected else { return nil }
                } else if !(48...57).contains(bytes[index]) { return nil }
            }
            // FormatStyle normalizes out-of-range minutes and leap seconds that ICU rejects.
            guard bytes[11] < 50 || (bytes[11] == 50 && bytes[12] <= 51),
                  bytes[14] <= 53, bytes[17] <= 53 else { return nil }
            return bytes.count == 24
        } ?? nil
    }
}
