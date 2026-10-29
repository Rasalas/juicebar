import XCTest
import CSQLite
import JuicebarCore
@testable import Juicebar

private struct IsolatedCredentials: CredentialStore {
    func read(account: String) -> String? { nil }
    func contains(account: String) -> Bool { false }
    func save(_ secret: String, account: String) {}
    func remove(account: String) {}
}

private final class DelayedCredentials: CredentialStore {
    let started = XCTestExpectation(description: "Credential write inside SQLite transaction")
    let release = DispatchSemaphore(value: 0)
    func read(account: String) -> String? { XCTAssertFalse(Thread.isMainThread); return nil }
    func contains(account: String) -> Bool { XCTAssertFalse(Thread.isMainThread); return false }
    func save(_ secret: String, account: String) {
        XCTAssertFalse(Thread.isMainThread)
        started.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 4), .success)
    }
    func remove(account: String) { XCTAssertFalse(Thread.isMainThread) }
}

actor NotificationFixture: AppNotifications {
    var failDelivery = false
    var failAuthorization = false
    private(set) var deliveries: [AppNotification] = []
    private(set) var statusReads = 0
    var holdDelivery = false
    private var delivery: CheckedContinuation<Void, Never>?
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []
    func permission() -> NotificationPermission {
        statusReads += 1
        return NotificationPermission(authorization: .authorized, banner: true, sound: true)
    }
    func requestAuthorization() throws -> Bool {
        if failAuthorization { throw ProviderFailure.unavailable("Fixture authorization failure") }
        return true
    }
    func deliver(_ notification: AppNotification) async throws {
        if holdDelivery {
            await withCheckedContinuation { continuation in
                delivery = continuation
                deliveryWaiters.forEach { $0.resume() }; deliveryWaiters = []
            }
        }
        if failDelivery { throw ProviderFailure.unavailable("Fixture delivery failure") }
        deliveries.append(notification)
    }
    func hold() { holdDelivery = true }
    func waitUntilDelivering() async {
        if delivery != nil { return }
        await withCheckedContinuation { deliveryWaiters.append($0) }
    }
    func finishDelivery() { holdDelivery = false; delivery?.resume(); delivery = nil }
    func setFailures(delivery: Bool = false, authorization: Bool = false) {
        failDelivery = delivery; failAuthorization = authorization
    }
}

