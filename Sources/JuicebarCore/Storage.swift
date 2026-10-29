import Foundation
import CSQLite

/// How long quota history is kept and which observations add nothing to it.
public enum HistoryRetention {
    /// A full previous weekly cycle with margin.
    public static let storedSpan: TimeInterval = 30 * 86400
    /// The app holds only the span it evaluates.
    public static let loadedSpan = WeeklyReach.historySpan
    /// Projections and the 24-hour chart read every poll of the last day.
    public static let completeSpan: TimeInterval = 86400
    public static let maximumRows = 10_000

    /// Equal values and periods: a row between two such neighbours changes no delta, period match or chart step.
    static func sameQuota(_ a: AccountSnapshot, _ b: AccountSnapshot) -> Bool {
        a.configurationID == b.configurationID && a.identity == b.identity && a.windows.count == b.windows.count
            && zip(a.windows, b.windows).allSatisfy {
                $0.id == $1.id && $0.duration == $1.duration && $0.usedPercent == $1.usedPercent
                    && ($0.periodAnchor ?? $0.resetsAt) == ($1.periodAnchor ?? $1.resetsAt)
            }
    }
    /// Rows observed in `start..<cutoff` inside a run of unchanged quota; both ends of the run stay. Expects chronological order.
    static func redundant(_ history: [AccountSnapshot], from start: Date = .distantPast, before cutoff: Date) -> [Int] {
        let lower = max(1, firstIndex(in: history, notBefore: start)), upper = min(history.count - 1, firstIndex(in: history, notBefore: cutoff))
        guard lower < upper else { return [] }
        return (lower..<upper).filter { sameQuota(history[$0 - 1], history[$0]) && sameQuota(history[$0], history[$0 + 1]) }
    }
    private static func firstIndex(in history: [AccountSnapshot], notBefore date: Date) -> Int {
        var low = 0, high = history.count
        while low < high { let mid = (low + high) / 2; if history[mid].observedAt < date { low = mid + 1 } else { high = mid } }
        return low
    }
    /// Thins history loaded from the database, which may hold polls that crossed the one-day line while the app was closed.
    public static func thinned(_ history: [AccountSnapshot], now: Date) -> [AccountSnapshot] {
        let drop = Set(redundant(history, before: now.addingTimeInterval(-completeSpan)))
        return history.indices.filter { !drop.contains($0) }.map { history[$0] }
    }
    /// Applies the database limits to in-memory history; only polls that crossed the one-day line since the last append are examined.
    public static func appending(_ snapshot: AccountSnapshot, to history: [AccountSnapshot]) -> [AccountSnapshot] {
        var result = history; result.append(snapshot)
        let now = snapshot.observedAt
        if let first = result.firstIndex(where: { now.timeIntervalSince($0.observedAt) <= loadedSpan }) { result.removeFirst(first) }
        let since = (history.last?.observedAt ?? .distantPast).addingTimeInterval(-completeSpan)
        for index in redundant(result, from: since, before: now.addingTimeInterval(-completeSpan)).reversed() { result.remove(at: index) }
        if result.count > maximumRows { result.removeFirst(result.count - maximumRows) }
        return result
    }
}

