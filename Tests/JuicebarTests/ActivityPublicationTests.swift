import XCTest
import JuicebarCore
@testable import Juicebar

@MainActor
final class ActivityPublicationTests: XCTestCase {
    private struct Credentials: CredentialStore {
        func read(account: String) -> String? { XCTFail("Unexpected credential read"); return nil }
        func contains(account: String) -> Bool { false }
        func save(_ secret: String, account: String) { XCTFail("Unexpected credential write") }
        func remove(account: String) { XCTFail("Unexpected credential removal") }
    }
    private actor Gate {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !open { await withCheckedContinuation { waiters.append($0) } }
        }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    }
    private func fixture() throws -> (URL, HistoryDatabase) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-publication-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try HistoryDatabase(path: root.appendingPathComponent("usage.sqlite").path)
        try database.write([AccountConfiguration](), key: "accounts")
        return (root, database)
    }
    private nonisolated static func report(_ tokens: Double) -> ActivityReport {
        ActivityReport(events: [.init(id: "fixture", source: .pi, date: Date().addingTimeInterval(-1), model: "fixture", tokens: tokens)])
    }
    private func eventually(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testLocalPublicationPrecedesCatalogAndObsoleteReaderCannotPublishAfterCancelPauseOrShutdown() async throws {
        for action in ["cancel", "pause", "shutdown"] {
            let (root, database) = try fixture(), remote = Gate(), catalog = Gate()
            let store = AppStore(directory: root, credentials: Credentials(), notifications: NotificationFixture(), activityReader: { _, _, publish in
                await publish(Self.report(10), nil)
                await remote.wait()
                // Deliberately ignores cancellation to exercise the store's independent generation check.
                await publish(Self.report(999), nil)
            }, activityCatalogRefresh: { await catalog.wait() })
            await store.waitUntilReady()
            store.loadLocalUsage()
            try await eventually { store.activity?.days.first?.tokens == 10 }
            XCTAssertTrue(store.localUsageLoading, "Neither held catalog nor SSH may delay local values")
            let shutdown: Task<Void, Never>?
            if action == "pause" { store.isPaused = true; shutdown = nil }
            else if action == "shutdown" { shutdown = Task { await store.shutDown() }; await Task.yield() }
            else { store.cancelActivityImport(); shutdown = nil }
            await remote.release(); await catalog.release()
            if let shutdown { await shutdown.value } else { await store.shutDown() }
            XCTAssertEqual(store.activity?.days.first?.tokens, 10, action)
            XCTAssertEqual(try database.readCache(ActivityReport.self, key: "activity-report-v2")?.days.first?.tokens, 10, action)
        }
    }

    func testCancelledQueuedCacheWriteDoesNotReplaceDurableReport() async throws {
        let (root, database) = try fixture(), target = DispatchQueue(label: "fixture.blocked-persistence")
        try database.write(Self.report(7), key: "activity-report-v2")
        let persistence = AppPersistence(directory: root, demo: false, credentials: Credentials(), workerTarget: target)
        let store = AppStore(directory: root, credentials: Credentials(), notifications: NotificationFixture(), persistence: persistence,
            activityReader: { _, _, publish in await publish(Self.report(99), nil) }, activityCatalogRefresh: {})
        await store.waitUntilReady()
        target.suspend()
        store.loadLocalUsage()
        try await eventually { store.activity?.days.first?.tokens == 99 }
        store.cancelActivityImport()
        target.resume()
        await store.shutDown()
        XCTAssertEqual(try database.readCache(ActivityReport.self, key: "activity-report-v2")?.days.first?.tokens, 7)
    }

    func testSourceReloadWaitsForCancelledWorkerAndPublishesOnlyNewGeneration() async throws {
        let (root, database) = try fixture(), old = Gate(), newPublished = expectation(description: "new source generation")
        let store = AppStore(directory: root, credentials: Credentials(), notifications: NotificationFixture(), activityReader: { request, _, publish in
            if request.hosts.isEmpty {
                await publish(Self.report(10), nil)
                await old.wait()
                await publish(Self.report(999), nil)
            } else {
                await publish(Self.report(20), nil)
                newPublished.fulfill()
            }
        }, activityCatalogRefresh: {})
        await store.waitUntilReady()
        store.loadLocalUsage()
        try await eventually { store.activity?.days.first?.tokens == 10 }
        try await store.addSSHHost("synthetic")
        await old.release()
        await fulfillment(of: [newPublished], timeout: 3)
        await store.shutDown()
        XCTAssertEqual(store.activity?.days.first?.tokens, 20)
        XCTAssertEqual(try database.readCache(ActivityReport.self, key: "activity-report-v2")?.days.first?.tokens, 20)
    }
}
