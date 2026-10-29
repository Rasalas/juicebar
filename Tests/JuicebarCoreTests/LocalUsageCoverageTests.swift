import XCTest
import CSQLite
@testable import JuicebarCore

final class LocalUsageCoverageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func database(_ body: (OpaquePointer?, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message(id TEXT, data TEXT, time_created INTEGER); CREATE TABLE session_message(id TEXT, data TEXT, time_created INTEGER)", nil, nil, nil), SQLITE_OK)
        try body(db, file)
    }

    private func insert(_ db: OpaquePointer?, id: String, model: String, cost: Double?, table: String = "message", future: Bool = false) throws {
        var record: [String: Any] = ["role": "assistant", "modelID": model, "providerID": "custom", "tokens": ["input": 10, "output": 20]]
        record["cost"] = cost
        let json = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        let time = Int(now.addingTimeInterval(future ? 100 : -100).timeIntervalSince1970 * 1000)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO \(table) VALUES ('\(id)', '\(json)', \(time))", nil, nil, nil), SQLITE_OK)
    }

    func testMissingPartialZeroAndInvalidCostsHaveExplicitCoverageAndLabels() throws {
        try database { db, file in
            try insert(db, id: "missing", model: "missing", cost: nil)
            try insert(db, id: "partial-1", model: "partial", cost: 0.4)
            try insert(db, id: "partial-2", model: "partial", cost: nil)
            try insert(db, id: "zero", model: "zero", cost: 0)
            try insert(db, id: "negative", model: "negative", cost: -1)
            let report = try OpenCodeHistory.read(path: file.path, now: now)
            let models = Dictionary(uniqueKeysWithValues: report.models.map { ($0.model, $0) })
            let missing = try XCTUnwrap(models["missing"]), partial = try XCTUnwrap(models["partial"])
            let zero = try XCTUnwrap(models["zero"]), invalid = try XCTUnwrap(models["negative"])
            XCTAssertEqual(missing.costCoverage, .unknown); XCTAssertEqual(missing.pricedTokens, 0)
            XCTAssertEqual(missing.costLabel, tr("Unbekannt"))
            XCTAssertEqual(partial.costCoverage, .partial); XCTAssertEqual(partial.pricedTokens, 30)
            XCTAssertEqual(partial.tokens, 60); XCTAssertEqual(partial.cost, 0.4)
            XCTAssertEqual(partial.costLabel, "≥ " + partial.cost.formatted(.currency(code: "USD").locale(Localization.locale)))
            XCTAssertEqual(zero.costCoverage, .complete); XCTAssertEqual(zero.pricedTokens, 30)
            XCTAssertEqual(zero.costLabel, zero.cost.formatted(.currency(code: "USD").locale(Localization.locale)))
            XCTAssertEqual(invalid.costCoverage, .unknown); XCTAssertEqual(invalid.cost, 0)
            let cached = try OpenCodeHistory.read(path: file.path, now: now.addingTimeInterval(1))
            XCTAssertEqual(cached.models, report.models)
        }
    }

    func testCoverageUsesDeduplicatedInWindowRows() throws {
        try database { db, file in
            try insert(db, id: "migrated", model: "custom", cost: nil)
            try insert(db, id: "migrated", model: "custom", cost: 0, table: "session_message")
            try insert(db, id: "future", model: "custom", cost: nil, future: true)
            let report = try OpenCodeHistory.read(path: file.path, now: now)
            XCTAssertEqual(report.messageCount, 1)
            XCTAssertEqual(report.models.first?.costCoverage, .complete)
            XCTAssertFalse(report.notice.contains(tr(" Für einige Nachrichten fehlen Kosten.")))
        }
    }

    func testOldCachesDecodeWithUnknownCoverageAndNewCachesRoundTrip() throws {
        let legacy = Data(#"{"id":"custom/m","provider":"custom","model":"m","tokens":30,"cost":0}"#.utf8)
        let old = try JSONDecoder().decode(ModelUsage.self, from: legacy)
        XCTAssertNil(old.pricedTokens); XCTAssertEqual(old.costCoverage, .unknown)
        XCTAssertEqual(old.costLabel, tr("Unbekannt"))
        for priced in [0.0, 15, 30] {
            var model = old; model.pricedTokens = priced
            let saved = try PropertyListEncoder().encode(model)
            XCTAssertEqual(try PropertyListDecoder().decode(ModelUsage.self, from: saved), model)
        }
    }

    func testCostOnlyCorrectionRewritesPersistedLocalSummary() throws {
        try database { db, file in
            try insert(db, id: "a", model: "custom", cost: nil)
            let directory = file.deletingLastPathComponent().appendingPathComponent("state")
            _ = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: directory, now: now)
            XCTAssertEqual(sqlite3_exec(db, "DELETE FROM message", nil, nil, nil), SQLITE_OK)
            try insert(db, id: "a", model: "custom", cost: 0)
            let updated = try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: directory, now: now)
            XCTAssertEqual(updated.1?.models.first?.costCoverage, .complete)
            struct Archive: Decodable { var summary: LocalUsageReport? }
            let archive = directory.appendingPathComponent("activity-sources/\(stableID("opencode|\(file.path)")).plist")
            let restored = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: archive))
            XCTAssertEqual(restored.summary?.models.first?.costCoverage, .complete)
            XCTAssertEqual(restored.summary?.models.first?.pricedTokens, 30)
        }
    }
}
