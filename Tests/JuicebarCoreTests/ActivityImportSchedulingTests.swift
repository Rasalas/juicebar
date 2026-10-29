import XCTest
import CSQLite
@testable import JuicebarCore

final class ActivityImportSchedulingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-scheduling-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func request(_ root: URL, hosts: [String]) -> ActivityImport.Request {
        .init(roots: [], databasePath: root.appendingPathComponent("absent.db").path, hosts: hosts, directory: root, now: now)
    }
    private func event(_ id: String = "shared", cost: Double = 1) -> ActivityEvent {
        .init(id: id, source: .pi, date: now, model: "fixture", provider: "fixture", tokens: 100, reportedCost: cost)
    }
    private func finish(_ state: inout SSHActivity.State, event: ActivityEvent, now: Date) {
        state.carried.append(event); state.revision += 1; state.observedAt = now; state.complete = true
    }
    /// Gates are bounded and inspect task cancellation, like ProcessClient. No live SSH or timing-order assumptions.
    private final class Gate: @unchecked Sendable {
        let condition = NSCondition()
        var opened = false
        func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
        func wait() throws {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while !opened {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ProviderFailure.unavailable("Synthetic gate timed out") }
                _ = condition.wait(until: Date().addingTimeInterval(0.01))
            }
        }
    }
    private actor Reports {
        var values: [ActivityReport] = []
        func append(_ report: ActivityReport) { values.append(report) }
    }

    func testLocalAndFastPeerPublishWhileSlowHostIsHeld() async throws {
        let root = try directory(), gate = Gate(), reports = Reports()
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let record = "{\"type\":\"assistant\",\"timestamp\":\"\(ISO8601DateFormatter().string(from: now))\",\"message\":{\"id\":\"local\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":17,\"output_tokens\":3}}}\n"
        try Data(record.utf8).write(to: logs.appendingPathComponent("local.jsonl"))
        var request = request(root, hosts: ["slow", "fast"])
        request.roots = [.init(source: .claude, url: logs)]
        let localVisible = expectation(description: "local before SSH completion"), peerVisible = expectation(description: "healthy peer before slow completion")
        let task = Task {
            try await ActivityImport.readProgressively(request, collectors: .init(remote: { [self] host, state, now in
                if host == "slow" { try gate.wait() }
                finish(&state, event: event(host), now: now)
            })) { report, _ in
                await reports.append(report)
                if report.days.contains(where: { $0.source == .claude && $0.tokens == 20 }), report.sources?.filter({ $0.phase == .checking }).count == 2 { localVisible.fulfill() }
                if report.days.contains(where: { $0.source == .pi }), report.sources?.contains(where: { $0.id == "ssh|slow" && $0.phase == .checking }) == true { peerVisible.fulfill() }
            }
        }
        defer { gate.open(); task.cancel() }
        await fulfillment(of: [localVisible, peerVisible], timeout: 3)
        let partial = await reports.values.last
        XCTAssertEqual(partial?.days.reduce(0) { $0 + $1.tokens }, 120)
        gate.open(); try await task.value
        let final = await reports.values.last
        XCTAssertEqual(final?.days.reduce(0) { $0 + $1.tokens }, 220)
    }

    func testConcurrencyCapCancellationAndCheckpointRecovery() async throws {
        let root = try directory(), gate = Gate(), reports = Reports(), started = expectation(description: "three running hosts")
        started.expectedFulfillmentCount = ActivityImport.remoteConcurrency
        let counter = Counter(), control = ActivityImport.Control()
        let task = Task {
            try await ActivityImport.readProgressively(request(root, hosts: (0..<8).map { "host\($0)" }), control: control,
                collectors: .init(remote: { [self] host, state, now in
                    counter.start(); defer { counter.stop() }
                    // A completed checkpoint is retained even if this host never completes.
                    state.carried.append(event(host)); state.revision += 1
                    started.fulfill(); try gate.wait()
                    state.observedAt = now; state.complete = true
                })) { report, _ in await reports.append(report) }
        }
        await fulfillment(of: [started], timeout: 3)
        control.cancel(); task.cancel()
        do { try await task.value; XCTFail("Cancelled import returned normally") } catch is CancellationError { }
        XCTAssertEqual(counter.maximum, ActivityImport.remoteConcurrency)
        XCTAssertEqual(counter.total, ActivityImport.remoteConcurrency, "Queued hosts must never start")
        XCTAssertEqual(counter.active, 0, "Cancellation must drain all running work")
        let publicationCount = await reports.values.count
        XCTAssertEqual(publicationCount, 1, "No obsolete completion publication")
        let recovered = Reports()
        try await ActivityImport.readProgressively(request(root, hosts: ["host0", "host1", "host2"]), collectors: .init(remote: { _, _, _ in
            throw ProviderFailure.unavailable("offline")
        })) { report, _ in await recovered.append(report) }
        let final = await recovered.values.last
        XCTAssertEqual(final?.days.reduce(0) { $0 + $1.tokens }, 300)
        XCTAssertTrue(final?.sources?.filter { $0.id.hasPrefix("ssh|") }.allSatisfy { $0.lastSuccess == nil && $0.phase == .unavailable } == true)
    }
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var maximum = 0, active = 0, total = 0
        func start() { lock.withLock { active += 1; total += 1; maximum = max(maximum, active) } }
        func stop() { lock.withLock { active -= 1 } }
    }

    func testPeerWinnerIndependentOfCompletionOrderAndNoDoubleCounting() async throws {
        for first in ["a", "b"] {
            let root = try directory(), gate = Gate(), reports = Reports()
            let firstPublished = expectation(description: "first peer published")
            let task = Task {
                try await ActivityImport.readProgressively(request(root, hosts: ["a", "b"]), collectors: .init(remote: { [self] host, state, now in
                    if host != first { try gate.wait() }
                    finish(&state, event: event(cost: host == "a" ? 1 : 2), now: now)
                })) { report, _ in
                    await reports.append(report)
                    if report.sources?.contains(where: { $0.id == "ssh|\(first)" && $0.phase == .success }) == true,
                       report.sources?.contains(where: { $0.phase == .checking }) == true { firstPublished.fulfill() }
                }
            }
            await fulfillment(of: [firstPublished], timeout: 3)
            gate.open(); try await task.value
            let final = await reports.values.last
            XCTAssertEqual(final?.days.first?.tokens, 100)
            XCTAssertEqual(final?.days.first?.apiCost, 2, "Later configured peer wins equal evidence")
        }
    }

    func testHealthSidecarCannotMakeCorruptHostArchiveNotDue() async throws {
        let root = try directory(), reports = Reports(), counter = Counter()
        var request = request(root, hosts: ["a"])
        let collectors = ActivityImport.Collectors(remote: { [self] _, state, now in
            counter.start(); defer { counter.stop() }
            finish(&state, event: event(), now: now)
        })
        try await ActivityImport.readProgressively(request, collectors: collectors) { _, _ in }
        let file = root.appendingPathComponent("activity-sources/ssh-\(stableID("ssh|a")).plist")
        try Data("corrupt synthetic cache".utf8).write(to: file, options: .atomic)
        request.now = now.addingTimeInterval(60); request.refreshRemote = false
        try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        XCTAssertEqual(counter.total, 2, "Health metadata cannot substitute for a valid event archive")
        let final = await reports.values.last
        XCTAssertEqual(final?.days.first?.tokens, 100)
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.phase, .success)
        try Data("corrupt again".utf8).write(to: file, options: .atomic)
        request.now = now.addingTimeInterval(120)
        try await ActivityImport.readProgressively(request, collectors: .init(remote: { _, _, _ in
            throw ProviderFailure.unavailable("offline")
        })) { report, _ in await reports.append(report) }
        let unavailable = await reports.values.last
        XCTAssertEqual(unavailable?.sources?.first { $0.id == "ssh|a" }?.phase, .unavailable)
        XCTAssertEqual(unavailable?.sources?.first { $0.id == "ssh|a" }?.lastSuccess, now.addingTimeInterval(60))
    }

    func testQueuedImportCancellationDoesNotEnterSameDirectory() async throws {
        let root = try directory(), gate = Gate(), started = expectation(description: "first import owns archives")
        let first = Task {
            try await ActivityImport.readProgressively(request(root, hosts: ["a"]), collectors: .init(remote: { _, _, _ in
                started.fulfill(); try gate.wait()
            })) { _, _ in }
        }
        await fulfillment(of: [started], timeout: 3)
        let queued = Task {
            try await ActivityImport.readProgressively(request(root, hosts: ["a"]), collectors: .init(remote: { _, _, _ in
                XCTFail("Cancelled queued import reached collector")
            })) { _, _ in XCTFail("Cancelled queued import published") }
        }
        queued.cancel()
        do { try await queued.value; XCTFail("Queued import ignored cancellation") } catch is CancellationError { }
        first.cancel(); gate.open()
        _ = try? await first.value
    }

    func testUnchangedSSHDatabaseKeepsCoverageAcrossRestartUntilRetainedUsageExpires() async throws {
        let root = try directory(), reports = Reports()
        var request = request(root, hosts: ["a"])
        let collectors = ActivityImport.Collectors(remote: { [self] host, state, at in
            var rows: [[String: Any]]
            if state.databases.isEmpty {
                rows = [
                    ["database": "fixture", "fingerprint": "unchanged"],
                    ["event": ["id": "a", "source": "opencode", "date": now.timeIntervalSince1970, "tokens": 100]],
                    ["endDatabase": true], ["notice": "Synthetic row limit reached"], ["done": true]
                ]
            } else { rows = [["database": "fixture", "unchanged": true], ["done": true]] }
            if at == now.addingTimeInterval(45 * 86400) {
                state.carried.append(.init(id: "later", source: .opencode, date: at, model: "fixture", tokens: 40))
                state.revision += 1
            }
            var index = 0
            try SSHActivity.consume(host: host, state: &state, now: at) {
                defer { index += 1 }
                return rows[index]
            }
        })
        try await ActivityImport.readProgressively(request, collectors: collectors) { _, _ in }
        request.now = now.addingTimeInterval(60)
        try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        var final = await reports.values.last
        XCTAssertEqual(final?.days.first?.tokens, 100)
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.coverage, ["a: Synthetic row limit reached"])
        let cold = try directory().appendingPathComponent("cold")
        try FileManager.default.copyItem(at: root, to: cold)
        request.directory = cold; request.now = now.addingTimeInterval(120)
        try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        final = await reports.values.last
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.coverage, ["a: Synthetic row limit reached"])
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.lastSuccess, request.now)
        request.now = now.addingTimeInterval(45 * 86400)
        try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        final = await reports.values.last
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.coverage, ["a: Synthetic row limit reached"])
        request.now = now.addingTimeInterval(90 * 86400 - 60)
        try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        request.now = now.addingTimeInterval(90 * 86400 + 60); request.refreshRemote = false
        try await ActivityImport.readProgressively(request, collectors: .init(remote: { _, _, _ in XCTFail("Host is not due") })) { report, _ in await reports.append(report) }
        final = await reports.values.last
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.phase, .cached)
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.coverage, [], "Expiry also applies before a cached publication")
        request.refreshRemote = true
        request.now = now.addingTimeInterval(91 * 86400)
        try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        final = await reports.values.last
        XCTAssertEqual(final?.days.reduce(0) { $0 + $1.tokens }, 40, "Newer complete usage must not extend an older coverage limit")
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.coverage, [])
    }

    func testLocalSummaryAndSourceLastSuccessSurviveUnchangedReadFailureAndRestart() throws {
        let root = try directory(), file = root.appendingPathComponent("opencode.db"), state = root.appendingPathComponent("state")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let record = #"{"role":"assistant","modelID":"custom","tokens":{"input":5}}"#
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message(id TEXT,data TEXT,time_created INTEGER); INSERT INTO message VALUES('a','\(record)',\(Int(now.timeIntervalSince1970 * 1000)));", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        func read(_ directory: URL, at: Date) throws -> ActivityImport.Result {
            try ActivityImport.read(roots: [], databasePath: file.path, hosts: [], directory: directory, now: at)
        }
        _ = try read(state, at: now)
        let success = now.addingTimeInterval(60)
        XCTAssertEqual(try read(state, at: success).1?.observedAt, success)
        let cold = root.appendingPathComponent("cold")
        try FileManager.default.copyItem(at: state, to: cold)
        try FileManager.default.removeItem(at: file)
        let failed = try read(cold, at: now.addingTimeInterval(120))
        XCTAssertEqual(failed.1?.observedAt, success, "Fallback summary must preserve last successful verification, never assembly time")
        XCTAssertEqual(failed.0.sources?.first?.lastSuccess, success)
        XCTAssertEqual(failed.0.sources?.first?.phase, .stale)
        XCTAssertEqual(failed.0.days.first?.tokens, 5)
        let archive = cold.appendingPathComponent("activity-sources/\(stableID("opencode|\(file.path)")).plist")
        try Data("corrupt synthetic archive".utf8).write(to: archive, options: .atomic)
        let missing = try read(cold, at: now.addingTimeInterval(180))
        XCTAssertTrue(missing.0.days.isEmpty)
        XCTAssertNil(missing.1)
        XCTAssertEqual(missing.0.sources?.first?.lastSuccess, success)
        XCTAssertEqual(missing.0.sources?.first?.phase, .unavailable, "A success timestamp cannot substitute for a readable fallback")
    }

    func testMissingLogRootRequiresReadableAttributedFallbackAfterRestart() throws {
        let fm = FileManager.default, root = try directory().resolvingSymlinksInPath(), state = root.appendingPathComponent("state")
        let missing = ActivityLogs.Root(source: .claude, url: root.appendingPathComponent("removed"))
        let healthy = ActivityLogs.Root(source: .claude, url: root.appendingPathComponent("healthy"))
        for (source, tokens) in [(missing, 20), (healthy, 30)] {
            try fm.createDirectory(at: source.url, withIntermediateDirectories: true)
            let row = #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: now))","message":{"id":"\#(tokens)","model":"fixture","usage":{"input_tokens":\#(tokens)}}}"# + "\n"
            try Data(row.utf8).write(to: source.url.appendingPathComponent("usage.jsonl"))
        }
        func read(_ state: URL, at: Date) throws -> ActivityReport {
            try ActivityImport.read(roots: [missing, healthy], databasePath: root.appendingPathComponent("absent.db").path,
                                    hosts: [], directory: state, now: at).0
        }
        _ = try ActivityImport.read(roots: [missing], databasePath: root.appendingPathComponent("absent.db").path,
                                    hosts: [], directory: state, now: now)
        let caches = try fm.contentsOfDirectory(at: state.appendingPathComponent("activity-cache"), includingPropertiesForKeys: nil)
        XCTAssertEqual(caches.count, 1)
        let key = try XCTUnwrap(caches.first).lastPathComponent
        XCTAssertEqual(try read(state, at: now).days.reduce(0) { $0 + $1.tokens }, 50)
        try fm.removeItem(at: missing.url)
        for variant in ["valid", "corrupt", "legacy"] {
            let cold = root.appendingPathComponent(variant)
            try fm.copyItem(at: state, to: cold)
            let cache = cold.appendingPathComponent("activity-cache/\(key)")
            if variant == "corrupt" { try Data("corrupt synthetic cache".utf8).write(to: cache, options: .atomic) }
            if variant == "legacy" {
                var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: cache), format: nil) as? [String: Any])
                plist.removeValue(forKey: "rootID")
                try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: cache, options: .atomic)
            }
            for offset in [60.0, 120.0] {
                let report = try read(cold, at: now.addingTimeInterval(offset))
                let health = report.sources?.first { $0.id == stableID(missing.id) }
                XCTAssertEqual(health?.phase, variant == "valid" ? .stale : .unavailable, variant)
                XCTAssertEqual(health?.lastSuccess, now)
                XCTAssertEqual(report.days.reduce(0) { $0 + $1.tokens }, variant == "corrupt" ? 30 : 50)
                XCTAssertEqual(report.sources?.first { $0.id == stableID(healthy.id) }?.phase, .success)
                if variant == "legacy" { XCTAssertTrue(report.sources?.contains { $0.phase == .unknown && $0.includes(.claude) } == true) }
            }
        }
        let expired = try read(state, at: now.addingTimeInterval(91 * 86400))
        XCTAssertEqual(expired.sources?.first { $0.id == stableID(missing.id) }?.phase, .unavailable)
    }

    func testColdNotDueRemoteCacheDetectsAtomicArchiveReplacement() async throws {
        let root = try directory(), archives = root.appendingPathComponent("activity-sources"), reports = Reports()
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let file = archives.appendingPathComponent("ssh-\(stableID("ssh|a")).plist")
        var state = SSHActivity.State()
        state.carried = [event(cost: 1)]; state.observedAt = now; state.complete = true
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(state).write(to: file, options: .atomic)
        var request = request(root, hosts: ["a"]); request.refreshRemote = false
        let collectors = ActivityImport.Collectors(remote: { _, _, _ in
            XCTFail("The synthetic host is not due")
            throw ProviderFailure.unavailable("Unexpected synthetic collection")
        })
        for _ in 0..<2 {
            try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        }
        let cached = await reports.values.last
        XCTAssertEqual(cached?.days.first?.apiCost, 1)
        // Equal-sized corrections with an unchanged timestamp still have a new file identity.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        state.carried = [event(cost: 2)]
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])], ofItemAtPath: file.path)
        try await ActivityImport.readProgressively(request, collectors: collectors) { report, _ in await reports.append(report) }
        let corrected = await reports.values.last
        XCTAssertEqual(corrected?.days.first?.apiCost, 2)
        XCTAssertEqual(corrected?.days.first?.tokens, 100)
        XCTAssertEqual(corrected?.sources?.first { $0.id == "ssh|a" }?.phase, .cached)
    }

    func testMissingKiloRootDoesNotAdvanceSuccessfulObservationAndRemovalRetainsHistory() throws {
        let root = try directory(), file = root.appendingPathComponent("kilo.db"), state = root.appendingPathComponent("state")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let record = #"{"role":"assistant","modelID":"custom","tokens":{"input":5}}"#
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message(id TEXT,data TEXT,time_created INTEGER); INSERT INTO message VALUES('a','\(record)',\(Int(now.timeIntervalSince1970 * 1000)));", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        func read(roots: [ActivityLogs.Root], at: Date) throws -> ActivityReport {
            try ActivityImport.read(roots: roots, databasePath: root.appendingPathComponent("absent.db").path, hosts: [], directory: state, now: at).0
        }
        let roots = [ActivityLogs.Root(source: .kilo, url: file)]
        _ = try read(roots: roots, at: now)
        try FileManager.default.removeItem(at: file)
        let failed = try read(roots: roots, at: now.addingTimeInterval(60))
        XCTAssertEqual(failed.sources?.first { $0.tools == [.kilo] }?.lastSuccess, now)
        XCTAssertEqual(failed.sources?.first { $0.tools == [.kilo] }?.phase, .stale)
        XCTAssertEqual(failed.days.first?.tokens, 5)
        let removed = try read(roots: [], at: now.addingTimeInterval(120))
        XCTAssertEqual(removed.sources?.first { $0.tools == [.kilo] }?.phase, .retained)
        XCTAssertNil(removed.sources?.first { $0.tools == [.kilo] }?.issue)
        XCTAssertEqual(removed.days.first?.tokens, 5)
        let expired = try read(roots: [], at: now.addingTimeInterval(91 * 86400))
        XCTAssertFalse(expired.sources?.contains { $0.tools == [.kilo] } == true)
        XCTAssertTrue(expired.days.isEmpty)
        let metadata = try Data(contentsOf: state.appendingPathComponent("activity-sources/local-health.plist"))
        XCTAssertNil(metadata.range(of: Data(file.path.utf8)), "Usage health metadata must not store configured paths")
    }

    func testReportPricingDateBelongsToItsCatalogSnapshot() {
        var catalog = ModelCatalog.shared.snapshot
        catalog.verifiedOn = "2026-01-01"
        var builder = ActivityReport.Builder(now: now, catalog: catalog)
        builder.add(event())
        catalog.verifiedOn = "2026-02-01"
        XCTAssertEqual(builder.report().pricingVerifiedOn, "2026-01-01")
    }

    func testLegacyReportHasUnknownFreshnessAndCacheLoadingDoesNotInventSuccess() throws {
        let report = ActivityReport(events: [event()])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        json.removeValue(forKey: "sources")
        json.removeValue(forKey: "pricingVerifiedOn")
        var legacy = try JSONDecoder().decode(ActivityReport.self, from: JSONSerialization.data(withJSONObject: json))
        legacy.markCached()
        XCTAssertNil(legacy.sources)
        XCTAssertNil(legacy.pricingVerifiedOn)
        legacy.sources = [.init(id: "checking", label: "checking", phase: .checking),
                          .init(id: "success", label: "success", phase: .success, lastSuccess: now)]
        legacy.markCached()
        XCTAssertEqual(legacy.sources?.map(\.phase), [.cached, .cached])
        let local = ActivitySourceHealth(id: "local", label: "local", tools: [.pi], phase: .success)
        XCTAssertTrue(local.includes(.pi)); XCTAssertFalse(local.includes(.claude))
        XCTAssertTrue(local.includes(nil)); XCTAssertTrue(legacy.sources!.first!.includes(.claude))
        XCTAssertNil(legacy.sources?.first?.lastSuccess)
        XCTAssertEqual(legacy.sources?.last?.lastSuccess, now)
    }

    func testLegacyOrphanUsageKeepsUnknownFreshnessBesideSuccessfulCurrentRoot() throws {
        struct LegacyFile: Encodable {
            var version = 2
            var size = 10
            var modified: Date
            var events: [ActivityEvent]
            var skipped = 0
        }
        struct LegacyArchive: Encodable {
            var events: CompactEvents
            var observedAt: Date
            var retainedSource = ActivitySource.kilo
        }
        let root = try directory(), state = root.appendingPathComponent("state")
        let cache = state.appendingPathComponent("activity-cache"), logs = root.appendingPathComponent("empty-pi")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = LegacyFile(modified: now, events: [event()])
        try PropertyListEncoder().encode(file).write(to: cache.appendingPathComponent("removed-folder.plist"))
        let archives = state.appendingPathComponent("activity-sources")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let legacyKilo = LegacyArchive(events: CompactEvents([.init(id: "old-kilo", source: .kilo, date: now, model: "fixture", tokens: 25)]), observedAt: now)
        try PropertyListEncoder().encode(legacyKilo).write(to: archives.appendingPathComponent("kilo-legacy.plist"))
        func read(_ directory: URL, at: Date) throws -> ActivityReport {
            try ActivityImport.read(roots: [.init(source: .pi, url: logs)], databasePath: root.appendingPathComponent("absent.db").path,
                                    hosts: [], directory: directory, now: at).0
        }
        func verify(_ report: ActivityReport) throws {
            XCTAssertEqual(report.days.filter { $0.source == .pi }.reduce(0) { $0 + $1.tokens }, 100)
            let sources = report.sources?.filter { $0.includes(.pi) } ?? []
            XCTAssertTrue(sources.contains { $0.phase == .success }, "The current empty root really was read")
            let unknown = sources.filter { $0.phase == .unknown }
            XCTAssertEqual(unknown.count, 1, "Legacy orphan usage needs its own freshness warning")
            XCTAssertNil(unknown.first?.lastSuccess, "Cache modification is not a successful observation")
            XCTAssertFalse(unknown.first?.includes(.claude) == true)
            let kilo = report.sources?.first { $0.tools == [.kilo] }
            XCTAssertEqual(kilo?.phase, .retained)
            XCTAssertEqual(kilo?.lastSuccess, now, "Legacy aggregate archives preserve their actual observation")
        }
        try verify(read(state, at: now))
        try verify(read(state, at: now.addingTimeInterval(60)))
        let cold = root.appendingPathComponent("cold")
        try FileManager.default.copyItem(at: state, to: cold)
        try verify(read(cold, at: now.addingTimeInterval(120)))
        let expired = try read(cold, at: now.addingTimeInterval(91 * 86400))
        XCTAssertTrue(expired.days.isEmpty)
        XCTAssertFalse(expired.sources?.contains { $0.phase == .unknown } == true)
    }

    func testSuccessFailureRestartCadenceAndRecoveryKeepLastSuccess() async throws {
        let root = try directory(), reports = Reports()
        var request = request(root, hosts: ["a"])
        let successful = ActivityImport.Collectors(remote: { [self] _, state, now in finish(&state, event: event(), now: now) })
        try await ActivityImport.readProgressively(request, collectors: successful) { report, _ in await reports.append(report) }
        request.now = now.addingTimeInterval(60); request.refreshRemote = false
        try await ActivityImport.readProgressively(request, collectors: .init(remote: { _, _, _ in XCTFail("Not due") })) { report, _ in await reports.append(report) }
        var final = await reports.values.last
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.phase, .cached)
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.lastSuccess, now)
        request.refreshRemote = true
        try await ActivityImport.readProgressively(request, collectors: .init(remote: { _, state, now in
            state.observedAt = now; state.complete = true
        })) { report, _ in await reports.append(report) }
        // New directory bypasses all decoded memory, including the compact remote cache.
        let cold = try directory().appendingPathComponent("cold")
        try FileManager.default.copyItem(at: root, to: cold)
        request.directory = cold; request.refreshRemote = true
        try await ActivityImport.readProgressively(request, collectors: .init(remote: { _, _, _ in throw ProviderFailure.unavailable("offline") })) { report, _ in await reports.append(report) }
        final = await reports.values.last
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.phase, .stale)
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.lastSuccess, now.addingTimeInterval(60))
        XCTAssertEqual(final?.days.first?.tokens, 100)
        request.now = now.addingTimeInterval(120)
        try await ActivityImport.readProgressively(request, collectors: successful) { report, _ in await reports.append(report) }
        final = await reports.values.last
        XCTAssertEqual(final?.sources?.first { $0.id == "ssh|a" }?.lastSuccess, request.now)
        XCTAssertNil(final?.sources?.first { $0.id == "ssh|a" }?.issue)
        XCTAssertEqual(final?.days.first?.tokens, 100)
        request.hosts = []
        try await ActivityImport.readProgressively(request, collectors: successful) { report, _ in await reports.append(report) }
        final = await reports.values.last
        XCTAssertTrue(final?.days.isEmpty == true, "Removed hosts stop contributing, unlike retained local folders")
        XCTAssertFalse(final?.sources?.contains { $0.id == "ssh|a" } == true)
    }
}
