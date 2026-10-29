import SwiftUI
import AppKit
import Observation
import ServiceManagement
import JuicebarCore

struct ManualReset: Codable, Identifiable, Sendable {
    var id: String { benefit.id }
    var accountID: String
    var benefit: ResetBenefit
}

@MainActor @Observable
final class AppStore {
    static let shared = AppStore(demo: CommandLine.arguments.contains("--demo"))
    var accounts: [AccountConfiguration] = []
    private(set) var settings = MonitorSettings()
    var snapshots: [String: AccountSnapshot] = [:]
    var failures: [String: String] = [:]
    var refreshingAccountIDs: Set<String> = []
    var isRefreshing: Bool { !refreshingAccountIDs.isEmpty }
    var isPaused = false { didSet { if isPaused { scheduler.cancelAll(); cancelActivityImport() } else { refreshActivityIfNeeded() } } }
    var lastChecked: Date?
    var now = Date()
    var history: [String: [AccountSnapshot]] = [:] { didSet { quotaHistoryCache = [:] } }
    var warnings: [WarningEvent] = []
    var manualResets: [ManualReset] = []
    var redeemingResetAccounts: Set<String> = []
    var resetAccountsAwaitingRefresh: Set<String> = []
    @ObservationIgnored private let resetRedeemer: any CodexResetRedeeming
    @ObservationIgnored private var resetRedemptionKeys: [String: String] = [:]
    var localUsage: LocalUsageReport?
    var localUsageError: String?
    var localUsageLoading = false
    var activity: ActivityReport?
    var sshHosts: [String] = []
    var activityRoots: [ActivityLogs.Root] = []
    var activityProgress = ""
    @ObservationIgnored private var nextActivityImport = Date.distantPast
    private let storageDirectory: URL
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var activityWorker: Task<Void, Error>?
    @ObservationIgnored private var activityControl: ActivityImport.Control?
    @ObservationIgnored private let activityReader: ActivityImport.Reader
    @ObservationIgnored private var activityImportID: UUID?
    @ObservationIgnored private let activityCatalogRefresh: @Sendable () async -> Void
    var storageError: String?
    var hasRecoverableStorageError = false
    var notificationStatus = tr("Nicht aktiviert")
    var localDatabasePath = ""
    let isDemo: Bool
    @ObservationIgnored private let persistence: AppPersistence
    @ObservationIgnored private let notifications: any AppNotifications
    var isLoading = true
    var pendingStorageOperations = 0
    @ObservationIgnored private var bootstrapTask: Task<MonitorSettings, Never>?
    @ObservationIgnored private var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var settingsRevision = 0
    @ObservationIgnored private var startupSettingsEdits: [(inout MonitorSettings) -> Void] = []
    @ObservationIgnored private var resetTasks: [UUID: Task<CodexResetResult, Error>] = [:]
    @ObservationIgnored private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var durableSettings = MonitorSettings()
    @ObservationIgnored private var credentialRecovery: Set<String> = []
    @ObservationIgnored private var pendingAccountMutations: [String: Int] = [:]
    private let registry: ProviderRegistry
    @ObservationIgnored private var refreshPolicy = AccountRefreshPolicy()
    private let scheduler = AccountRefreshScheduler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingWarningIDs: Set<String> = []
    @ObservationIgnored private var quotaHistoryCache: [String: [AccountSnapshot]] = [:]