/// All access is serialized by the owning store. Contains metadata only, never credentials or transcripts.
public final class HistoryDatabase {
    private var database: OpaquePointer?
    private var unreadablePreferences: Set<String> = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var insertsSincePrune: [String: Int] = [:]
    /// Thinning resumes at the second-to-last kept row, so a run continuing past the cutoff still collapses.
    private var thinnedFrom: [String: Double] = [:]
    public init(path: String) throws {
        if sqlite3_open(path, &database) != SQLITE_OK { throw ProviderFailure.unavailable(tr("Der lokale Verlauf konnte nicht geöffnet werden.")) }
        sqlite3_busy_timeout(database, 100)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS observations (id INTEGER PRIMARY KEY, account TEXT NOT NULL, time REAL NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS observation_account_time ON observations(account,time); CREATE TABLE IF NOT EXISTS warnings (id TEXT PRIMARY KEY, time REAL NOT NULL, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS preferences (id TEXT PRIMARY KEY, payload BLOB NOT NULL);")
        // Migrations are housekeeping only; a busy database retries on the next launch.
        try? migrate()
    }
    private func migrate() throws {
        let stmt = try statement("PRAGMA user_version")
        let version = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
        sqlite3_finalize(stmt)
        // Version 1 also drops the never-read "last-errors" row.
        if version < 1 { try execute("CREATE INDEX IF NOT EXISTS warning_time ON warnings(time); DELETE FROM preferences WHERE id='last-errors'; PRAGMA user_version=1") }
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ProviderFailure.unavailable(tr("Der lokale Verlauf ist momentan nicht verfügbar.")) }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ProviderFailure.unavailable(tr("Der lokale Verlauf konnte nicht gelesen werden.")) }
        return stmt
    }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) { sqlite3_bind_text(stmt, index, value, -1, transient) }
    private func bind(_ value: Data, to stmt: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(value.count), transient) }
    }
    private func data(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, column)))
    }
    public func save(_ snapshot: AccountSnapshot) throws {
        let stmt = try statement("INSERT INTO observations(account,time,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(snapshot.configurationID, to: stmt, at: 1)
        sqlite3_bind_double(stmt, 2, snapshot.observedAt.timeIntervalSince1970)
        bind(try encoder.encode(snapshot), to: stmt, at: 3)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Verlauf konnte nicht gespeichert werden.")) }
        // Pruning per account walks the (account,time) index; batching keeps inserts cheap. A failed prune retries next time.
        let inserts = insertsSincePrune[snapshot.configurationID, default: 0]
        if inserts % 100 == 0 { do { try prune(account: snapshot.configurationID, now: snapshot.observedAt) } catch { return } }
        insertsSincePrune[snapshot.configurationID] = inserts + 1
    }
    private func prune(account: String, now: Date) throws {
        try thin(account: account, before: now.addingTimeInterval(-HistoryRetention.completeSpan))
        let stmt = try statement("DELETE FROM observations WHERE account=?1 AND (time < ?2 OR time < (SELECT time FROM observations WHERE account=?1 ORDER BY time DESC LIMIT 1 OFFSET ?3))")
        defer { sqlite3_finalize(stmt) }
        bind(account, to: stmt, at: 1); sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970 - HistoryRetention.storedSpan)
        sqlite3_bind_int(stmt, 3, Int32(HistoryRetention.maximumRows - 1))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Verlauf konnte nicht gespeichert werden.")) }
    }
    private func thin(account: String, before cutoff: Date) throws {
        let stmt = try statement("SELECT id,time,payload FROM observations WHERE account=? AND time>=? AND time<? ORDER BY time,id")
        bind(account, to: stmt, at: 1); sqlite3_bind_double(stmt, 2, thinnedFrom[account] ?? -.infinity)
        sqlite3_bind_double(stmt, 3, cutoff.timeIntervalSince1970)
        var rows: [(id: Int64, time: Double, snapshot: AccountSnapshot)] = []
        defer { sqlite3_finalize(stmt) }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let v = try? decoder.decode(AccountSnapshot.self, from: data(stmt, 2)) { rows.append((sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1), v)) }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Der lokale Verlauf konnte nicht gelesen werden.")) }
        let redundant = HistoryRetention.redundant(rows.map(\.snapshot), before: cutoff)
        if !redundant.isEmpty { try execute("DELETE FROM observations WHERE id IN (\(redundant.map { String(rows[$0].id) }.joined(separator: ",")))") }
        let dropped = Set(redundant), kept = rows.indices.filter { !dropped.contains($0) }
        if kept.count >= 2 { thinnedFrom[account] = rows[kept[kept.count - 2]].time }
    }
    public func history(account: String, since: Date = .distantPast, limit: Int = 2000) throws -> [AccountSnapshot] {
        let stmt = try statement("SELECT payload FROM observations WHERE account=? AND time>=? ORDER BY time DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        bind(account, to: stmt, at: 1); sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(max(1, min(limit, HistoryRetention.maximumRows))))
        var result: [AccountSnapshot] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let v = try? decoder.decode(AccountSnapshot.self, from: data(stmt, 0)) { result.append(v) }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Der lokale Verlauf konnte nicht gelesen werden.")) }
        return result.reversed()
    }
    public func saveWarning(_ event: WarningEvent) throws {
        let stmt = try statement("INSERT OR REPLACE INTO warnings(id,time,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(event.id, to: stmt, at: 1); sqlite3_bind_double(stmt, 2, event.createdAt.timeIntervalSince1970)
        bind(try encoder.encode(event), to: stmt, at: 3)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Warnzustand konnte nicht gespeichert werden.")) }
        try? execute("DELETE FROM warnings WHERE time < strftime('%s','now') - 15552000")
    }
    public func warnings(limit: Int = 2000) throws -> [WarningEvent] {
        let stmt = try statement("SELECT payload FROM warnings ORDER BY time DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }; sqlite3_bind_int(stmt, 1, Int32(limit))
        var result: [WarningEvent] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let v = try? decoder.decode(WarningEvent.self, from: data(stmt, 0)) { result.append(v) }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Der lokale Verlauf konnte nicht gelesen werden.")) }
        return result
    }
    private func payload(key: String) throws -> Data? {
        let stmt = try statement("SELECT payload FROM preferences WHERE id=?")
        defer { sqlite3_finalize(stmt) }; bind(key, to: stmt, at: 1)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        // BUSY or IOERR says nothing about the stored value, so it must not lock or offer a reset.
        guard status == SQLITE_ROW else { throw ProviderFailure.unavailable(tr("Einstellung konnte nicht gelesen werden: {0}", key)) }
        return data(stmt, 0)
    }
    public func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let payload = try payload(key: key) else { return nil }
        do { return try decoder.decode(type, from: payload) }
        catch {
            unreadablePreferences.insert(key)
            throw ProviderFailure.invalidData(tr("Gespeicherte Einstellung ist nicht lesbar: {0}. Die Originaldaten bleiben erhalten.", key))
        }
    }
    public var unreadablePreferenceKeys: Set<String> { unreadablePreferences }
    /// Derived caches are rebuilt by the next import, so an outdated format is discarded instead of locked.
    public func readCache<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try payload(key: key).flatMap { try? decoder.decode(type, from: $0) }
    }

    /// Explicit recovery preserves the exact original blobs in the same transaction.
    @discardableResult
    public func recoverUnreadablePreferences() throws -> Set<String> {
        let keys = unreadablePreferences
        guard !keys.isEmpty else { return [] }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE IF NOT EXISTS preference_recovery (id INTEGER PRIMARY KEY, preference TEXT NOT NULL, time REAL NOT NULL, payload BLOB NOT NULL)")
            for key in keys.sorted() {
                let backup = try statement("INSERT INTO preference_recovery(preference,time,payload) SELECT id,strftime('%s','now'),payload FROM preferences WHERE id=?")
                bind(key, to: backup, at: 1)
                let status = sqlite3_step(backup)
                sqlite3_finalize(backup)
                guard status == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Originaldaten konnten nicht gesichert werden.")) }
                let removal = try statement("DELETE FROM preferences WHERE id=?")
                bind(key, to: removal, at: 1)
                let removed = sqlite3_step(removal)
                sqlite3_finalize(removal)
                guard removed == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Einstellung konnte nicht zurückgesetzt werden.")) }
            }
            try execute("COMMIT")
            unreadablePreferences.subtract(keys)
            return keys
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func requireWritablePreference(_ key: String) throws {
        guard !unreadablePreferences.contains(key) else {
            throw ProviderFailure.invalidData(tr("Einstellung {0} ist zum Schutz der Originaldaten gesperrt. Mit „Beschädigte Einstellungen zurücksetzen“ können Sie fortfahren.", key))
        }
    }
    public func write<T: Encodable>(_ value: T, key: String) throws {
        try requireWritablePreference(key)
        let stmt = try statement("INSERT OR REPLACE INTO preferences(id,payload) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }; bind(key, to: stmt, at: 1); bind(try encoder.encode(value), to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Einstellung konnte nicht gespeichert werden.")) }
    }
    /// Commits related preferences and history together. The hook runs only after all SQL writes
    /// succeed, allowing the caller to compensate an external credential change if COMMIT fails.
    public func saveAccounts(_ accounts: [AccountConfiguration], clearingHistoryFor id: String? = nil,
                             beforeCommit: () throws -> Void = {}) throws {
        try transaction {
            try write(accounts, key: "accounts")
            if let id { try deleteHistory(id) }
            try beforeCommit()
        }
        if let id { thinnedFrom[id] = nil; insertsSincePrune[id] = nil }
    }

    public func deleteAccount<Resets: Encodable>(_ id: String, accounts: [AccountConfiguration], manualResets: Resets,
                                                 beforeCommit: () throws -> Void = {}) throws {
        try transaction {
            try write(accounts, key: "accounts")
            try write(manualResets, key: "manual-resets")
            try deleteHistory(id)
            try beforeCommit()
        }
        thinnedFrom[id] = nil; insertsSincePrune[id] = nil
    }

    private func transaction(_ changes: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try changes()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func removeAccount(_ id: String) throws {
        try deleteHistory(id)
        thinnedFrom[id] = nil; insertsSincePrune[id] = nil
    }
    private func deleteHistory(_ id: String) throws {
        let stmt = try statement("DELETE FROM observations WHERE account=?")
        defer { sqlite3_finalize(stmt) }; bind(id, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable(tr("Verlauf konnte nicht entfernt werden.")) }
    }
}
