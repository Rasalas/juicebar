import XCTest
import CSQLite
@testable import JuicebarCore

final class ActivityCorrectnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEqualTokenCostCorrectionsUseLaterObservationIncludingZero() throws {
        let original = ActivityEvent(id: stableID("message"), source: .kilo, date: now, model: "custom", tokens: 30,
                                     usage: TokenBreakdown(input: 10, output: 20), reportedCost: 0.8)
        for cost in [0.2, 0, 1.2] {
            var corrected = original; corrected.reportedCost = cost
            for (events, expected) in [([original, corrected], cost), ([corrected, original], 0.8)] {
                let day = try XCTUnwrap(ActivityReport(events: events, now: now).days.first)
                XCTAssertEqual(day.apiCost, expected)
                XCTAssertEqual(day.responses, 1)
                XCTAssertEqual(day.pricedTokens, 30)
                XCTAssertEqual(ActivityEvent.preferred(events[0], events[1]).reportedCost, expected)
            }
        }
    }

    func testEqualTokenSplitAndModelCorrectionsReachPricing() throws {
        let original = ActivityEvent(id: "message", source: .codex, date: now, model: "unknown-model", tokens: 100,
                                     usage: TokenBreakdown(input: 90, output: 10))
        var corrected = original
        corrected.model = "gpt-6-astra"; corrected.provider = "openai"
        corrected.usage = TokenBreakdown(input: 10, output: 90)
        let day = try XCTUnwrap(ActivityReport(events: [original, corrected], now: now).days.first)
        XCTAssertEqual(day.pricedTokens, 100)
        XCTAssertEqual(day.apiCost, try XCTUnwrap(APICost.estimate(model: corrected.model, usage: corrected.usage)))
        XCTAssertTrue(day.unpricedModels.isEmpty)
    }

    func testCompletenessAndStreamingPreferencesAreOrderIndependent() throws {
        let complete = ActivityEvent(id: "same", source: .kilo, date: now, model: "custom", provider: "custom", tokens: 100,
                                     usage: TokenBreakdown(input: 20, output: 80), responseCount: 0, reportedCost: 0)
        var variants: [ActivityEvent] = []
        var incomplete = complete; incomplete.usage = nil; variants.append(incomplete)
        incomplete = complete; incomplete.usage = TokenBreakdown(input: -20, output: 120); variants.append(incomplete)
        incomplete = complete; incomplete.usage = TokenBreakdown(input: 1, output: 2); variants.append(incomplete)
        incomplete = complete; incomplete.reportedCost = nil; variants.append(incomplete)
        incomplete = complete; incomplete.reportedCost = -1; variants.append(incomplete)
        incomplete = complete; incomplete.model = tr("Unbekannt"); variants.append(incomplete)
        incomplete = complete; incomplete.provider = ""; variants.append(incomplete)
        incomplete = complete; incomplete.responseCount = nil; variants.append(incomplete)
        incomplete = complete; incomplete.tokens = 90; variants.append(incomplete)
        for variant in variants {
            for events in [[complete, variant], [variant, complete]] {
                let winner = ActivityEvent.preferred(events[0], events[1])
                XCTAssertEqual(winner.tokens, 100); XCTAssertEqual(winner.usage?.input, 20)
                XCTAssertEqual(winner.reportedCost, 0); XCTAssertEqual(winner.model, "custom")
                XCTAssertEqual(winner.provider, "custom"); XCTAssertEqual(winner.responseCount, 0)
                let day = try XCTUnwrap(ActivityReport(events: events, now: now).days.first)
                XCTAssertEqual(day.responses, 0); XCTAssertEqual(day.tokens, 100); XCTAssertEqual(day.pricedTokens, 100)
            }
        }
    }

    func testPiOriginalWinsEvenWhenForkIsLargerAndMoreComplete() throws {
        let original = ActivityEvent(id: "same", source: .pi, date: now, model: "custom", tokens: 100,
                                     sessionStartedAt: now.addingTimeInterval(-100))
        let fork = ActivityEvent(id: "same", source: .pi, date: now, model: "custom", tokens: 200,
                                 usage: TokenBreakdown(input: 100, output: 100), reportedCost: 9,
                                 sessionStartedAt: now.addingTimeInterval(-50))
        var noSession = fork; noSession.sessionStartedAt = nil
        for copy in [fork, noSession] {
            for events in [[original, copy], [copy, original]] {
                XCTAssertEqual(ActivityEvent.preferred(events[0], events[1]).tokens, 100)
                let day = try XCTUnwrap(ActivityReport(events: events, now: now).days.first)
                XCTAssertEqual(day.tokens, 100); XCTAssertEqual(day.responses, 1); XCTAssertEqual(day.pricedTokens, 0)
            }
        }
    }

    func testSameModelSplitCorrectionChangesCatalogCostWithoutChangingTotal() throws {
        let original = ActivityEvent(id: "same", source: .codex, date: now, model: "gpt-6-astra", tokens: 100,
                                     usage: TokenBreakdown(input: 90, output: 10))
        var corrected = original; corrected.usage = TokenBreakdown(input: 10, output: 90)
        let oldCost = try XCTUnwrap(ActivityReport(events: [original], now: now).days.first?.apiCost)
        let newCost = try XCTUnwrap(ActivityReport(events: [original, corrected], now: now).days.first?.apiCost)
        XCTAssertNotEqual(oldCost, newCost)
        XCTAssertEqual(newCost, try XCTUnwrap(APICost.estimate(model: corrected.model, usage: corrected.usage)))
    }

    func testEquallyCompleteMetadataConflictsUseLaterInput() throws {
        let original = ActivityEvent(id: "same", source: .opencode, date: now, model: "ox-alpha-free", provider: "opencode-go", tokens: 100,
                                     usage: TokenBreakdown(input: 20, output: 80), responseCount: 1)
        var corrected = original
        corrected.model = "gpt-6-astra"; corrected.provider = "openai"; corrected.responseCount = 2
        corrected.date = now.addingTimeInterval(-86400)
        for (events, winner) in [([original, corrected], corrected), ([corrected, original], original)] {
            let preferred = ActivityEvent.preferred(events[0], events[1])
            XCTAssertEqual(preferred.model, winner.model); XCTAssertEqual(preferred.provider, winner.provider)
            let day = try XCTUnwrap(ActivityReport(events: events, now: now).days.first)
            XCTAssertEqual(day.day, Calendar.current.startOfDay(for: winner.date))
            XCTAssertEqual(day.responses, winner.responseCount)
            XCTAssertEqual(day.apiCost, try XCTUnwrap(APICost.estimate(model: winner.model, provider: winner.provider, usage: winner.usage)))
        }
    }

    func testProfileArchiveOverlappingAndSymlinkRootsReadEachFileOnce() throws {
        let root = try directory(), profile = root.appendingPathComponent("profile")
        let sessions = profile.appendingPathComponent("sessions"), archives = profile.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: profile)
        for (folder, id) in [(sessions, "active"), (archives, "archived")] {
            let record: [String: Any] = ["type": "token_usage_record", "timestamp": now.timeIntervalSince1970,
                                         "payload": ["response_id": id, "usage": ["input_tokens": 10, "output_tokens": 20]]]
            var line = try JSONSerialization.data(withJSONObject: record); line.append(10)
            try line.write(to: folder.appendingPathComponent("log.jsonl"))
        }
        let roots = ActivityLogs.defaultRoots(accounts: [.init(provider: .codex, profileDirectory: profile.path),
                                                         .init(provider: .codex, profileDirectory: alias.path)],
                                             additional: [.init(source: .codex, url: profile)], home: root, environment: [:])
        XCTAssertEqual(roots.filter { $0.url.path == archives.resolvingSymlinksInPath().path }.count, 1)
        let result = try ActivityLogs.read(roots: roots, cacheDirectory: root.appendingPathComponent("cache"), now: now)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(ActivityReport(events: result.events, now: now).days.first?.tokens, 60)
    }

    func testCustomCodexProfilesIncludeArchivesAndDeduplicateRoots() {
        let profile = URL(fileURLWithPath: "/synthetic/profile")
        let roots = ActivityLogs.defaultRoots(accounts: [.init(provider: .codex, profileDirectory: profile.path)],
                                             additional: [.init(source: .codex, url: profile.appendingPathComponent("archived_sessions"))],
                                             home: URL(fileURLWithPath: "/synthetic/home"), environment: ["CODEX_HOME": profile.path])
        XCTAssertEqual(roots.filter { $0.source == .codex }.map(\.url.path).sorted(),
                       [profile.appendingPathComponent("archived_sessions").path, profile.appendingPathComponent("sessions").path])
        let customOnly = ActivityLogs.defaultRoots(accounts: [.init(provider: .codex, profileDirectory: profile.path)],
                                                  home: URL(fileURLWithPath: "/synthetic/home"), environment: [:])
        XCTAssertTrue(customOnly.contains { $0.url == profile.appendingPathComponent("archived_sessions") })
    }

    func testMovedLogCorrectionOverridesRetainedCacheAfterRestart() throws {
        let root = try directory(), logs = root.appendingPathComponent("sessions"), cache = root.appendingPathComponent("cache")
        let archives = root.appendingPathComponent("archived_sessions")
        for folder in [logs, archives] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let roots = [ActivityLogs.Root(source: .codex, url: logs), .init(source: .codex, url: archives)]
        func write(_ file: URL, input: Int) throws {
            let context: [String: Any] = ["type": "turn_context", "payload": ["model": "gpt-6-astra"]]
            let record: [String: Any] = ["type": "token_usage_record", "timestamp": now.timeIntervalSince1970,
                                         "payload": ["response_id": "same",
                                                     "usage": ["input_tokens": input, "output_tokens": 100 - input]]]
            var line = try JSONSerialization.data(withJSONObject: context); line.append(10)
            line.append(try JSONSerialization.data(withJSONObject: record)); line.append(10)
            try line.write(to: file)
        }
        func report(_ cache: URL) throws -> ActivityDay {
            let result = try ActivityLogs.read(roots: roots, cacheDirectory: cache, now: now)
            return try XCTUnwrap(ActivityReport(events: result.events, now: now).days.first)
        }
        let original = logs.appendingPathComponent("a.jsonl")
        try write(original, input: 90)
        let oldCost = try report(cache).apiCost
        XCTAssertEqual(oldCost, try XCTUnwrap(APICost.estimate(model: "gpt-6-astra", usage: TokenBreakdown(input: 90, output: 10))))
        try FileManager.default.removeItem(at: original)
        try write(archives.appendingPathComponent("b.jsonl"), input: 10)
        let expected = try XCTUnwrap(APICost.estimate(model: "gpt-6-astra", usage: TokenBreakdown(input: 10, output: 90)))
        XCTAssertNotEqual(oldCost, expected)
        XCTAssertEqual(try report(cache).apiCost, expected)
        XCTAssertEqual(try report(cache).responses, 1)
        let cold = root.appendingPathComponent("cold-cache")
        try FileManager.default.copyItem(at: cache, to: cold)
        XCTAssertEqual(try report(cold).apiCost, expected)
    }

    func testRemotePeerConflictOrderSurvivesStateRoundTrips() throws {
        let event = ActivityEvent(id: "same", source: .kilo, date: now, model: "custom", tokens: 100, reportedCost: 0.8)
        var corrected = event; corrected.reportedCost = 0.2
        var state = SSHActivity.State()
        state.databases["a"] = .init(fingerprint: "a", events: [event])
        state.databases["b"] = .init(fingerprint: "b", events: [corrected])
        let encoded = try PropertyListEncoder().encode(state)
        for _ in 0..<40 {
            let restored = try PropertyListDecoder().decode(SSHActivity.State.self, from: encoded)
            let events = restored.events(since: now.addingTimeInterval(-1), now: now)
            XCTAssertEqual(ActivityReport(events: events, now: now).days.first?.apiCost, 0.2)
        }
    }

    func testKiloCostAndSplitCorrectionsSurviveColdArchiveRead() throws {
        let root = try directory(), file = root.appendingPathComponent("kilo.db"), state = root.appendingPathComponent("state")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message(id TEXT, data TEXT, time_created INTEGER)", nil, nil, nil), SQLITE_OK)
        func write(input: Int, cost: Double) {
            let record = #"{"role":"assistant","modelID":"custom","providerID":"custom","cost":\#(cost),"tokens":{"input":\#(input),"output":\#(30 - input)}}"#
            XCTAssertEqual(sqlite3_exec(db, "DELETE FROM message; INSERT INTO message VALUES ('a', '\(record)', \(Int(now.timeIntervalSince1970 * 1000)))", nil, nil, nil), SQLITE_OK)
        }
        let roots = [ActivityLogs.Root(source: .kilo, url: file)]
        func read(_ directory: URL) throws -> ActivityReport {
            let (report, _) = try ActivityImport.read(roots: roots, databasePath: root.appendingPathComponent("absent.db").path,
                                                      hosts: [], directory: directory, now: now)
            return report
        }
        write(input: 10, cost: 0.8)
        XCTAssertEqual(try read(state).days.first?.apiCost, 0.8)
        write(input: 10, cost: 0.2)
        XCTAssertEqual(try read(state).days.first?.apiCost, 0.2)
        let archive = state.appendingPathComponent("activity-sources/kilo-\(stableID("kilo|\(file.path)")).plist")
        let beforeSplit = try Data(contentsOf: archive)
        write(input: 20, cost: 0.2)
        _ = try read(state)
        XCTAssertNotEqual(try Data(contentsOf: archive), beforeSplit, "Equal totals with changed splits must rewrite the archive")
        // A new path bypasses the decoded in-memory archive and simulates restart with the source unavailable.
        let cold = root.appendingPathComponent("cold")
        try FileManager.default.copyItem(at: state, to: cold)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try read(cold).days.first?.apiCost, 0.2)
        struct Archive: Decodable { var events: CompactEvents }
        let persisted = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: archive)).events.events()
        XCTAssertEqual(persisted.first?.usage?.input, 20)
        XCTAssertEqual(persisted.first?.usage?.output, 10)
    }

    func testRemoteDatabaseCorrectionsSurviveStateRoundTripAndKeepDeletedRows() throws {
        var state = SSHActivity.State()
        func consume(cost: Double, output: Int) throws {
            let event: [String: Any] = ["id": "message", "source": "kilo", "date": now.timeIntervalSince1970, "tokens": 30,
                                        "model": "custom", "reportedCost": cost, "tokenBreakdown": ["input": 30 - output, "output": output]]
            var rows: [[String: Any]] = [["database": "db", "fingerprint": "\(cost)|\(output)"], ["event": event]]
            if state.databases.isEmpty {
                var deleted = event; deleted["id"] = "deleted"
                rows.append(["event": deleted])
            }
            rows += [["endDatabase": true], ["done": true]]
            var iterator = rows.makeIterator()
            try SSHActivity.consume(host: "synthetic", state: &state, now: now) { try XCTUnwrap(iterator.next()) }
        }
        try consume(cost: 0.8, output: 20)
        try consume(cost: 0.2, output: 10)
        let saved = try PropertyListEncoder().encode(state)
        let restored = try PropertyListDecoder().decode(SSHActivity.State.self, from: saved)
        let events = restored.events(since: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first { $0.id == "message" }?.reportedCost, 0.2)
        XCTAssertEqual(events.first { $0.id == "message" }?.usage?.output, 10)
    }
}