    init(demo: Bool = false, directory: URL? = nil, resetRedeemer: (any CodexResetRedeeming)? = nil, credentials: any CredentialStore = KeychainCredentialStore(), registry: ProviderRegistry = ProviderRegistry(), notifications: any AppNotifications = SystemAppNotifications(), persistence: AppPersistence? = nil, activityReader: @escaping ActivityImport.Reader = { try await ActivityImport.readProgressively($0, control: $1, publish: $2) }, activityCatalogRefresh: @escaping @Sendable () async -> Void = { await AppStore.refreshCatalog() }) {
        self.activityReader = activityReader; self.activityCatalogRefresh = activityCatalogRefresh
        self.registry = registry; self.notifications = notifications
        isDemo = demo
        if let resetRedeemer { self.resetRedeemer = resetRedeemer }
        else if demo { self.resetRedeemer = DemoCodexResetCredits() }
        else { self.resetRedeemer = CodexResetCredits() }
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Juicebar", isDirectory: true)
        storageDirectory = directory
        self.persistence = persistence ?? AppPersistence(directory: directory, demo: demo, credentials: credentials)
        scheduler.onChange = { [weak self] ids in
            guard let self else { return }
            if self.refreshingAccountIDs != ids { self.refreshingAccountIDs = ids }
        }
        if demo {
            accounts = DemoData.accounts; isLoading = false
            for snapshot in DemoData.snapshots(now: now) {
                snapshots[snapshot.configurationID] = snapshot
                history[snapshot.configurationID] = DemoData.history(for: snapshot, now: now)
            }
            lastChecked = now
            activity = DemoData.activity(now: now)
        }
        bootstrapTask = Task { [self] in
            let loaded = await self.persistence.bootstrap()
            // Edits submitted during startup wait for this publication. No defaults are written.
            if !isDemo {
                accounts = loaded.configuration.accounts
                settings = loaded.configuration.settings
                for edit in startupSettingsEdits { edit(&settings) }
                startupSettingsEdits = []
                durableSettings = loaded.configuration.settings
                manualResets = loaded.configuration.manualResets
                resetRedemptionKeys = loaded.configuration.resetRedemptionKeys
                localDatabasePath = loaded.configuration.localDatabasePath
                sshHosts = loaded.configuration.sshHosts; activityRoots = loaded.configuration.activityRoots
                history = loaded.history; snapshots = loaded.snapshots; warnings = loaded.warnings
                activity = loaded.activity; localUsage = loaded.localUsage
                storageError = loaded.error; hasRecoverableStorageError = loaded.hasUnreadablePreferences
            }
            isLoading = false
            if timer != nil, !isShuttingDown { refresh(); refreshActivityIfNeeded() }
            return loaded.configuration.settings
        }
    }

    func waitUntilReady() async { _ = await bootstrapTask?.value }

    /// Reserve a place before suspending. UI cancellation never cancels an accepted commit or
    /// its publication. All configuration read/modify/write operations use this lane.
    private func mutate<T>(finishingAcceptedAction: Bool = false, _ action: @escaping @MainActor () async throws -> T) async throws -> T {
        try await enqueueMutation(finishingAcceptedAction: finishingAcceptedAction, action).value
    }

    private func enqueueMutation<T>(finishingAcceptedAction: Bool = false, _ action: @escaping @MainActor () async throws -> T) throws -> Task<T, Error> {
        guard !isShuttingDown || finishingAcceptedAction else { throw CancellationError() }
        let previous = mutationTail
        pendingStorageOperations += 1
        let operation = Task { @MainActor [self] in
            await previous?.value
            await waitUntilReady()
            defer { pendingStorageOperations -= 1 }
            return try await action()
        }
        mutationTail = Task { _ = try? await operation.value }
        return operation
    }

