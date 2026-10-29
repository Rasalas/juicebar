import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import JuicebarCore

/// Exported by libsystem_kernel but missing from the SDK headers; restarts `ri_interval_max_phys_footprint`.
@_silgen_name("proc_reset_footprint_interval") private func resetFootprintInterval(_ pid: pid_t) -> Int32

/// Opt-in measurements use synthetic data only. Thresholds are generous and catch only order-of-magnitude regressions.
final class ActivityPerformanceTests: XCTestCase {
    private var ciProfile: Bool { ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK_PROFILE"] == "ci" }

    override func setUpWithError() throws {
        #if DEBUG
        if ciProfile { throw BenchmarkConfigurationError.releaseRequired }
        #endif
    }
    private enum BenchmarkConfigurationError: Error { case releaseRequired }

    /// Identity plus bytes detects even an atomic rewrite with unchanged content or coarse timestamps.
    private func cacheSnapshot(_ directory: URL) throws -> [String: String] {
        let fm = FileManager.default
        let files = try XCTUnwrap(fm.enumerator(at: directory, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let file as URL in files where file.pathExtension == "plist" {
            let attributes = try fm.attributesOfItem(atPath: file.path)
            result[file.path] = "\(attributes[.systemFileNumber]!)|\(attributes[.modificationDate]!)|\(SHA256.hash(data: try Data(contentsOf: file)))"
        }
        return result
    }

    private func resources() -> (cpu: Double, rss: Int) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return (cpu, Int(usage.ru_maxrss))
    }

    private func claudeLog(file: Int, rows: Range<Int>, stamp: String, content: Int) throws -> Data {
        var data = Data()
        for row in rows {
            let user: [String: Any] = ["type": "user", "timestamp": stamp, "message": ["role": "user", "content": String(repeating: "u", count: content)]]
            let assistant: [String: Any] = ["type": "assistant", "timestamp": stamp, "requestId": "r-\(file)-\(row)",
                "message": ["id": "m-\(file)-\(row)", "model": "claude-opus-5", "content": [["type": "text", "text": String(repeating: "a", count: content)]],
                            "usage": ["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40]]]
            for line in [user, assistant] { data.append(try JSONSerialization.data(withJSONObject: line)); data.append(10) }
        }
        return data
    }

    private func measure(_ name: String, _ body: () throws -> Void) rethrows -> (wall: Double, cpu: Double) {
        let start = Date(), before = resources()
        try body()
        let result = (wall: Date().timeIntervalSince(start), cpu: resources().cpu - before.cpu)
        print("BENCHMARK \(name): wall=\(result.wall)s cpu=\(result.cpu)s peakRSS=\(resources().rss)")
        return result
    }

    // Steady state of the five-minute import: many logs and an OpenCode database, nothing changed.
    func testUnchangedImport() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else { throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure imports") }
        let fileCount = ciProfile ? 64 : (ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK_FILES"].flatMap(Int.init) ?? 1000)
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let logs = root.appendingPathComponent("claude/projects")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date(), stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        for file in 0..<fileCount {
            let project = logs.appendingPathComponent("project-\(file % 20)")
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try claudeLog(file: file, rows: 0..<50, stamp: stamp, content: 400).write(to: project.appendingPathComponent("session-\(file).jsonl"))
        }
        let dbFile = root.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFile.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE message (id TEXT, data TEXT, time_created INTEGER); BEGIN", nil, nil, nil), SQLITE_OK)
        let record = #"{"role":"assistant","modelID":"custom","cost":0.2,"tokens":{"input":100,"output":20,"cache":{"read":60}}}"#
        for row in 0..<20000 {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES ('\(row)', '\(record)', \(Int(now.timeIntervalSince1970 * 1000) - 7_200_000))", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
        let roots = [ActivityLogs.Root(source: .claude, url: logs)], directory = root.appendingPathComponent("state")
        var passes: [(wall: Double, cpu: Double)] = []
        var snapshot: [String: String] = [:]
        for label in ["cold", "unchanged", "unchanged again"] {
            passes.append(try measure("\(label) import of \(fileCount) logs and 20,000 OpenCode rows") {
                let report = try ActivityImport.read(roots: roots, databasePath: dbFile.path, hosts: [], directory: directory, now: now).0
                XCTAssertEqual(report.days.reduce(0) { $0 + $1.responses }, fileCount * 50 + 20000)
            })
            if ciProfile {
                let current = try cacheSnapshot(directory)
                XCTAssertFalse(current.isEmpty)
                if label == "cold" { snapshot = current }
                else { XCTAssertEqual(current, snapshot, "Unchanged imports must not rewrite their metadata caches") }
            }
        }
        if ciProfile {
            // Process CPU excludes runner descheduling. Compare to this host's cold import,
            // with a 20 ms noise allowance, rather than a hardware-specific wall-clock limit.
            XCTAssertLessThan(passes[2].cpu, passes[0].cpu * 0.5 + 0.02, "Unchanged import must reuse parsed logs and SQLite results")
            return
        }
        // Release, 1,000 files: 0.77 s CPU before (cache decoding and archive rewrite), 0.08 s after.
        XCTAssertLessThan(passes[2].cpu, 0.6 * Double(fileCount) / 1000, "Unchanged imports must not decode or rewrite caches")
    }

    // An active session grows by a few lines between imports.
    func testAppendToLargeLog() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else { throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure imports") }
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date(), stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let file = logs.appendingPathComponent("session.jsonl")
        let rowCount = ciProfile ? 6000 : 20000
        try claudeLog(file: 0, rows: 0..<rowCount, stamp: stamp, content: 2000).write(to: file)
        let size = try XCTUnwrap(fm.attributesOfItem(atPath: file.path)[.size] as? Int)
        let roots = [ActivityLogs.Root(source: .claude, url: logs)]
        let cold = try measure("cold parse of \(size / 1_048_576) MiB log") {
            XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, rowCount)
        }
        var appended: (wall: Double, cpu: Double) = (0, 0)
        for round in 1...3 {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: try claudeLog(file: 0, rows: (rowCount + (round - 1) * 10)..<(rowCount + round * 10), stamp: stamp, content: 2000)); try handle.close()
            appended = try measure("append round \(round)") {
                XCTAssertEqual(try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now).events.count, rowCount + round * 10)
            }
        }
        if ciProfile {
            XCTAssertLessThan(appended.cpu, cold.cpu * 0.5 + 0.02, "Appending ten rows must not parse the entire log again")
            return
        }
        // Release: 1.7 s CPU before (full re-parse), 0.21 s after.
        XCTAssertLessThan(appended.cpu, 0.5, "Appending must not re-parse the whole log")
    }

    func testEventAggregation() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else { throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure imports") }
        let now = Date()
        let events = (0..<100000).map { row in ActivityEvent(id: "\(row)", source: .gemini, date: now.addingTimeInterval(-Double(row % 90) * 86400), model: "gemini-3.1-pro-preview", provider: "google", tokens: 130,
            usage: TokenBreakdown(input: 40, output: 30, cacheRead: 60)) }
        for pass in 0..<3 {
            let start = Date(), before = resources(), report = ActivityReport(events: events, now: now)
            XCTAssertEqual(report.days.reduce(0) { $0 + $1.responses }, events.count)
            print("BENCHMARK event aggregation pass \(pass): wall=\(Date().timeIntervalSince(start))s cpu=\(resources().cpu - before.cpu)s peakRSS=\(resources().rss)")
        }
    }

    // Stress fixture: 4,000 small archives, about 79 MB and 1.15 million usage events.
    func testManyUnchangedArchives() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else { throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure imports") }
        let fileCount = ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK_FILES"].flatMap(Int.init) ?? 4000
        guard (1...4000).contains(fileCount) else { throw XCTSkip("Use 1...4000 fixture files") }
        struct CachedFile: Codable {
            var version = 2
            var size: Int
            var modified: Date
            var events: [ActivityEvent]
            var skipped = 0
        }
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs"), cache = root.appendingPathComponent("cache")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let now = Date(), encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var bytes = 0
        for index in 0..<fileCount { try Data().write(to: logs.appendingPathComponent("session-\(index).jsonl")) }
        let enumerator = try XCTUnwrap(fm.enumerator(at: logs, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]))
        var index = 0
        while let file = enumerator.nextObject() as? URL {
            let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let events = (0..<288).map { row in ActivityEvent(id: "\(index)-\(row)", source: .gemini, date: now, model: "gemini-3.1-pro-preview", provider: "google", tokens: 130,
                usage: TokenBreakdown(input: 40, output: 30, cacheRead: 60, cacheWrite: 0)) }
            let data = try encoder.encode(CachedFile(size: 0, modified: modified, events: events))
            bytes += data.count
            try data.write(to: cache.appendingPathComponent(stableID("v2|gemini|\(file.path)") + ".plist"))
            index += 1
        }
        XCTAssertEqual(index, fileCount)
        print("BENCHMARK metadata fixture: \(fileCount) files, \(bytes) bytes")
        for pass in 0..<2 {
            let start = Date(), before = resources()
            let result = try ActivityLogs.read(roots: [.init(source: .gemini, url: logs)], cacheDirectory: cache, now: now)
            XCTAssertEqual(result.events.count, fileCount * 288)
            XCTAssertEqual(try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).count, fileCount)
            print("BENCHMARK unchanged metadata pass \(pass): wall=\(Date().timeIntervalSince(start))s cpu=\(resources().cpu - before.cpu)s peakRSS=\(resources().rss)")
            let aggregateStart = Date(), aggregateBefore = resources(), report = ActivityReport(events: result.events, now: now)
            XCTAssertEqual(report.days.reduce(0) { $0 + $1.responses }, fileCount * 288)
            print("BENCHMARK metadata aggregation pass \(pass): wall=\(Date().timeIntervalSince(aggregateStart))s cpu=\(resources().cpu - aggregateBefore.cpu)s peakRSS=\(resources().rss)")
        }
    }

    /// Peak and retained footprint of whole imports. Run alone so earlier tests do not leave freed pages behind.
    func testImportPeakMemory() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else { throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure imports") }
        let fileCount = ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK_FILES"].flatMap(Int.init) ?? 1400, rows = 400
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let logs = root.appendingPathComponent("claude/projects")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date(), formatter = ISO8601DateFormatter(), models = ["claude-opus-5", "claude-sonnet-4-5", "local-unpriced"]
        let stamps = (0..<90).map { formatter.string(from: now.addingTimeInterval(-Double($0) * 86400 - 3600)) }
        for file in 0..<fileCount {
            try autoreleasepool {
                var text = ""
                for row in 0..<rows {
                    // Every tenth file resumes the previous session, so its first rows repeat message IDs.
                    let id = file % 10 == 1 && row < 40 ? "\(file - 1)-\(row)" : "\(file)-\(row)"
                    text += #"{"type":"assistant","timestamp":"\#(stamps[(file + row) % 90])","requestId":"r-\#(id)","message":{"id":"m-\#(id)","model":"\#(models[row % 3])","usage":{"input_tokens":10,"output_tokens":\#(20 + row % 7),"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}"#
                    text += "\n"
                }
                let project = logs.appendingPathComponent("project-\(file % 20)")
                try fm.createDirectory(at: project, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: project.appendingPathComponent("session-\(file).jsonl"))
            }
        }
        func footprint() -> (current: Double, peak: Double) {
            var info = rusage_info_v4()
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
            return (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_interval_max_phys_footprint) / 1_048_576)
        }
        let roots = [ActivityLogs.Root(source: .claude, url: logs)], directory = root.appendingPathComponent("state"), absent = root.appendingPathComponent("absent.db").path
        malloc_zone_pressure_relief(nil, 0)
        let baseline = footprint().current
        for label in ["cold", "unchanged", "unchanged again"] {
            malloc_zone_pressure_relief(nil, 0)
            let before = footprint().current
            XCTAssertEqual(resetFootprintInterval(getpid()), 0)
            let start = Date(), cpu = resources().cpu
            let report = try ActivityImport.read(roots: roots, databasePath: absent, hosts: [], directory: directory, now: now).0
            let elapsed = (wall: Date().timeIntervalSince(start), cpu: resources().cpu - cpu), peak = footprint().peak
            XCTAssertEqual(report.days.reduce(0) { $0 + $1.responses }, fileCount * rows - (fileCount + 8) / 10 * 40)
            malloc_zone_pressure_relief(nil, 0)
            print(String(format: "BENCHMARK %@ import of %d events: wall=%.2fs cpu=%.2fs footprint before=%.1f MB peak=+%.1f MB after=+%.1f MB (vs baseline +%.1f MB)",
                         label, fileCount * rows, elapsed.wall, elapsed.cpu, before, peak - before, footprint().current - before, footprint().current - baseline))
        }
    }

    func testRepeatedImports() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else { throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure imports") }
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date(), stamp = ISO8601DateFormatter().string(from: now)
        let logs = root.appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        for file in 0..<10 {
            var data = Data()
            for row in 0..<1000 {
                data.append(try JSONSerialization.data(withJSONObject: ["type": "gemini", "id": "\(file)-\(row)", "timestamp": stamp,
                    "model": "gemini-3.1-pro-preview", "content": String(repeating: "x", count: 512),
                    "tokens": ["input": 100, "output": 20, "cached": 60, "thoughts": 10, "total": 130]]))
                data.append(10)
            }
            try data.write(to: logs.appendingPathComponent("session-\(file).jsonl"))
        }
        func measure(_ name: String, read: () throws -> Int) throws {
            let start = Date(), before = resources(), count = try read()
            print("BENCHMARK \(name): \(count) records wall=\(Date().timeIntervalSince(start))s cpu=\(resources().cpu - before.cpu)s peakRSS=\(resources().rss)")
        }
        for label in ["cold JSONL", "cached JSONL"] {
            try measure(label) {
                let events = try ActivityLogs.read(roots: [.init(source: .gemini, url: logs)], cacheDirectory: root.appendingPathComponent("cache"), now: now).events
                XCTAssertEqual(events.count, 10000); return events.count
            }
        }
        let appended = logs.appendingPathComponent("session-0.jsonl")
        let handle = try FileHandle(forWritingTo: appended)
        try handle.seekToEnd()
        for row in 0..<100 {
            var data = try JSONSerialization.data(withJSONObject: ["type": "gemini", "id": "append-\(row)", "timestamp": stamp,
                "model": "gemini-3.1-pro-preview", "tokens": ["input": 100, "output": 20, "total": 120]])
            data.append(10); try handle.write(contentsOf: data)
        }
        try handle.close()
        try measure("appended JSONL") {
            let events = try ActivityLogs.read(roots: [.init(source: .gemini, url: logs)], cacheDirectory: root.appendingPathComponent("cache"), now: now).events
            XCTAssertEqual(events.count, 10100); return events.count
        }
        let kilo = root.appendingPathComponent("kilo")
        try fm.createDirectory(at: kilo, withIntermediateDirectories: true)
        let dbFile = kilo.appendingPathComponent("kilo.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbFile.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE message (id TEXT, data TEXT, time_created INTEGER); BEGIN", nil, nil, nil), SQLITE_OK)
        let record = #"{"role":"assistant","modelID":"custom","cost":0.2,"tokens":{"input":100,"output":20,"cache":{"read":60}}}"#
        for row in 0..<20000 {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES ('\(row)', '\(record)', \(Int(now.timeIntervalSince1970 * 1000)))", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
        for label in ["cold OpenCode import", "unchanged OpenCode import", "second unchanged OpenCode import"] {
            try measure(label) {
                let report = try ActivityImport.read(roots: [], databasePath: dbFile.path, hosts: [], directory: root.appendingPathComponent("opencode-archive"), now: now).0
                let count = report.days.reduce(0) { $0 + $1.responses }
                XCTAssertEqual(count, 20000); return count
            }
        }
        for label in ["cold SQLite import", "unchanged SQLite import"] {
            try measure(label) {
                let report = try ActivityImport.read(roots: [.init(source: .kilo, url: kilo)], databasePath: root.appendingPathComponent("absent.db").path,
                                                     hosts: [], directory: root.appendingPathComponent("archive"), now: now).0
                let count = report.days.reduce(0) { $0 + $1.responses }
                XCTAssertEqual(count, 20000); return count
            }
        }
    }
}
