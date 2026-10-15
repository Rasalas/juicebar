import XCTest
import CSQLite
import Darwin
@testable import JuicebarCore

/// Opt-in measurements use synthetic data only; timing thresholds are not CI assertions.
final class ActivityPerformanceTests: XCTestCase {
    private func resources() -> (cpu: Double, rss: Int) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return (cpu, Int(usage.ru_maxrss))
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
