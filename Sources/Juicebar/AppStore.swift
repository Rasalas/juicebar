import SwiftUI
import AppKit
import Observation
import UserNotifications
import ServiceManagement
import JuicebarCore

struct ManualReset: Codable, Identifiable {
    var id: String { benefit.id }
    var accountID: String
    var benefit: ResetBenefit
}

@MainActor @Observable
final class AppStore {
    static let shared = AppStore(demo: CommandLine.arguments.contains("--demo"))
    var accounts: [AccountConfiguration]
    var settings: MonitorSettings
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
    @ObservationIgnored private var activityWorker: Task<(ActivityReport, LocalUsageReport?), Error>?
    @ObservationIgnored private var activityImportID: UUID?
    @ObservationIgnored private var lastActivityProgress: ContinuousClock.Instant?
    var storageError: String?
    var hasRecoverableStorageError = false
    var notificationStatus = tr("Nicht aktiviert")
    var localDatabasePath = ""
    let isDemo: Bool
    private let database: HistoryDatabase
    private let registry = ProviderRegistry()
    @ObservationIgnored private var refreshPolicy = AccountRefreshPolicy()
    private let scheduler = AccountRefreshScheduler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingWarningIDs: Set<String> = []
    @ObservationIgnored private var quotaHistoryCache: [String: [AccountSnapshot]] = [:]

    init(demo: Bool = false, directory: URL? = nil) {
        isDemo = demo
        let fm = FileManager.default
        let directory = directory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Juicebar", isDirectory: true)
        storageDirectory = directory
        var startupError: String?
        if demo { database = try! HistoryDatabase(path: ":memory:") }
        else {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
            } catch {
                database = try! HistoryDatabase(path: ":memory:")
                startupError = tr("Der Verlauf ist nur für diese Sitzung verfügbar: {0}", error.localizedDescription)
            }
        }
        if !demo { ModelCatalog.shared.configure(directory: directory) }
        let persistedDatabase = database
        func load<T: Decodable>(_ type: T.Type, key: String, missing: T, unreadable: T) -> T {
            do { return try persistedDatabase.read(type, key: key) ?? missing }
            catch {
                startupError = [startupError, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
                return unreadable
            }
        }
        accounts = demo ? DemoData.accounts : load([AccountConfiguration].self, key: "accounts", missing: CLISetupHelp.detectedDefaultAccounts(), unreadable: [])
        settings = load(MonitorSettings.self, key: "settings", missing: MonitorSettings(), unreadable: MonitorSettings())
        manualResets = load([ManualReset].self, key: "manual-resets", missing: [], unreadable: [])
        localDatabasePath = load(String.self, key: "opencode-path", missing: "", unreadable: "")
        sshHosts = load([String].self, key: "ssh-hosts", missing: [], unreadable: [])
        activityRoots = load([ActivityLogs.Root].self, key: "activity-roots", missing: [], unreadable: [])
        activity = try? database.readCache(ActivityReport.self, key: "activity-report-v2")
        localUsage = try? database.readCache(LocalUsageReport.self, key: "local-usage-v2")
        do { warnings = try database.warnings() } catch { startupError = error.localizedDescription }
        storageError = startupError
        hasRecoverableStorageError = !database.unreadablePreferenceKeys.isEmpty
        settings.migrateLegacyRefreshDefault()
        for account in accounts {
            let values = (try? database.history(account: account.id, limit: 1200)) ?? []
            history[account.id] = values; snapshots[account.id] = values.last
        }
        scheduler.onChange = { [weak self] ids in
            guard let self else { return }
            if self.refreshingAccountIDs != ids { self.refreshingAccountIDs = ids }
        }
        if demo {
            for snapshot in DemoData.snapshots(now: now) {
                snapshots[snapshot.configurationID] = snapshot
                history[snapshot.configurationID] = DemoData.history(for: snapshot, now: now)
            }
            lastChecked = now
            activity = DemoData.activity(now: now)
        }
    }

    func start() {
        guard timer == nil else { return }
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
        Task { await updateNotificationStatus() }
    }

    /// Views show minutes at most, so a new `now` within the same minute would only redraw them.
    func tick(at date: Date = Date()) {
        if Int(date.timeIntervalSinceReferenceDate / 60) != Int(now.timeIntervalSinceReferenceDate / 60) { now = date }
    }