/// Holds only the repository worker, never MainActor. Tests release it after observing UI work.
private final class WorkerGate {
    let entered = XCTestExpectation(description: "Storage worker reached gate")
    private let release = DispatchSemaphore(value: 0)
    init(_ worker: DispatchQueue) {
        worker.async { [self] in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
    }
    func open() { release.signal() }
}

private actor HeldUsage: UsageProvider {
    private var continuation: CheckedContinuation<AccountSnapshot, Never>?
    private var called: [CheckedContinuation<Void, Never>] = []
    func read(configuration: AccountConfiguration, includeHistory: Bool) async -> AccountSnapshot {
        let snapshot = await withCheckedContinuation { continuation in
            self.continuation = continuation
            called.forEach { $0.resume() }; called = []
        }
        return snapshot
    }
    func waitUntilCalled() async {
        if continuation != nil { return }
        await withCheckedContinuation { called.append($0) }
    }
    func finish(_ snapshot: AccountSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}

@MainActor
final class StorageIntegrationTests: XCTestCase {
    private func fixture(enabled: Bool = false) throws -> (URL, AccountConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-storage-integration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let account = AccountConfiguration(id: "fixture", provider: .codex, enabled: enabled, executablePath: "/fixture/never-run")
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        try db.write([account], key: "accounts")
        return (directory, account)
    }

    private func store(_ directory: URL, worker: DispatchQueue, notifications: NotificationFixture = NotificationFixture(),
                       registry: ProviderRegistry = ProviderRegistry()) -> AppStore {
        let persistence = AppPersistence(directory: directory, demo: false, credentials: IsolatedCredentials(), workerTarget: worker)
        return AppStore(directory: directory, credentials: IsolatedCredentials(), registry: registry, notifications: notifications, persistence: persistence)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate(), "Timed out waiting for operation", file: file, line: line)
        if !predicate() { throw ProviderFailure.timedOut }
    }

    private func execute(_ sql: String, at directory: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testStartupDoesNotBlockMainActorOrOverwriteAnEditSubmittedWhileLoading() async throws {
        let (directory, account) = try fixture()
        let worker = DispatchQueue(label: "fixture.bootstrap")
        let gate = WorkerGate(worker); defer { gate.open() }
        await fulfillment(of: [gate.entered], timeout: 2)
        let store = store(directory, worker: worker)
        XCTAssertTrue(store.isLoading)
        var edited = account; edited.label = "Submitted during startup"
        let save = Task { try await store.saveAccount(edited, secret: "") }
        // A separate MainActor turn completes while bootstrap is still waiting on real storage's worker.
        let heartbeat = Task { @MainActor in store.tick(at: store.now.addingTimeInterval(60)) }
        await heartbeat.value
        XCTAssertTrue(store.isLoading)
        XCTAssertTrue(store.accounts.isEmpty)
        gate.open()
        try await save.value
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.accounts, [edited])
        await store.shutDown()
        let restarted = storeForRestart(directory)
        await restarted.waitUntilReady()
        XCTAssertEqual(restarted.accounts, [edited])
        await restarted.shutDown()
    }

    private func storeForRestart(_ directory: URL) -> AppStore {
        AppStore(directory: directory, credentials: IsolatedCredentials(), notifications: NotificationFixture())
    }

    private var customSettings: MonitorSettings {
        var value = MonitorSettings()
        value.soundEnabled = false; value.notificationsEnabled = true
        value.threshold = 83; value.refreshSeconds = 600
        value.selectedTrayAccount = "synthetic-account"; value.selectedTrayWindow = "weekly"
        value.expiryHours = [36, 6]; value.quietStart = 21
        return value
    }

    func testStartupSnoozePreservesSavedFieldsAndDrainsOnImmediateShutdown() async throws {
        let (directory, _) = try fixture()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        var expected = customSettings
        try db.write(expected, key: "settings")
        let worker = DispatchQueue(label: "fixture.startup-snooze"), gate = WorkerGate(worker)
        defer { gate.open() }
        let store = store(directory, worker: worker)
        store.snooze()
        expected.snoozedUntil = try XCTUnwrap(store.settings.snoozedUntil)
        XCTAssertEqual(store.pendingStorageOperations, 1, "Snooze reserves its write before returning")
        let shutdown = Task { await store.shutDown() }
        gate.open(); await shutdown.value
        XCTAssertEqual(store.settings, expected)
        XCTAssertEqual(try db.read(MonitorSettings.self, key: "settings"), expected)
        let restarted = storeForRestart(directory)
        await restarted.waitUntilReady()
        XCTAssertEqual(restarted.settings, expected)
        await restarted.shutDown()
    }

    func testSeveralStartupBindingEditsPreserveUntouchedFieldsAndTheirOrder() async throws {
        let (directory, _) = try fixture()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        var expected = customSettings
        try db.write(expected, key: "settings")
        let worker = DispatchQueue(label: "fixture.startup-bindings"), gate = WorkerGate(worker)
        defer { gate.open() }
        let store = store(directory, worker: worker)
        // Explicitly selecting the provisional default must still override a different saved value.
        store.setting(\.soundEnabled).wrappedValue = true
        let first = Task { await store.persistSettings() }
        try await waitUntil { store.pendingStorageOperations == 1 }
        store.setting(\.threshold).wrappedValue = 65
        store.editSettings { $0.selectedTrayAccount = nil; $0.selectedTrayWindow = nil }
        let second = Task { await store.persistSettings() }
        try await waitUntil { store.pendingStorageOperations == 2 }
        gate.open(); await first.value; await second.value; await store.shutDown()
        expected.soundEnabled = true; expected.threshold = 65
        expected.selectedTrayAccount = nil; expected.selectedTrayWindow = nil
        XCTAssertEqual(store.settings, expected)
        XCTAssertEqual(try db.read(MonitorSettings.self, key: "settings"), expected)
    }

    func testFailedStartupSnoozeRestoresLoadedSettings() async throws {
        let (directory, _) = try fixture()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        let expected = customSettings
        try db.write(expected, key: "settings")
        try execute("CREATE TRIGGER reject_settings BEFORE INSERT ON preferences WHEN NEW.id = 'settings' BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: directory)
        let worker = DispatchQueue(label: "fixture.failed-startup-setting"), gate = WorkerGate(worker)
        defer { gate.open() }
        let store = store(directory, worker: worker)
        store.snooze()
        gate.open(); await store.shutDown()
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.settings, expected)
        XCTAssertEqual(try db.read(MonitorSettings.self, key: "settings"), expected)
    }

    func testRelativeStartupEditsAreAppliedOncePerSavedSnapshot() async throws {
        let (directory, _) = try fixture()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        var expected = customSettings
        try db.write(expected, key: "settings")
        let worker = DispatchQueue(label: "fixture.relative-startup-edits"), gate = WorkerGate(worker)
        defer { gate.open() }
        let store = store(directory, worker: worker)
        store.editSettings { $0.threshold += 1 }
        let first = Task { await store.persistSettings() }
        try await waitUntil { store.pendingStorageOperations == 1 }
        store.editSettings { $0.threshold += 2 }
        let second = Task { await store.persistSettings() }
        try await waitUntil { store.pendingStorageOperations == 2 }
        gate.open(); await first.value; await second.value; await store.shutDown()
        expected.threshold += 3
        XCTAssertEqual(store.settings, expected)
        XCTAssertEqual(try db.read(MonitorSettings.self, key: "settings"), expected)
    }

    func testRecoveryPublishesTheSameDefaultsUsedByTheNextAccountCommit() async throws {
        let (directory, account) = try fixture()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        for key in ["accounts", "settings", "manual-resets", "ssh-hosts", "activity-roots", "reset-redemptions"] {
            try db.write("incompatible", key: key)
        }
        try db.write(123, key: "opencode-path")
        let store = storeForRestart(directory)
        store.isPaused = true
        await store.waitUntilReady()
        XCTAssertTrue(store.hasRecoverableStorageError)
        await store.recoverStoredConfiguration()
        let recoveredAccounts = store.accounts
        XCTAssertEqual(recoveredAccounts.map(\.id), ["default-codex", "default-claude"])
        XCTAssertEqual(store.settings, MonitorSettings())
        XCTAssertTrue(store.manualResets.isEmpty); XCTAssertTrue(store.sshHosts.isEmpty)
        XCTAssertTrue(store.activityRoots.isEmpty); XCTAssertEqual(store.localDatabasePath, "")
        XCTAssertFalse(store.hasRecoverableStorageError)
        try await store.saveAccount(account, secret: "")
        XCTAssertEqual(store.accounts, recoveredAccounts + [account])
        XCTAssertTrue(store.manualResets.isEmpty)
        await store.shutDown()
        let restarted = storeForRestart(directory)
        await restarted.waitUntilReady()
        XCTAssertEqual(restarted.accounts, recoveredAccounts + [account])
        XCTAssertEqual(restarted.settings, store.settings)
        XCTAssertTrue(restarted.manualResets.isEmpty); XCTAssertTrue(restarted.sshHosts.isEmpty)
        XCTAssertTrue(restarted.activityRoots.isEmpty); XCTAssertEqual(restarted.localDatabasePath, "")
        await restarted.shutDown()
    }

    func testSettingsEditedDuringBootstrapSurvivePublicationAndRestart() async throws {
        let (directory, _) = try fixture()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        var persisted = MonitorSettings(); persisted.soundEnabled = false
        try db.write(persisted, key: "settings")
        let worker = DispatchQueue(label: "fixture.settings"), gate: WorkerGate
        gate = WorkerGate(worker); defer { gate.open() }
        let store = store(directory, worker: worker)
        store.setting(\.soundEnabled).wrappedValue = true
        let pending = Task { await store.persistSettings() }
        await Task.yield()
        gate.open(); await pending.value
        XCTAssertTrue(store.settings.soundEnabled)
        await store.shutDown()
        XCTAssertTrue(try XCTUnwrap(db.read(MonitorSettings.self, key: "settings")).soundEnabled)
    }

    func testBootstrapCannotOverwriteAnEditBeforeItsSaveTaskStarts() async throws {
        let (directory, _) = try fixture()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        var settings = MonitorSettings(); settings.soundEnabled = false
        try db.write(settings, key: "settings")
        let worker = DispatchQueue(label: "fixture.unscheduled-setting"), gate: WorkerGate
        gate = WorkerGate(worker); defer { gate.open() }
        let store = store(directory, worker: worker)
        store.setting(\.soundEnabled).wrappedValue = true
        // An observed binding can change before SwiftUI's onChange submits persistence.
        gate.open(); await store.waitUntilReady()
        XCTAssertTrue(store.settings.soundEnabled)
        await store.persistSettings(); await store.shutDown()
        XCTAssertTrue(try XCTUnwrap(db.read(MonitorSettings.self, key: "settings")).soundEnabled)
    }

    func testSlowCancelledAccountSaveStillCommitsBeforeRemovalAndShutdown() async throws {
        let (directory, account) = try fixture()
        let worker = DispatchQueue(label: "fixture.order")
        let store = store(directory, worker: worker)
        await store.waitUntilReady()
        let gate = WorkerGate(worker); defer { gate.open() }
        await fulfillment(of: [gate.entered], timeout: 2)
        var edited = account; edited.label = "Saved first"
        let save = Task { try await store.saveAccount(edited, secret: "") }
        // Wait for submission through the public operation, not a copy of its implementation.
        try await waitUntil { !(store.pendingStorageOperations == 0) }
        save.cancel()
        let removal = Task { await store.removeAccount(account) }
        try await waitUntil { !(store.pendingStorageOperations < 2) }
        let shutdown = Task { await store.shutDown() }
        await Task.yield()
        XCTAssertEqual(store.accounts, [account], "No partial publication before durable commit")
        XCTAssertGreaterThan(store.pendingStorageOperations, 0)
        gate.open()
        try await save.value; await removal.value; await shutdown.value
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(store.pendingStorageOperations, 0)
        let restarted = storeForRestart(directory)
        await restarted.waitUntilReady()
        XCTAssertTrue(restarted.accounts.isEmpty)
        await restarted.shutDown()
    }

    func testShutdownRejectsNewAccountWritesAfterDrainingAcceptedOperations() async throws {
        let (directory, account) = try fixture()
        let store = storeForRestart(directory)
        await store.waitUntilReady(); await store.shutDown()
        var edited = account; edited.label = "Too late"
        await XCTAssertThrowsErrorAsync(try await store.saveAccount(edited, secret: ""))
        XCTAssertEqual(store.accounts, [account])
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        XCTAssertEqual(try db.read([AccountConfiguration].self, key: "accounts"), [account])
    }

    func testConcurrentSavesRetainBothAccountsAndManualResets() async throws {
        let (directory, _) = try fixture()
        let worker = DispatchQueue(label: "fixture.multiple")
        let store = store(directory, worker: worker)
        await store.waitUntilReady()
        let gate = WorkerGate(worker); defer { gate.open() }
        let a = AccountConfiguration(id: "second", provider: .codex, enabled: false)
        let b = AccountConfiguration(id: "third", provider: .claude, enabled: false)
        let first = Task { try await store.saveAccount(a, secret: "") }
        try await waitUntil { !(store.pendingStorageOperations < 1) }
        let second = Task { try await store.saveAccount(b, secret: "") }
        let reset = Task { await store.addReset(accountID: a.id, title: "Fixture", scope: "Fixture", expiry: Date()) }
        try await waitUntil { !(store.pendingStorageOperations < 3) }
        gate.open(); try await first.value; try await second.value; await reset.value
        XCTAssertEqual(Set(store.accounts.map(\.id)), ["fixture", "second", "third"])
        XCTAssertEqual(store.manualResets.map(\.accountID), [a.id])
        await store.shutDown()
    }

    func testFailedSlowSaveKeepsDurableAndVisibleAccountAndAllowsNextEdit() async throws {
        let (directory, account) = try fixture()
        let worker = DispatchQueue(label: "fixture.failure")
        let store = store(directory, worker: worker)
        await store.waitUntilReady()
        try execute("CREATE TRIGGER reject_accounts BEFORE INSERT ON preferences WHEN NEW.id='accounts' BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: directory)
        let gate = WorkerGate(worker); defer { gate.open() }
        var edited = account; edited.label = "Edited"
        let save = Task { try await store.saveAccount(edited, secret: "") }
        try await waitUntil { !(store.pendingStorageOperations == 0) }
        XCTAssertEqual(store.accounts, [account])
        gate.open()
        await XCTAssertThrowsErrorAsync(try await save.value)
        XCTAssertEqual(store.accounts, [account])
        try execute("DROP TRIGGER reject_accounts", at: directory)
        try await store.saveAccount(edited, secret: "")
        await store.shutDown()
        let restarted = storeForRestart(directory); await restarted.waitUntilReady()
        XCTAssertEqual(restarted.accounts, [edited])
        await restarted.shutDown()
    }

    func testLateProviderCompletionCannotRecreateRemovedAccountOrPersistItsHistory() async throws {
        let (directory, account) = try fixture(enabled: true)
        let provider = HeldUsage(), notifications = NotificationFixture()
        let store = store(directory, worker: DispatchQueue(label: "fixture.stale"), notifications: notifications,
                          registry: ProviderRegistry(overrides: [.codex: provider]))
        await store.waitUntilReady()
        store.refresh(force: true)
        await provider.waitUntilCalled()
        await store.removeAccount(account)
        await provider.finish(AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture"))
        await store.shutDown()
        XCTAssertNil(store.snapshots[account.id])
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        XCTAssertTrue(try db.history(account: account.id).isEmpty)
        let deliveries = await notifications.deliveries
        XCTAssertTrue(deliveries.isEmpty)
    }

    func testCredentialChangeInvalidatesObservationAlreadyWaitingForStorage() async throws {
        let (directory, account) = try fixture(enabled: true)
        let provider = HeldUsage(), worker = DispatchQueue(label: "fixture.stale-commit")
        let store = store(directory, worker: worker, registry: ProviderRegistry(overrides: [.codex: provider]))
        await store.waitUntilReady()
        store.refresh(force: true); await provider.waitUntilCalled()
        let gate = WorkerGate(worker); defer { gate.open() }
        await fulfillment(of: [gate.entered], timeout: 2)
        await provider.finish(AccountSnapshot(configurationID: account.id, identity: "fixture-old-login", source: "fixture"))
        try await waitUntil { store.pendingStorageOperations == 1 }
        var edited = account; edited.profileDirectory = "/fixture/new-profile"
        let save = Task { try await store.saveAccount(edited, secret: "fixture-new-secret") }
        try await waitUntil { store.pendingStorageOperations == 2 }
        store.isPaused = true
        gate.open(); try await save.value; await store.shutDown()
        XCTAssertEqual(store.accounts, [edited])
        XCTAssertNil(store.snapshots[account.id])
        XCTAssertTrue(store.history[account.id]?.isEmpty == true)
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        XCTAssertTrue(try db.history(account: account.id).isEmpty)
    }

    func testNotificationFailureIsInjectableAndDoesNotMarkUndeliveredWarningsAsSent() async throws {
        let (directory, account) = try fixture(enabled: true)
        let provider = HeldUsage(), notifications = NotificationFixture()
        let store = store(directory, worker: DispatchQueue(label: "fixture.notification"), notifications: notifications,
                          registry: ProviderRegistry(overrides: [.codex: provider]))
        await store.waitUntilReady()
        store.editSettings { $0.notificationsEnabled = true; $0.quietEnabled = false }
        await store.persistSettings()
        await notifications.setFailures(delivery: true)
        store.refresh(force: true); await provider.waitUntilCalled()
        await provider.finish(AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture",
            windows: [.init(id: "primary", title: "5h", usedPercent: 95, resetsAt: Date().addingTimeInterval(3600), duration: 18000)]))
        try await waitUntil { !store.isRefreshing }
        XCTAssertTrue(store.warnings.isEmpty)
        XCTAssertTrue(store.storageError?.contains("Fixture delivery failure") == true)
        await notifications.setFailures()
        store.refresh(force: true)
        // Manual checks retry the existing observation while the next provider call is held.
        await provider.waitUntilCalled()
        try await waitUntil { !store.warnings.isEmpty }
        XCTAssertFalse(store.warnings.isEmpty)
        await provider.finish(AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture"))
        await store.shutDown()
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        XCTAssertEqual(Set(try db.warnings().map(\.id)), Set(store.warnings.map(\.id)))
    }

    func testNotificationLifecycleAndExplicitFailuresNeverNeedTheSystemCenter() async throws {
        let (directory, _) = try fixture()
        let notifications = NotificationFixture()
        let store = store(directory, worker: DispatchQueue(label: "fixture.permission"), notifications: notifications)
        await store.waitUntilReady()
        store.isPaused = true; store.start()
        await store.updateNotificationStatus()
        XCTAssertEqual(store.notificationStatus, tr("Banner: {0} · macOS-Ton: {1}", tr("an"), tr("an")))
        await notifications.setFailures(authorization: true)
        await store.enableNotifications()
        XCTAssertTrue(store.notificationStatus.contains("Fixture authorization failure"))
        await notifications.setFailures(delivery: true)
        await store.testNotification()
        XCTAssertTrue(store.notificationStatus.contains("Fixture delivery failure"))
        await store.shutDown()
    }

    func testCoordinatedCredentialWriteWaitsOffMainActorAndPublishesDespiteCancellation() async throws {
        let (directory, account) = try fixture()
        let credentials = DelayedCredentials()
        let store = AppStore(directory: directory, credentials: credentials, notifications: NotificationFixture())
        await store.waitUntilReady()
        var edited = account; edited.label = "Durably saved"
        let save = Task { try await store.saveAccount(edited, secret: "fixture-secret") }
        await fulfillment(of: [credentials.started], timeout: 2)
        let now = store.now
        store.tick(at: now.addingTimeInterval(60))
        XCTAssertNotEqual(store.now, now)
        XCTAssertEqual(store.accounts, [account])
        save.cancel()
        let shutdown = Task { await store.shutDown() }
        await Task.yield()
        credentials.release.signal()
        try await save.value; await shutdown.value
        XCTAssertEqual(store.accounts, [edited])
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        XCTAssertEqual(try db.read([AccountConfiguration].self, key: "accounts"), [edited])
    }

    func testDeliveredNotificationIsRecordedAfterRefreshCancellationAndShutdown() async throws {
        let (directory, account) = try fixture(enabled: true)
        let provider = HeldUsage(), notifications = NotificationFixture()
        await notifications.hold()
        let store = store(directory, worker: DispatchQueue(label: "fixture.delivered"), notifications: notifications,
                          registry: ProviderRegistry(overrides: [.codex: provider]))
        await store.waitUntilReady()
        store.editSettings { $0.notificationsEnabled = true; $0.quietEnabled = false }; await store.persistSettings()
        store.refresh(force: true); await provider.waitUntilCalled()
        await provider.finish(AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture",
            windows: [.init(id: "primary", title: "5h", usedPercent: 95, resetsAt: Date().addingTimeInterval(3600), duration: 18000)]))
        await notifications.waitUntilDelivering()
        let shutdown = Task { await store.shutDown() }
        await Task.yield()
        await notifications.finishDelivery()
        await shutdown.value
        XCTAssertFalse(store.warnings.isEmpty)
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        XCTAssertEqual(Set(try db.warnings().map(\.id)), Set(store.warnings.map(\.id)))
    }

    func testShutdownFinishesAnAcceptedResetEvenWhenItsUIActionWasCancelled() async throws {
        let (directory, account) = try fixture(enabled: true)
        let benefit = ResetBenefit(id: "fixture-credit", title: "Fixture", scope: "Codex")
        let snapshot = AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture",
            windows: [.init(id: "primary", title: "5h", usedPercent: 90, duration: 18000)], benefits: [benefit])
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        try db.save(snapshot)
        let redeemer = ResetFake(hold: true, includesFreshLimits: false)
        let store = AppStore(directory: directory, resetRedeemer: redeemer, credentials: IsolatedCredentials(), notifications: NotificationFixture())
        await store.waitUntilReady()
        let reset = Task { try await store.redeemReset(benefit, for: account, expectedIdentity: snapshot.identity) }
        await redeemer.waitUntilCalled()
        reset.cancel()
        let shutdown = Task { await store.shutDown() }
        await Task.yield()
        await redeemer.finish()
        _ = try await reset.value; await shutdown.value
        XCTAssertTrue(store.resetAccountsAwaitingRefresh.contains(account.id))
        XCTAssertFalse(store.canRedeemReset(benefit, for: account))
        XCTAssertEqual(try db.read([String: String].self, key: "reset-redemptions"), [:])
    }

    func testLargeHistoryDecodingLeavesMainActorAvailable() async throws {
        let (directory, account) = try fixture()
        // Populate 10,000 genuine SQLite rows without running retention while seeding.
        var snapshot = AccountSnapshot(configurationID: account.id, identity: "fixture-login", source: "fixture",
            windows: (0..<20).map { .init(id: "window-\($0)", title: "Fixture", usedPercent: Double($0), duration: 604800) })
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &db), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_exec(db, "BEGIN", nil, nil, nil), SQLITE_OK)
        var insert: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO observations(account,time,payload) VALUES('fixture',?,?)", -1, &insert, nil), SQLITE_OK)
        for index in 0..<10_000 {
            snapshot.observedAt = Date().addingTimeInterval(Double(index - 10_000) * 30)
            snapshot.windows[0].usedPercent = Double(index % 100)
            let data = try JSONEncoder().encode(snapshot)
            sqlite3_bind_double(insert, 1, snapshot.observedAt.timeIntervalSince1970)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32(data.count), transient) }
            XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE); sqlite3_reset(insert)
        }
        sqlite3_finalize(insert); sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close(db)
        let synchronousDB = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        let clock = ContinuousClock(), before = ContinuousClock.now
        XCTAssertEqual(try synchronousDB.history(account: account.id, limit: 10_000).count, 10_000)
        let blocked = before.duration(to: clock.now)
        let initialized = clock.now
        let store = storeForRestart(directory)
        let initTime = initialized.duration(to: clock.now)
        var heartbeats = 0
        while store.isLoading { heartbeats += 1; await Task.yield() }
        XCTAssertEqual(store.history[account.id]?.count, 10_000)
        XCTAssertGreaterThan(heartbeats, 0)
        XCTAssertLessThan(initTime, blocked)
        print("Synthetic 10k × 20-window history: synchronous decode blocked MainActor for \(blocked); async initialization \(initTime), \(heartbeats) MainActor turns during bootstrap")
        await store.shutDown()
    }
}
