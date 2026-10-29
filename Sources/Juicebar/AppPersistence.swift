import Foundation
import JuicebarCore

struct StoredConfiguration: Sendable {
    var accounts: [AccountConfiguration] = []
    var settings = MonitorSettings()
    var manualResets: [ManualReset] = []
    var resetRedemptionKeys: [String: String] = [:]
    var localDatabasePath = ""
    var sshHosts: [String] = []
    var activityRoots: [ActivityLogs.Root] = []
}

struct PersistenceBootstrap: Sendable {
    var configuration: StoredConfiguration
    var history: [String: [AccountSnapshot]] = [:]
    var snapshots: [String: AccountSnapshot] = [:]
    var warnings: [WarningEvent] = []
    var activity: ActivityReport?
    var localUsage: LocalUsageReport?
    var error: String?
    var hasUnreadablePreferences = false
}

struct AccountCommit: Sendable {
    var accounts: [AccountConfiguration]
    var manualResets: [ManualReset]
    var clearedHistory: Bool
}

enum AccountMutation: Sendable {
    case save(AccountConfiguration, secret: String, removeSavedKey: Bool)
    case remove(String)
    case removeSavedKey(String)
}

enum ConfigurationWrite: Sendable {
    case settings(MonitorSettings)
    case manualResets([ManualReset])
    case sshHosts([String])
    case activityRoots([ActivityLogs.Root])
    case localDatabasePath(String)
    case resetRedemptions([String: String])
}

struct CredentialRecoveryFailure: LocalizedError {
    var errorDescription: String? {
        tr("Der Schlüssel konnte nach einem Speicherfehler nicht wiederhergestellt werden. Bitte die Kontoaktion erneut versuchen. Bis dahin wird dieses Konto nicht abgerufen.")
    }
}

/// Owns the database and credential compensation. Every blocking operation, including open,
/// decode and close, runs on this worker. Neither the SQLite handle nor a callable database
/// escape hatch leaves the module. Once submitted, operations finish despite caller cancellation.
final class AppPersistence: @unchecked Sendable {
    private let worker: DispatchQueue
    private let directory: URL
    private let demo: Bool
    private let credentials: any CredentialStore
    // Accessed only on worker, including database destruction.
    private var database: HistoryDatabase?
    private var configuration = StoredConfiguration()
    private struct CredentialBackup { var secret: String? }
    private var credentialRecovery: [String: CredentialBackup] = [:]

    init(directory: URL, demo: Bool, credentials: any CredentialStore,
         workerTarget: DispatchQueue? = nil) {
        self.worker = DispatchQueue(label: "app.juicebar.persistence", qos: .utility, target: workerTarget)
        self.directory = directory; self.demo = demo; self.credentials = credentials
    }

