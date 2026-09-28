import XCTest
import CSQLite
@testable import JuicebarCore

/// Opt-in measurements use synthetic data only; timing thresholds are not CI assertions.
final class ActivityPerformanceTests: XCTestCase {
    func testRepeatedImports() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else { throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure imports") }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
            let start = Date(), count = try read()
            print("BENCHMARK \(name): \(count) records in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        }
        for label in ["cold JSONL", "cached JSONL"] {
            try measure(label) {
                let events = try ActivityLogs.read(roots: [.init(source: .gemini, url: logs)], cacheDirectory: root.appendingPathComponent("cache"), now: now).events
                XCTAssertEqual(events.count, 10000); return events.count
            }
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
