import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import JuicebarCore

struct ManualReset: Codable, Identifiable {
    var id: String { benefit.id }
    var accountID: String
    var benefit: ResetBenefit
}

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore(demo: CommandLine.arguments.contains("--demo"))
    @Published var accounts: [AccountConfiguration]
    @Published var settings: MonitorSettings
    @Published var snapshots: [String: AccountSnapshot] = [:]
    @Published var failures: [String: String] = [:]
    @Published var refreshingAccount: String?
    @Published var isRefreshing = false
    @Published var isPaused = false { didSet { if isPaused { refreshTask?.cancel(); cancelActivityImport() } else { refreshActivityIfNeeded() } } }
    @Published var lastChecked: Date?
    @Published var now = Date()
    @Published var history: [String: [AccountSnapshot]] = [:]
    @Published var warnings: [WarningEvent] = []
    @Published var manualResets: [ManualReset] = []
    @Published var localUsage: LocalUsageReport?
    @Published var localUsageError: String?
    @Published var localUsageLoading = false
    @Published var activity: ActivityReport?
    @Published var sshHosts: [String] = []
    @Published var activityProgress = ""
    private var nextActivityImport = Date.distantPast
    private let storageDirectory: URL
    private var activityTask: Task<Void, Never>?
    private var activityWorker: Task<(ActivityReport, LocalUsageReport?), Error>?
    @Published var storageError: String?
    @Published var notificationStatus = tr("Nicht aktiviert")
    @Published var localDatabasePath = ""
    let isDemo: Bool
    private let database: HistoryDatabase
    private let registry = ProviderRegistry()
    private var nextFetch: [String: Date] = [:]
    private var rateLimitedUntil: [String: Date] = [:]
    private var failureCounts: [String: Int] = [:]
    private var lastUsageFetch: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

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
        accounts = demo ? DemoData.accounts : ((try? database.read([AccountConfiguration].self, key: "accounts")) ?? [AccountConfiguration(id: "default-codex", provider: .codex), AccountConfiguration(id: "default-claude", provider: .claude)])
        settings = (try? database.read(MonitorSettings.self, key: "settings")) ?? MonitorSettings()
        manualResets = (try? database.read([ManualReset].self, key: "manual-resets")) ?? []
        localDatabasePath = (try? database.read(String.self, key: "opencode-path")) ?? ""
        warnings = (try? database.warnings()) ?? []
        sshHosts = (try? database.read([String].self, key: "ssh-hosts")) ?? []
        activity = try? database.read(ActivityReport.self, key: "activity-report-v2")
        localUsage = try? database.read(LocalUsageReport.self, key: "local-usage-v2")
        storageError = startupError
        for account in accounts {
            let values = (try? database.history(account: account.id, limit: 1200)) ?? []
            history[account.id] = values; snapshots[account.id] = values.last
        }
        if demo {
            for snapshot in DemoData.snapshots() {
                snapshots[snapshot.configurationID] = snapshot
                history[snapshot.configurationID] = (0..<24).map { index in
                    var past = snapshot; past.observedAt = now.addingTimeInterval(Double(index - 23) * 3600)
                    past.windows = past.windows.map { window in var w = window; w.usedPercent *= Double(index + 2) / 25; return w }
                    return past
                }
            }
            lastChecked = now
            activity = DemoData.activity(now: now)
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.now = Date()
                if !self.isPaused { self.refresh(); self.refreshActivityIfNeeded() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshTask?.cancel(); self?.cancelActivityImport() }
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

    func stop() { timer?.invalidate(); timer = nil; refreshTask?.cancel(); cancelActivityImport() }
    func shutDown() async { stop(); await refreshTask?.value; await activityTask?.value }

    func refresh(force: Bool = false, only accountID: String? = nil) {
        guard !isRefreshing, !isDemo else { return }
        let selected = accounts.filter { $0.enabled && (accountID == nil || $0.id == accountID) }
        guard !selected.isEmpty else { return }
        isRefreshing = true
        refreshTask = Task {
            defer { isRefreshing = false; refreshingAccount = nil }
            for account in selected {
                guard !Task.isCancelled else { break }
                let now = Date()
                if let until = rateLimitedUntil[account.id], until > now { continue }
                if !force, let next = nextFetch[account.id], next > now { continue }
                refreshingAccount = account.id
                let includeUsage = lastUsageFetch[account.id].map { now.timeIntervalSince($0) > 1800 } ?? true
                do {
                    var snapshot = try await registry.provider(for: account.provider).read(configuration: account, includeHistory: includeUsage)
                    guard !Task.isCancelled, accounts.contains(where: { $0 == account }) else { continue }
                    if let previous = snapshots[account.id], previous.identity != snapshot.identity {
                        history[account.id] = []; try database.removeAccount(account.id)
                    }
                    if snapshot.dailyUsage.isEmpty, let previous = snapshots[account.id], previous.identity == snapshot.identity {
                        snapshot.dailyUsage = previous.dailyUsage
                    }
                    if includeUsage { lastUsageFetch[account.id] = now }
                    snapshots[account.id] = snapshot; failures[account.id] = nil; failureCounts[account.id] = 0
                    try? database.write(failures, key: "last-errors")
                    var entries = history[account.id] ?? []; entries.append(snapshot)
                    history[account.id] = Array(entries.suffix(1200))
                    do { try database.save(snapshot) } catch { storageError = error.localizedDescription }
                    let interval = account.provider == .anthropicAPI || account.provider == .openaiAPI ? max(settings.refreshSeconds, 300) : max(settings.refreshSeconds, 60)
                    nextFetch[account.id] = now.addingTimeInterval(interval)
                    await notify(account: account, snapshot: withManualResets(snapshot))
                } catch is CancellationError { break }
                catch {
                    failures[account.id] = error.localizedDescription
                    try? database.write(failures, key: "last-errors")
                    let count = min((failureCounts[account.id] ?? 0) + 1, 5); failureCounts[account.id] = count
                    var delay = max(60, settings.refreshSeconds) * pow(2, Double(count - 1))
                    if case ProviderFailure.rateLimited(let retry) = error { delay = retry; rateLimitedUntil[account.id] = now.addingTimeInterval(retry) }
                    nextFetch[account.id] = now.addingTimeInterval(min(delay, 86400))
                    if case ProviderFailure.needsSetup = error { nextFetch[account.id] = .distantFuture }
                }
                lastChecked = Date()
            }
            // Manual expiration dates also work for disconnected accounts.
            for account in accounts where account.enabled {
                var snapshot = snapshots[account.id] ?? AccountSnapshot(configurationID: account.id, identity: account.id, observedAt: .distantPast, source: tr("Manuell"))
                snapshot = withManualResets(snapshot)
                await notify(account: account, snapshot: snapshot)
            }
        }
    }

    func withManualResets(_ snapshot: AccountSnapshot) -> AccountSnapshot {
        var value = snapshot
        value.benefits += manualResets.filter { $0.accountID == snapshot.configurationID }.map(\.benefit)
        return value
    }

    private func notify(account: AccountConfiguration, snapshot: AccountSnapshot) async {
        guard settings.notificationsEnabled, !settings.isQuiet(at: Date()), !isDemo else { return }
        let events = WarningEngine.events(snapshot: snapshot, accountName: account.displayName, history: history[account.id] ?? [],
                                          settings: settings, sent: Set(warnings.map(\.id)))
        guard !events.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = account.displayName
        content.body = events.map(\.message).joined(separator: "\n")
        if settings.soundEnabled { content.sound = .default }
        content.userInfo = ["account": account.id]
        do {
            let permission = await UNUserNotificationCenter.current().notificationSettings()
            guard permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional else { return }
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: events[0].id, content: content, trigger: nil))
            for event in events { try database.saveWarning(event); warnings.insert(event, at: 0) }
        } catch { storageError = tr("Warnung konnte nicht gespeichert oder zugestellt werden. {0}", error.localizedDescription) }
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
        let content = UNMutableNotificationContent(); content.title = tr("Juicebar ist bereit")
        content.body = settings.soundEnabled ? tr("Test für Banner und Hinweiston.") : tr("Test für Banner. Der Hinweiston ist in Juicebar ausgeschaltet.")
        if settings.soundEnabled { content.sound = .default }
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
        catch { notificationStatus = error.localizedDescription }
    }
    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    func persistSettings() {
        do { try database.write(settings, key: "settings") } catch { storageError = error.localizedDescription }
    }
    func saveAccount(_ account: AccountConfiguration, secret: String) throws {
        if let old = accounts.first(where: { $0.id == account.id }), old.provider != account.provider {
            throw ProviderFailure.unavailable(tr("Für einen anderen Anbieter bitte ein neues Konto hinzufügen."))
        }
        if !secret.isEmpty && !isDemo { try SecretStore.save(secret, account: account.id) }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let old = accounts[index]
            if old.provider != account.provider || old.profileDirectory != account.profileDirectory || !secret.isEmpty {
                snapshots[account.id] = nil; history[account.id] = []; try database.removeAccount(account.id)
            }
            accounts[index] = account
        } else { accounts.append(account) }
        try database.write(accounts, key: "accounts")
        nextFetch[account.id] = nil; rateLimitedUntil[account.id] = nil
        refresh(force: true, only: account.id)
    }
    func removeAccount(_ account: AccountConfiguration) {
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
        guard !isPaused, Date() >= nextActivityImport else { return }
        loadLocalUsage()
    }
    func loadLocalUsage() {
        guard !localUsageLoading, !isDemo else { return }
        nextActivityImport = Date().addingTimeInterval(300)
        localUsageLoading = true; activityProgress = tr("Nutzungsdaten werden aktualisiert …")
        let path = localDatabasePath.isEmpty ? nil : localDatabasePath
        let roots = ActivityLogs.defaultRoots(accounts: accounts)
        let owner = self, hosts = sshHosts, directory = storageDirectory
        let worker = Task.detached(priority: .utility) {
            if UserDefaults.standard.object(forKey: "catalogUpdates") as? Bool ?? true { _ = await ModelCatalog.shared.refreshIfNeeded() }
            return try ActivityImport.read(roots: roots, databasePath: path, hosts: hosts, directory: directory) { message in
                Task { @MainActor in owner.activityProgress = message }
            }
        }
        activityWorker = worker
        activityTask = Task {
            defer { localUsageLoading = false; activityWorker = nil; activityProgress = ""; nextActivityImport = Date().addingTimeInterval(300) }
            do {
                let result = try await worker.value
                guard !Task.isCancelled else { return }
                activity = result.0; localUsage = result.1; localUsageError = nil
                try database.write(result.0, key: "activity-report-v2")
                if let localUsage { try database.write(localUsage, key: "local-usage-v2") }
                try database.write(localDatabasePath, key: "opencode-path")
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
    func cancelActivityImport() { activityWorker?.cancel(); activityTask?.cancel() }
    func selectLocalDatabase() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = tr("OpenCode-Datenbank nur lesend öffnen")
        if panel.runModal() == .OK, let url = panel.url { localDatabasePath = url.path; reloadActivitySources() }
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