    func start() {
        guard !isShuttingDown, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.tick()
                if !self.isPaused { self.refresh(); self.refreshActivityIfNeeded() }
            }
        }
        timer?.tolerance = 10
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduler.cancelAll(); self?.cancelActivityImport() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                if self?.isPaused == false { self?.refresh(force: true); self?.refreshActivityIfNeeded() }
            }
        })
        refresh()
        refreshActivityIfNeeded()
        trackNotification { [self] in await updateNotificationStatus() }
    }

    /// Views show minutes at most, so a new `now` within the same minute would only redraw them.
    func tick(at date: Date = Date()) {
        if Int(date.timeIntervalSinceReferenceDate / 60) != Int(now.timeIntervalSinceReferenceDate / 60) { now = date }
    }

    func stop() {
        timer?.invalidate(); timer = nil; scheduler.cancelAll(); cancelActivityImport()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
    func shutDown() async {
        isShuttingDown = true
        stop()
        await waitUntilReady()
        await scheduler.waitUntilIdle()
        await activityTask?.value
        for task in resetTasks.values { _ = try? await task.value }
        for task in notificationTasks.values { await task.value }
        await mutationTail?.value
        await persistence.drain()
    }

    func refresh(force: Bool = false, only accountID: String? = nil) {
        guard !isLoading, !isShuttingDown, !isDemo, !isPaused else { return }
        let selected = accounts.filter { $0.enabled && pendingAccountMutations[$0.id, default: 0] == 0 && !credentialRecovery.contains($0.id) && !redeemingResetAccounts.contains($0.id) && (accountID == nil || $0.id == accountID) }
        let schedulingNow = Date()
        refreshPolicy.clamp(now: schedulingNow)
        refreshPolicy.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        for account in selected {
            guard refreshPolicy.isDue(id: account.id, force: force, now: schedulingNow) else { continue }
            scheduler.enqueue(id: account.id, replacingPending: force) { [self] generation in
                guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(account) else { return }
                let now = Date()
                guard refreshPolicy.isDue(id: account.id, force: force, now: now) else { return }
                let includeUsage = refreshPolicy.includesHistory(id: account.id, now: now)
                do {
                    var snapshot = try await registry.provider(for: account.provider).read(configuration: account, includeHistory: includeUsage)
                    guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(where: { $0 == account }) else { return }
                    try await mutate { [self] in
                        guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(account) else { return }
                        let identity = AccountIdentity.reconcile(snapshot, previous: snapshots[account.id], configuration: account)
                        snapshot = QuotaPeriod.normalizing(identity.snapshot, previous: snapshots[account.id])
                        // Each row keeps its login identity. Charts separate their series and
                        // forecasts filter by identity, so a fallback key need not erase old history.
                        if snapshot.dailyUsage.isEmpty, let previous = snapshots[account.id], previous.identity == snapshot.identity {
                            snapshot.dailyUsage = previous.dailyUsage
                        }
                        do { try await persistence.saveObservation(snapshot) } catch { storageError = error.localizedDescription }
                        guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(account) else { return }
                        snapshots[account.id] = snapshot; failures[account.id] = nil
                        resetAccountsAwaitingRefresh.remove(account.id)
                        let previous = history[account.id]?.last
                        history[account.id] = HistoryRetention.appending(snapshot, to: history[account.id] ?? [])
                        refreshPolicy.succeeded(account: account, refreshSeconds: settings.refreshSeconds, includedHistory: includeUsage,
                                                unchanged: !force && AccountRefreshPolicy.quotaUnchanged(from: previous, to: snapshot), now: Date())
                    }
                    guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(account) else { return }
                    await notify(account: account, snapshot: withManualResets(snapshot), generation: generation)
                } catch is CancellationError { return }
                catch {
                    guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(where: { $0 == account }) else { return }
                    failures[account.id] = error.localizedDescription
                    refreshPolicy.failed(id: account.id, error: error, refreshSeconds: settings.refreshSeconds, now: Date())
                }
                lastChecked = Date()
            }
        }
        let manualChecks = selected.map { ($0, scheduler.generation(for: $0.id)) }
        trackNotification { [self] in
            for (account, generation) in manualChecks {
                guard scheduler.isCurrent(id: account.id, generation: generation), !isPaused, accounts.contains(account) else { continue }
                let snapshot = snapshots[account.id] ?? AccountSnapshot(configurationID: account.id, identity: account.id, observedAt: .distantPast, source: tr("Manuell"))
                await notify(account: account, snapshot: withManualResets(snapshot), generation: generation)
            }
        }
    }

    @discardableResult
    private func trackNotification(_ action: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [self] in
            await action()
            notificationTasks[id] = nil
        }
        notificationTasks[id] = task
        return task
    }

    func withManualResets(_ snapshot: AccountSnapshot) -> AccountSnapshot {
        var value = snapshot
        value.benefits += manualResets.filter { $0.accountID == snapshot.configurationID }.map(\.benefit)
        return value
    }

    private func notify(account: AccountConfiguration, snapshot: AccountSnapshot, generation: UUID) async {
        guard settings.notificationsEnabled, !settings.isQuiet(at: Date()), !isDemo else { return }
        var snapshot = snapshot
        snapshot.windows = QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)
        let events = WarningEngine.events(snapshot: snapshot, accountName: account.displayName, history: history[account.id] ?? [],
                                          settings: settings, sent: Set(warnings.map(\.id)).union(pendingWarningIDs))
        guard !events.isEmpty else { return }
        let eventIDs = Set(events.map(\.id))
        pendingWarningIDs.formUnion(eventIDs)
        defer { pendingWarningIDs.subtract(eventIDs) }
        let notification = AppNotification(id: events[0].id, title: account.displayName,
                                           body: events.map(\.message).joined(separator: "\n"),
                                           sound: settings.soundEnabled, accountID: account.id)
        do {
            let permission = await notifications.permission()
            guard scheduler.isCurrent(id: account.id, generation: generation), !isPaused, accounts.contains(account) else { return }
            guard permission.allowsDelivery else { return }
            try await notifications.deliver(notification)
        } catch {
            guard scheduler.isCurrent(id: account.id, generation: generation), !isPaused, accounts.contains(account) else { return }
            storageError = tr("Warnung konnte nicht gespeichert oder zugestellt werden. {0}", error.localizedDescription)
            return
        }
        // Delivered even if the Mac slept or the account changed meanwhile, so it must count as sent.
        await recordDelivered(events)
    }

    func recordDelivered(_ events: [WarningEvent]) async {
        await waitUntilReady()
        // Delivery already happened. Keep deduplication even if persistence fails or shutdown began.
        warnings.insert(contentsOf: events.reversed(), at: 0)
        do { try await persistence.recordDelivered(events) }
        catch { storageError = tr("Warnung konnte nicht gespeichert oder zugestellt werden. {0}", error.localizedDescription) }
    }

    func enableNotifications() async {
        guard !isDemo, !isShuttingDown else { return }
        await trackNotification { [self] in
            do {
                let allowed = try await notifications.requestAuthorization()
                editSettings { $0.notificationsEnabled = allowed }
                await persistSettings(finishingAcceptedAction: true)
                await updateNotificationStatus()
                if allowed { refresh(force: true) }
            } catch { notificationStatus = error.localizedDescription }
        }.value
    }
    func updateNotificationStatus() async {
        guard !isDemo else { notificationStatus = tr("Im Demo-Modus deaktiviert"); return }
        let status = await notifications.permission()
        switch status.authorization {
        case .authorized:
            let banner = status.banner
            notificationStatus = tr("Banner: {0} · macOS-Ton: {1}", banner ? tr("an") : tr("aus"), status.sound ? tr("an") : tr("aus"))
        case .provisional: notificationStatus = tr("Nur stille Zustellung erlaubt · Banner in macOS aktivieren")
        case .denied: notificationStatus = tr("In den macOS-Systemeinstellungen gesperrt")
        case .undetermined: notificationStatus = tr("Noch nicht freigegeben")
        }
    }
    func testNotification() async {
        guard !isDemo, !isShuttingDown else { return }
        await trackNotification { [self] in
            await updateNotificationStatus()
            let notification = AppNotification(id: UUID().uuidString, title: tr("Juicebars ist bereit"),
                body: settings.soundEnabled ? tr("Test für Banner und Hinweiston.") : tr("Test für Banner. Der Hinweiston ist in Juicebars ausgeschaltet."),
                sound: settings.soundEnabled)
            do { try await notifications.deliver(notification) }
            catch { notificationStatus = error.localizedDescription }
        }.value
    }
    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    func recoverStoredConfiguration() async {
        do { try await mutate { [self] in
            let recovered = try await persistence.recoverConfiguration()
            if let accounts = recovered.accounts {
                scheduler.cancelAll()
                self.accounts = accounts
                snapshots = [:]; history = [:]; failures = [:]
                refreshPolicy = AccountRefreshPolicy()
            }
            for change in recovered.changes {
                switch change {
                case let .settings(value): settings = value; durableSettings = value
                case let .manualResets(value): manualResets = value
                case let .localDatabasePath(value): localDatabasePath = value
                case let .sshHosts(value): sshHosts = value
                case let .activityRoots(value): activityRoots = value
                case let .resetRedemptions(value): resetRedemptionKeys = value
                }
            }
            hasRecoverableStorageError = false
            storageError = tr("Zurückgesetzt: {0}. Die Originaldaten bleiben gesichert.", recovered.keys.sorted().joined(separator: ", "))
        } } catch { storageError = error.localizedDescription }
    }

    /// Record the user's operation, including an explicit choice equal to the provisional default.
    /// During bootstrap it is replayed against loaded settings, preserving untouched fields.
    func editSettings(_ edit: @escaping (inout MonitorSettings) -> Void) {
        if isLoading { startupSettingsEdits.append(edit) }
        edit(&settings)
        settingsRevision += 1
    }

    func setting<Value>(_ keyPath: WritableKeyPath<MonitorSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in
            self.editSettings { $0[keyPath: keyPath] = value }
        })
    }

    func persistSettings() async { await persistSettings(finishingAcceptedAction: false) }

    private func persistSettings(finishingAcceptedAction: Bool) async {
        if let pending = enqueueSettingsSave(finishingAcceptedAction: finishingAcceptedAction) { _ = try? await pending.value }
    }

    @discardableResult
    private func enqueueSettingsSave(finishingAcceptedAction: Bool = false) -> Task<Void, Error>? {
        let value = settings
        let startupEdits = isLoading ? startupSettingsEdits : nil
        settingsRevision += 1
        let revision = settingsRevision
        do { return try enqueueMutation(finishingAcceptedAction: finishingAcceptedAction) { [self] in
            var updated = value
            if let startupEdits, let loaded = await bootstrapTask?.value {
                // These edits are cumulative snapshots. Rebase each on the original load,
                // not on an earlier write that may already contain the same relative edit.
                updated = loaded
                for edit in startupEdits { edit(&updated) }
            }
            do { try await persistence.writeConfiguration(.settings(updated)); durableSettings = updated }
            catch {
                if revision == settingsRevision { settings = durableSettings }
                storageError = error.localizedDescription
            }
        } } catch { storageError = error.localizedDescription; return nil }
    }
    private func invalidateAccount(_ id: String) {
        scheduler.invalidate(id: id)
        failures[id] = nil
        // A confirmed reset still needs a fresh observation after editing/restoring credentials.
        refreshPolicy.remove(id: id)
    }
    /// Key presence uses attributes only. Editing an account never loads its saved secret.
    func hasSavedKey(for account: AccountConfiguration) async -> Bool {
        await waitUntilReady()
        guard !isDemo, accounts.contains(where: { $0.id == account.id }) else { return false }
        return await persistence.hasSavedKey(account.id)
    }

    private func commitAccount(_ mutation: AccountMutation, id: String) async throws {
        // Invalidate before suspension as well as at publication. A late provider response
        // cannot write a measurement using credentials that are being replaced.
        pendingAccountMutations[id, default: 0] += 1
        var committed = false
        defer {
            pendingAccountMutations[id, default: 0] -= 1
            if committed { refresh(force: true, only: id) }
        }
        scheduler.invalidate(id: id)
        try await mutate { [self] in
            scheduler.invalidate(id: id)
            do {
                let commit = try await persistence.commitAccount(mutation)
                let recovered = credentialRecovery.remove(id) != nil
                if recovered, storageError == CredentialRecoveryFailure().localizedDescription { storageError = nil }
                invalidateAccount(id)
                accounts = commit.accounts; manualResets = commit.manualResets
                if commit.clearedHistory { snapshots[id] = nil; history[id] = [] }
                if !accounts.contains(where: { $0.id == id }) {
                    resetAccountsAwaitingRefresh.remove(id); snapshots[id] = nil; history[id] = nil
                }
            } catch {
                if error is CredentialRecoveryFailure {
                    credentialRecovery.insert(id); failures[id] = error.localizedDescription; storageError = error.localizedDescription
                }
                throw error
            }
        }
        committed = true
    }

    func saveAccount(_ account: AccountConfiguration, secret: String, removeSavedKey: Bool = false) async throws {
        try await commitAccount(.save(account, secret: secret, removeSavedKey: removeSavedKey), id: account.id)
    }

    func removeAccount(_ account: AccountConfiguration) async {
        do { try await commitAccount(.remove(account.id), id: account.id) }
        catch { storageError = error.localizedDescription }
    }

    /// Removes only the Juicebars override. The account and its history remain available.
    func removeSavedKey(for account: AccountConfiguration) async throws {
        try await commitAccount(.removeSavedKey(account.id), id: account.id)
    }

    func addReset(accountID: String, title: String, scope: String, expiry: Date) async {
        let reset = ManualReset(accountID: accountID, benefit: ResetBenefit(id: UUID().uuidString, title: title, scope: scope, expiresAt: expiry, isManual: true))
        do { try await mutate { [self] in
            let resets = manualResets + [reset]
            try await persistence.writeConfiguration(.manualResets(resets)); manualResets = resets
        } } catch { storageError = error.localizedDescription }
    }
    func removeReset(_ id: String) async {
        do { try await mutate { [self] in
            let resets = manualResets.filter { $0.id != id }
            try await persistence.writeConfiguration(.manualResets(resets)); manualResets = resets
        } } catch { storageError = error.localizedDescription }
    }
    func openAccount(_ account: AccountConfiguration) { NSWorkspace.shared.open(account.provider.accountURL) }
    func snooze() {
        let until = Date().addingTimeInterval(3600)
        editSettings { $0.snoozedUntil = until }
        enqueueSettingsSave()
    }
    func refreshActivityIfNeeded() {
        nextActivityImport = min(nextActivityImport, Date().addingTimeInterval(300))
        guard !isLoading, !isShuttingDown, !isPaused, Date() >= nextActivityImport else { return }
        loadLocalUsage(refreshRemote: false)
    }
    func loadLocalUsage(refreshRemote: Bool = true) {
        guard !isLoading, !isShuttingDown, !isPaused, !localUsageLoading, !isDemo else { return }
        nextActivityImport = Date().addingTimeInterval(300)
        localUsageLoading = true; activityProgress = tr("Nutzungsdaten werden aktualisiert …")
        let importID = UUID()
        activityImportID = importID
        let path = localDatabasePath.isEmpty ? nil : localDatabasePath
        let roots = ActivityLogs.defaultRoots(accounts: accounts, additional: activityRoots)
        let request = ActivityImport.Request(roots: roots, databasePath: path, hosts: sshHosts, directory: storageDirectory, refreshRemote: refreshRemote)
        let control = ActivityImport.Control(), reader = activityReader
        activityControl = control
        let worker = Task.detached(priority: .utility) { [self] in
            // Catalog network latency never holds local publication. Accepted prices apply on the next import.
            async let catalog: Void = activityCatalogRefresh()
            try await reader(request, control) { [self] report, local in
                await publishActivity(report, local: local, importID: importID, control: control)
            }
            _ = await catalog
        }
        activityWorker = worker
        activityTask = Task {
            defer {
                localUsageLoading = false; activityWorker = nil; activityControl = nil; activityImportID = nil
                activityProgress = ""; nextActivityImport = Date().addingTimeInterval(300)
            }
            do { try await worker.value }
            catch is CancellationError { }
            catch { if activityImportID == importID { localUsageError = error.localizedDescription } }
        }
    }
    nonisolated private static func refreshCatalog() async {
        if UserDefaults.standard.object(forKey: "catalogUpdates") as? Bool ?? true { _ = await ModelCatalog.shared.refreshIfNeeded() }
    }
    private func publishActivity(_ report: ActivityReport, local: LocalUsageReport?, importID: UUID, control: ActivityImport.Control) async {
        guard activityImportID == importID, !isShuttingDown, !isPaused else { return }
        do { try control.check() } catch { return }
        activity = report; localUsage = local; localUsageError = nil
        activityProgress = report.sources?.contains { $0.phase == .checking } == true
            ? tr("Lokale Daten verfügbar · SSH-Quellen werden geprüft …") : tr("Nutzungsdaten verfügbar.")
        await persistence.cacheImport(report, localUsage: local, control: control)
    }

    func addSSHHost(_ host: String) async throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHActivity.isValidHost(host) else { throw ProviderFailure.invalidData(tr("Bitte einen SSH-Alias wie workstation oder user@host eingeben.")) }
        try await mutate { [self] in
            guard !sshHosts.contains(host) else { return }
            let hosts = sshHosts + [host]
            try await persistence.writeConfiguration(.sshHosts(hosts))
            sshHosts = hosts; reloadActivitySources()
        }
    }
    func removeSSHHost(_ host: String) async {
        do { try await mutate { [self] in
            let hosts = sshHosts.filter { $0 != host }
            try await persistence.writeConfiguration(.sshHosts(hosts)); sshHosts = hosts; reloadActivitySources()
        } } catch { storageError = error.localizedDescription }
    }
    private func reloadActivitySources() {
        cancelActivityImport()
        let previous = activityTask
        Task { await previous?.value; loadLocalUsage() }
    }
    func cancelActivityImport() {
        activityImportID = nil; activityControl?.cancel(); activityWorker?.cancel(); activityTask?.cancel()
        activity?.markCached()
    }
    func selectActivityDirectory(format: ActivitySource) {
        guard !isDemo, ActivitySource.logFormats.contains(format) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = format == .kilo ? tr("Ordner mit Kilo-Datenbanken auswählen.") : tr("Ordner mit {0}-Logs auswählen. Unterordner werden mitgelesen.", format.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = ActivityLogs.Root(source: format, url: url.standardizedFileURL.resolvingSymlinksInPath())
        guard !activityRoots.contains(where: { $0.url == root.url }) else { return }
        saveActivityRoots { current in current.contains(where: { $0.url == root.url }) ? current : current + [root] }
    }
    func removeActivityRoot(_ root: ActivityLogs.Root) {
        guard !isDemo else { return }
        saveActivityRoots { $0.filter { $0.id != root.id } }
    }
    private func saveActivityRoots(_ updated: @escaping ([ActivityLogs.Root]) -> [ActivityLogs.Root]) {
        Task {
            do { try await mutate { [self] in
                let roots = updated(activityRoots)
                try await persistence.writeConfiguration(.activityRoots(roots))
                activityRoots = roots; reloadActivitySources()
            } } catch { storageError = error.localizedDescription }
        }
    }
    func selectLocalDatabase() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = tr("OpenCode-Datenbank nur lesend öffnen")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { try await mutate { [self] in
                    try await persistence.writeConfiguration(.localDatabasePath(url.path))
                    localDatabasePath = url.path; reloadActivitySources()
                } } catch { storageError = error.localizedDescription }
            }
        }
    }
    /// Period-normalized history, rebuilt only after `history` changes.
    func quotaHistory(for id: String) -> [AccountSnapshot] {
        let raw = history[id] ?? []
        if let cached = quotaHistoryCache[id] { return cached }
        var previous: AccountSnapshot?
        let value = raw.sorted { $0.observedAt < $1.observedAt }.map { raw in
            let snapshot = QuotaPeriod.normalizing(raw, previous: previous)
            previous = snapshot
            return snapshot
        }
        quotaHistoryCache[id] = value
        return value
    }
    /// Weekly reach for the account's visible windows; empty after a failed refresh.
    func weeklyReach(for account: AccountConfiguration) -> [WeeklyReach] {
        guard account.workSchedule?.isEnabled != true, failures[account.id] == nil, var snapshot = snapshots[account.id] else { return [] }
        snapshot.windows = QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)
        let source: ActivitySource? = account.provider == .claude ? .claude : account.provider == .codex ? .codex : nil
        let hours = UsableHours.resolve(activity: activity, source: source, settings: settings, now: now)
        return WeeklyReach.assess(snapshot: snapshot, history: quotaHistory(for: account.id), hours: hours, now: now)
    }
    func workPlan(for account: AccountConfiguration) -> [WorkPlanTarget] {
        guard let schedule = account.workSchedule, schedule.isEnabled,
              failures[account.id] == nil, var snapshot = snapshots[account.id] else { return [] }
        snapshot.windows = QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)
        return WorkPlanTarget.assess(snapshot: snapshot, history: quotaHistory(for: account.id), schedule: schedule, now: now)
    }
    var trayMeters: [TrayMeter] {
        TraySelection.meters(accounts: accounts, snapshots: snapshots, failures: Set(failures.keys), settings: settings, now: now)
    }
    var expiringCount: Int {
        accounts.reduce(0) { total, account in
            let benefits = snapshots[account.id].map { withManualResets($0).benefits } ?? manualResets.filter { $0.accountID == account.id }.map(\.benefit)
            return total + benefits.filter { $0.status == .available && ($0.expiresAt.map { $0 > now && $0.timeIntervalSince(now) < 72 * 3600 } ?? false) }.count
        }
    }
}