    private func perform<T>(_ action: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result { try action() }) }
        }
    }

    func bootstrap() async -> PersistenceBootstrap {
        // No throwing work escapes bootstrap; an unavailable disk retains the session-only fallback.
        try! await perform { [self] in
            var errors: [String] = []
            if demo { database = try! HistoryDatabase(path: ":memory:") }
            else {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
                } catch {
                    database = try! HistoryDatabase(path: ":memory:")
                    errors.append(tr("Der Verlauf ist nur für diese Sitzung verfügbar: {0}", error.localizedDescription))
                }
                ModelCatalog.shared.configure(directory: directory)
            }
            let db = database!
            func load<T: Decodable>(_ type: T.Type, _ key: String, missing: @autoclosure () -> T, unreadable: T) -> T {
                do { return try db.read(type, key: key) ?? missing() }
                catch { errors.append(error.localizedDescription); return unreadable }
            }
            configuration.accounts = demo ? DemoData.accounts : load([AccountConfiguration].self, "accounts", missing: CLISetupHelp.detectedDefaultAccounts(), unreadable: [])
            configuration.settings = load(MonitorSettings.self, "settings", missing: MonitorSettings(), unreadable: MonitorSettings())
            configuration.settings.migrateLegacyRefreshDefault()
            configuration.manualResets = load([ManualReset].self, "manual-resets", missing: [], unreadable: [])
            configuration.resetRedemptionKeys = load([String: String].self, "reset-redemptions", missing: [:], unreadable: [:])
            configuration.localDatabasePath = load(String.self, "opencode-path", missing: "", unreadable: "")
            configuration.sshHosts = load([String].self, "ssh-hosts", missing: [], unreadable: [])
            configuration.activityRoots = load([ActivityLogs.Root].self, "activity-roots", missing: [], unreadable: [])
            var result = PersistenceBootstrap(configuration: configuration)
            result.activity = try? db.readCache(ActivityReport.self, key: "activity-report-v2")
            result.localUsage = try? db.readCache(LocalUsageReport.self, key: "local-usage-v2")
            do { result.warnings = try db.warnings() } catch { errors.append(error.localizedDescription) }
            let now = Date(), since = Date().addingTimeInterval(-HistoryRetention.loadedSpan)
            for account in configuration.accounts {
                do {
                    var values = try db.history(account: account.id, since: since, limit: HistoryRetention.maximumRows)
                    if values.isEmpty { values = try db.history(account: account.id, limit: 1) }
                    result.history[account.id] = HistoryRetention.thinned(values, now: now)
                    result.snapshots[account.id] = values.last
                } catch { errors.append(error.localizedDescription) }
            }
            result.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
            result.hasUnreadablePreferences = !db.unreadablePreferenceKeys.isEmpty
            return result
        }
    }

    func commitAccount(_ mutationRequest: AccountMutation) async throws -> AccountCommit {
        try await perform { [self] in
            let db = database!
            let mutation: AccountMutation
            if case let .removeSavedKey(id) = mutationRequest {
                guard let account = configuration.accounts.first(where: { $0.id == id }) else {
                    return AccountCommit(accounts: configuration.accounts, manualResets: configuration.manualResets, clearedHistory: false)
                }
                mutation = .save(account, secret: "", removeSavedKey: true)
            } else { mutation = mutationRequest }
            var accounts = configuration.accounts, resets = configuration.manualResets
            let id: String, secret: String?, clearHistory: Bool
            switch mutation {
            case let .save(account, suppliedSecret, removeKey):
                try db.requireWritablePreference("accounts")
                guard !removeKey || suppliedSecret.isEmpty else { throw ProviderFailure.invalidData(tr("Bitte den gespeicherten Key entweder ersetzen oder entfernen.")) }
                if let schedule = account.workSchedule, schedule.isEnabled, !schedule.isValid { throw ProviderFailure.invalidData(tr("Arbeitstage und Arbeitszeit prüfen.")) }
                let old = accounts.first { $0.id == account.id }
                if let old, old.provider != account.provider { throw ProviderFailure.unavailable(tr("Für einen anderen Anbieter bitte ein neues Konto hinzufügen.")) }
                if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
                else { accounts.append(account) }
                id = account.id
                secret = removeKey ? "" : suppliedSecret.isEmpty ? nil : suppliedSecret
                clearHistory = !removeKey && (old.map { $0.profileDirectory != account.profileDirectory || $0.useLocalCredentials != account.useLocalCredentials || !suppliedSecret.isEmpty } ?? false)
            case let .remove(accountID):
                id = accountID; secret = ""; clearHistory = true
                accounts.removeAll { $0.id == id }; resets.removeAll { $0.accountID == id }
            case .removeSavedKey: preconditionFailure("Normalized above")
            }
            try restoreCredential(id)
            var backup: CredentialBackup?
            do {
                let beforeCommit = {
                    guard let secret, !self.demo else { return }
                    let previous = try self.credentials.read(account: id)
                    if secret.isEmpty { try self.credentials.remove(account: id) }
                    else { try self.credentials.save(secret, account: id) }
                    backup = CredentialBackup(secret: previous)
                }
                switch mutation {
                case .save: try db.saveAccounts(accounts, clearingHistoryFor: clearHistory ? id : nil, beforeCommit: beforeCommit)
                case .remove: try db.deleteAccount(id, accounts: accounts, manualResets: resets, beforeCommit: beforeCommit)
                case .removeSavedKey: preconditionFailure("Normalized above")
                }
            } catch {
                if let backup {
                    credentialRecovery[id] = backup
                    try restoreCredential(id)
                }
                throw error
            }
            configuration.accounts = accounts; configuration.manualResets = resets
            return AccountCommit(accounts: accounts, manualResets: resets, clearedHistory: clearHistory)
        }
    }

    private func restoreCredential(_ id: String) throws {
        guard let backup = credentialRecovery[id] else { return }
        do {
            if let secret = backup.secret { try credentials.save(secret, account: id) }
            else { try credentials.remove(account: id) }
            credentialRecovery[id] = nil
        } catch { throw CredentialRecoveryFailure() }
    }

    func hasSavedKey(_ id: String) async -> Bool {
        try! await perform { [self] in !demo && credentials.contains(account: id) }
    }

    func writeConfiguration(_ change: ConfigurationWrite) async throws {
        try await perform { [self] in
            let db = database!
            switch change {
            case let .settings(value): try db.write(value, key: "settings"); configuration.settings = value
            case let .manualResets(value): try db.write(value, key: "manual-resets"); configuration.manualResets = value
            case let .sshHosts(value): try db.write(value, key: "ssh-hosts"); configuration.sshHosts = value
            case let .activityRoots(value): try db.write(value, key: "activity-roots"); configuration.activityRoots = value
            case let .localDatabasePath(value): try db.write(value, key: "opencode-path"); configuration.localDatabasePath = value
            case let .resetRedemptions(value): try db.write(value, key: "reset-redemptions"); configuration.resetRedemptionKeys = value
            }
        }
    }

    func saveObservation(_ snapshot: AccountSnapshot) async throws {
        try await perform { [self] in try database!.save(snapshot) }
    }

    func recordDelivered(_ events: [WarningEvent]) async throws {
        try await perform { [self] in
            var failure: Error?
            for event in events { do { try database!.saveWarning(event) } catch { failure = error } }
            if let failure { throw failure }
        }
    }

    func cacheImport(_ activity: ActivityReport, localUsage: LocalUsageReport?) async {
        _ = try? await perform { [self] in
            try? database!.write(activity, key: "activity-report-v2")
            if let localUsage { try? database!.write(localUsage, key: "local-usage-v2") }
        }
    }

    func recoverConfiguration() async throws -> Set<String> {
        try await perform { [self] in
            let keys = try database!.recoverUnreadablePreferences()
            if keys.contains("accounts") { configuration.accounts = [AccountConfiguration(id: "default-codex", provider: .codex), AccountConfiguration(id: "default-claude", provider: .claude)] }
            if keys.contains("settings") { configuration.settings = MonitorSettings() }
            if keys.contains("manual-resets") { configuration.manualResets = [] }
            if keys.contains("reset-redemptions") { configuration.resetRedemptionKeys = [:] }
            return keys
        }
    }

    func drain() async { _ = try? await perform {} }

    deinit {
        // The last reference to the connection also dies on its owning worker.
        let connection = database
        worker.async { withExtendedLifetime(connection) {} }
    }
}