    func stop() { timer?.invalidate(); timer = nil; scheduler.cancelAll(); cancelActivityImport() }
    func shutDown() async { stop(); await scheduler.waitUntilIdle(); await activityTask?.value }

    func refresh(force: Bool = false, only accountID: String? = nil) {
        guard !isDemo, !isPaused else { return }
        let selected = accounts.filter { $0.enabled && (accountID == nil || $0.id == accountID) }
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
                    let identity = AccountIdentity.reconcile(snapshot, previous: snapshots[account.id], configuration: account)
                    snapshot = QuotaPeriod.normalizing(identity.snapshot, previous: snapshots[account.id])
                    if identity.switchedLogin {
                        history[account.id] = []
                        do { try database.removeAccount(account.id) } catch { storageError = error.localizedDescription }
                    }
                    if snapshot.dailyUsage.isEmpty, let previous = snapshots[account.id], previous.identity == snapshot.identity {
                        snapshot.dailyUsage = previous.dailyUsage
                    }
                    snapshots[account.id] = snapshot; failures[account.id] = nil
                    var entries = history[account.id] ?? []; entries.append(snapshot)
                    history[account.id] = Array(entries.suffix(1200))
                    do { try database.save(snapshot) } catch { storageError = error.localizedDescription }
                    refreshPolicy.succeeded(account: account, refreshSeconds: settings.refreshSeconds, includedHistory: includeUsage,
                                            unchanged: !force && AccountRefreshPolicy.quotaUnchanged(from: entries.dropLast().last, to: snapshot), now: Date())
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
        Task {
            for (account, generation) in manualChecks {
                guard scheduler.isCurrent(id: account.id, generation: generation), !isPaused, accounts.contains(account) else { continue }
                let snapshot = snapshots[account.id] ?? AccountSnapshot(configurationID: account.id, identity: account.id, observedAt: .distantPast, source: tr("Manuell"))
                await notify(account: account, snapshot: withManualResets(snapshot), generation: generation)
            }
        }
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
        let content = UNMutableNotificationContent()
        content.title = account.displayName
        content.body = events.map(\.message).joined(separator: "\n")
        if settings.soundEnabled { content.sound = .default }
        content.userInfo = ["account": account.id]
        do {
            let permission = await UNUserNotificationCenter.current().notificationSettings()
            guard scheduler.isCurrent(id: account.id, generation: generation), !isPaused, accounts.contains(account) else { return }
            guard permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional else { return }
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: events[0].id, content: content, trigger: nil))
        } catch {
            guard scheduler.isCurrent(id: account.id, generation: generation), !isPaused, accounts.contains(account) else { return }
            storageError = tr("Warnung konnte nicht gespeichert oder zugestellt werden. {0}", error.localizedDescription)
            return
        }
        // Delivered even if the Mac slept or the account changed meanwhile, so it must count as sent.
        recordDelivered(events)
    }

    func recordDelivered(_ events: [WarningEvent]) {
        var failure: Error?
        for event in events {
            warnings.insert(event, at: 0)
            do { try database.saveWarning(event) } catch { failure = error }
        }
        if let failure { storageError = tr("Warnung konnte nicht gespeichert oder zugestellt werden. {0}", failure.localizedDescription) }
    }

    func enableNotifications() async {
        guard !isDemo else { return }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            settings.notificationsEnabled = allowed; persistSettings()
            await updateNotificationStatus()
            if allowed { refresh(force: true) }
        } catch { notificationStatus = error.localizedDescription }
    }
    func updateNotificationStatus() async {
        guard !isDemo else { notificationStatus = tr("Im Demo-Modus deaktiviert"); return }
        let status = await UNUserNotificationCenter.current().notificationSettings()
        switch status.authorizationStatus {
        case .authorized:
            let banner = status.alertSetting == .enabled && status.alertStyle != .none
            notificationStatus = tr("Banner: {0} · macOS-Ton: {1}", banner ? tr("an") : tr("aus"), status.soundSetting == .enabled ? tr("an") : tr("aus"))
        case .provisional: notificationStatus = tr("Nur stille Zustellung erlaubt · Banner in macOS aktivieren")
        case .denied: notificationStatus = tr("In den macOS-Systemeinstellungen gesperrt")
        default: notificationStatus = tr("Noch nicht freigegeben")
        }
    }
    func testNotification() async {
        guard !isDemo else { return }
        await updateNotificationStatus()
        let content = UNMutableNotificationContent(); content.title = tr("Juicebars ist bereit")
        content.body = settings.soundEnabled ? tr("Test für Banner und Hinweiston.") : tr("Test für Banner. Der Hinweiston ist in Juicebars ausgeschaltet.")
        if settings.soundEnabled { content.sound = .default }
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
        catch { notificationStatus = error.localizedDescription }
    }
    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    func recoverStoredConfiguration() {
        do {
            let keys = try database.recoverUnreadablePreferences()
            if keys.contains("accounts") {
                scheduler.cancelAll()
                accounts = [AccountConfiguration(id: "default-codex", provider: .codex), AccountConfiguration(id: "default-claude", provider: .claude)]
                snapshots = [:]; history = [:]; failures = [:]
                refreshPolicy = AccountRefreshPolicy()
            }
            if keys.contains("settings") { settings = MonitorSettings() }
            if keys.contains("manual-resets") { manualResets = [] }
            if keys.contains("opencode-path") { localDatabasePath = "" }
            if keys.contains("ssh-hosts") { sshHosts = [] }
            if keys.contains("activity-roots") { activityRoots = [] }
            hasRecoverableStorageError = false
            storageError = tr("Zurückgesetzt: {0}. Die Originaldaten bleiben gesichert.", keys.sorted().joined(separator: ", "))
        } catch { storageError = error.localizedDescription }
    }

    func persistSettings() {
        do { try database.write(settings, key: "settings") } catch { storageError = error.localizedDescription }
    }
    private func invalidateAccount(_ id: String) {
        scheduler.invalidate(id: id)
        failures[id] = nil
        refreshPolicy.remove(id: id)
    }
    func saveAccount(_ account: AccountConfiguration, secret: String) throws {
        try database.requireWritablePreference("accounts")
        if let old = accounts.first(where: { $0.id == account.id }), old.provider != account.provider {
            throw ProviderFailure.unavailable(tr("Für einen anderen Anbieter bitte ein neues Konto hinzufügen."))
        }
        invalidateAccount(account.id)
        if !secret.isEmpty && !isDemo { try SecretStore.save(secret, account: account.id) }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let old = accounts[index]
            if old.provider != account.provider || old.profileDirectory != account.profileDirectory || !secret.isEmpty {
                snapshots[account.id] = nil; history[account.id] = []; try database.removeAccount(account.id)
            }
            accounts[index] = account
        } else { accounts.append(account) }
        try database.write(accounts, key: "accounts")
        refresh(force: true, only: account.id)
    }
    func removeAccount(_ account: AccountConfiguration) {
        do {
            try database.requireWritablePreference("accounts")
            try database.requireWritablePreference("manual-resets")
        } catch { storageError = error.localizedDescription; return }
        invalidateAccount(account.id)
        accounts.removeAll { $0.id == account.id }; snapshots[account.id] = nil; history[account.id] = nil
        manualResets.removeAll { $0.accountID == account.id }; if !isDemo { SecretStore.remove(account: account.id) }
        do { try database.write(accounts, key: "accounts"); try database.write(manualResets, key: "manual-resets"); try database.removeAccount(account.id) }
        catch { storageError = error.localizedDescription }
    }
    func addReset(accountID: String, title: String, scope: String, expiry: Date) {
        manualResets.append(ManualReset(accountID: accountID, benefit: ResetBenefit(id: UUID().uuidString, title: title, scope: scope, expiresAt: expiry, isManual: true)))
        saveResets()
    }
    func removeReset(_ id: String) { manualResets.removeAll { $0.id == id }; saveResets() }
    private func saveResets() { do { try database.write(manualResets, key: "manual-resets") } catch { storageError = error.localizedDescription } }
    func openAccount(_ account: AccountConfiguration) { NSWorkspace.shared.open(account.provider.accountURL) }
    func snooze() { settings.snoozedUntil = Date().addingTimeInterval(3600); persistSettings() }
    func refreshActivityIfNeeded() {
        nextActivityImport = min(nextActivityImport, Date().addingTimeInterval(300))
        guard !isPaused, Date() >= nextActivityImport else { return }
        loadLocalUsage(refreshRemote: false)
    }
    func loadLocalUsage(refreshRemote: Bool = true) {
        guard !localUsageLoading, !isDemo else { return }
        nextActivityImport = Date().addingTimeInterval(300)
        localUsageLoading = true; activityProgress = tr("Nutzungsdaten werden aktualisiert …")
        let importID = UUID()
        activityImportID = importID
        lastActivityProgress = .now
        let path = localDatabasePath.isEmpty ? nil : localDatabasePath
        let roots = ActivityLogs.defaultRoots(accounts: accounts, additional: activityRoots)
        let owner = self, hosts = sshHosts, directory = storageDirectory
        let worker = Task.detached(priority: .utility) {
            if UserDefaults.standard.object(forKey: "catalogUpdates") as? Bool ?? true { _ = await ModelCatalog.shared.refreshIfNeeded() }
            return try ActivityImport.read(roots: roots, databasePath: path, hosts: hosts, directory: directory, refreshRemote: refreshRemote) { message in
                Task { @MainActor in
                    guard owner.activityImportID == importID else { return }
                    let instant = ContinuousClock.now
                    // Thousands of files otherwise invalidate every store-observing view hundreds of times.
                    if let last = owner.lastActivityProgress, last.duration(to: instant) < .seconds(1) { return }
                    owner.lastActivityProgress = instant
                    if owner.activityProgress != message { owner.activityProgress = message }
                }
            }
        }
        activityWorker = worker
        activityTask = Task {
            defer { localUsageLoading = false; activityWorker = nil; activityImportID = nil; activityProgress = ""; nextActivityImport = Date().addingTimeInterval(300) }
            do {
                let result = try await worker.value
                guard !Task.isCancelled else { return }
                activity = result.0; localUsage = result.1; localUsageError = nil
                try database.write(localDatabasePath, key: "opencode-path")
                // Caches only speed up the next launch; the next import rebuilds them.
                try? database.write(result.0, key: "activity-report-v2")
                if let localUsage { try? database.write(localUsage, key: "local-usage-v2") }
            } catch is CancellationError { }
            catch { localUsageError = error.localizedDescription }
        }
    }
    func addSSHHost(_ host: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHActivity.isValidHost(host) else { throw ProviderFailure.invalidData(tr("Bitte einen SSH-Alias wie workstation oder user@host eingeben.")) }
        guard !sshHosts.contains(host) else { return }
        sshHosts.append(host); try database.write(sshHosts, key: "ssh-hosts"); reloadActivitySources()
    }
    func removeSSHHost(_ host: String) {
        sshHosts.removeAll { $0 == host }
        do { try database.write(sshHosts, key: "ssh-hosts"); reloadActivitySources() } catch { storageError = error.localizedDescription }
    }
    private func reloadActivitySources() {
        cancelActivityImport()
        let previous = activityTask
        Task { await previous?.value; loadLocalUsage() }
    }
    func cancelActivityImport() { activityImportID = nil; activityWorker?.cancel(); activityTask?.cancel() }
    func selectActivityDirectory(format: ActivitySource) {
        guard !isDemo, ActivitySource.logFormats.contains(format) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = format == .kilo ? tr("Ordner mit Kilo-Datenbanken auswählen.") : tr("Ordner mit {0}-Logs auswählen. Unterordner werden mitgelesen.", format.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = ActivityLogs.Root(source: format, url: url.standardizedFileURL.resolvingSymlinksInPath())
        guard !activityRoots.contains(where: { $0.url == root.url }) else { return }
        saveActivityRoots(activityRoots + [root])
    }
    func removeActivityRoot(_ root: ActivityLogs.Root) {
        guard !isDemo else { return }
        saveActivityRoots(activityRoots.filter { $0.id != root.id })
    }
    private func saveActivityRoots(_ roots: [ActivityLogs.Root]) {
        do {
            try database.write(roots, key: "activity-roots")
            activityRoots = roots; reloadActivitySources()
        } catch { storageError = error.localizedDescription }
    }
    func selectLocalDatabase() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = tr("OpenCode-Datenbank nur lesend öffnen")
        if panel.runModal() == .OK, let url = panel.url { localDatabasePath = url.path; reloadActivitySources() }
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
        guard failures[account.id] == nil, var snapshot = snapshots[account.id] else { return [] }
        snapshot.windows = QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)
        let source: ActivitySource? = account.provider == .claude ? .claude : account.provider == .codex ? .codex : nil
        let hours = UsableHours.resolve(activity: activity, source: source, settings: settings, now: now)
        return WeeklyReach.assess(snapshot: snapshot, history: quotaHistory(for: account.id), hours: hours, now: now)
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