extension AppStore {
    func canRedeemReset(_ benefit: ResetBenefit, for account: AccountConfiguration) -> Bool {
        guard account.provider == .codex, account.enabled, accounts.contains(account), !benefit.isManual,
              !isLoading, pendingAccountMutations[account.id, default: 0] == 0, !credentialRecovery.contains(account.id),
              !redeemingResetAccounts.contains(account.id), !resetAccountsAwaitingRefresh.contains(account.id), failures[account.id] == nil,
              let snapshot = snapshots[account.id], snapshot.isFresh(at: Date()),
              snapshot.identity != AccountIdentity.fallback(for: account) else { return false }
        return snapshot.benefits.contains {
            $0.id == benefit.id && !$0.isManual && $0.status == .available && $0.count > 0 && ($0.expiresAt.map { $0 > Date() } ?? true)
        }
    }

    func redeemReset(_ benefit: ResetBenefit, for account: AccountConfiguration, expectedIdentity: String) async throws -> CodexResetResult {
        guard !isShuttingDown else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await performRedeemReset(benefit, for: account, expectedIdentity: expectedIdentity) }
        resetTasks[id] = task
        defer { resetTasks[id] = nil }
        return try await task.value
    }

    private func performRedeemReset(_ benefit: ResetBenefit, for account: AccountConfiguration, expectedIdentity: String) async throws -> CodexResetResult {
        guard !redeemingResetAccounts.contains(account.id) else {
            throw ProviderFailure.unavailable(tr("Einlösung läuft bereits."))
        }
        guard canRedeemReset(benefit, for: account), let snapshot = snapshots[account.id], snapshot.identity == expectedIdentity else {
            throw ProviderFailure.unavailable(tr("Die Reset-Gutschrift ist nicht mehr verfügbar oder das Konto hat sich geändert. Kontostand aktualisieren."))
        }
        let requestID = stableID("reset|\(account.id)|\(snapshot.identity)|\(benefit.id)")
        let key = resetRedemptionKeys[requestID] ?? UUID().uuidString
        // Persist before sending anything. An interrupted attempt keeps this key across retries and restarts.
        redeemingResetAccounts.insert(account.id)
        invalidateAccount(account.id)
        let generation = scheduler.generation(for: account.id)
        defer { redeemingResetAccounts.remove(account.id) }
        try await mutate(finishingAcceptedAction: true) { [self] in
            var keys = resetRedemptionKeys; keys[requestID] = key
            try await persistence.writeConfiguration(.resetRedemptions(keys))
            resetRedemptionKeys = keys
        }
        guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(account), !credentialRecovery.contains(account.id) else { throw CancellationError() }
        let result = try await resetRedeemer.redeem(configuration: account, expectedSnapshot: snapshot,
                                                    creditID: benefit.id, idempotencyKey: key)
        // Confirmation survives cancellation. Serialize it with account edits and removals.
        try await mutate(finishingAcceptedAction: true) { [self] in
            resetRedemptionKeys.removeValue(forKey: requestID)
            do { try await persistence.writeConfiguration(.resetRedemptions(resetRedemptionKeys)) }
            catch { storageError = error.localizedDescription }
            guard accounts.contains(where: { $0.id == account.id }) else { return }
            resetAccountsAwaitingRefresh.insert(account.id)
            guard !credentialRecovery.contains(account.id), scheduler.isCurrent(id: account.id, generation: generation),
                  accounts.contains(account), snapshots[account.id]?.identity == expectedIdentity,
                  var fresh = result.snapshot, fresh.configurationID == account.id, fresh.identity == expectedIdentity else { return }
            fresh = QuotaPeriod.normalizing(fresh, previous: snapshots[account.id])
            if fresh.dailyUsage.isEmpty { fresh.dailyUsage = snapshot.dailyUsage }
            do { try await persistence.saveObservation(fresh) } catch { storageError = error.localizedDescription }
            guard scheduler.isCurrent(id: account.id, generation: generation), accounts.contains(account) else { return }
            snapshots[account.id] = fresh; failures[account.id] = nil
            resetAccountsAwaitingRefresh.remove(account.id)
            history[account.id] = HistoryRetention.appending(fresh, to: history[account.id] ?? [])
            lastChecked = Date()
        }
        return result
    }
}
