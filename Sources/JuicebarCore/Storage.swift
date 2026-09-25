import Foundation
import CSQLite

/// All access is serialized by the owning store. Contains metadata only, never credentials or transcripts.
public final class HistoryDatabase {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(path: String) throws {
        if sqlite3_open(path, &database) != SQLITE_OK { throw ProviderFailure.unavailable("Der lokale Verlauf konnte nicht geöffnet werden.") }
        sqlite3_busy_timeout(database, 100)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS observations (id INTEGER PRIMARY KEY, account TEXT NOT NULL, time REAL NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS observation_account_time ON observations(account,time); CREATE TABLE IF NOT EXISTS warnings (id TEXT PRIMARY KEY, time REAL NOT NULL, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS preferences (id TEXT PRIMARY KEY, payload BLOB NOT NULL);")
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ProviderFailure.unavailable("Der lokale Verlauf ist momentan nicht verfügbar.") }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ProviderFailure.unavailable("Der lokale Verlauf konnte nicht gelesen werden.") }
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
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable("Verlauf konnte nicht gespeichert werden.") }
        try execute("DELETE FROM observations WHERE id NOT IN (SELECT id FROM observations ORDER BY time DESC LIMIT 12000); DELETE FROM warnings WHERE time < strftime('%s','now') - 15552000;")
    }
    public func history(account: String, since: Date = .distantPast, limit: Int = 2000) throws -> [AccountSnapshot] {
        let stmt = try statement("SELECT payload FROM observations WHERE account=? AND time>=? ORDER BY time DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        bind(account, to: stmt, at: 1); sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(max(1, min(limit, 12000))))
        var result: [AccountSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let v = try? decoder.decode(AccountSnapshot.self, from: data(stmt, 0)) { result.append(v) } }
        return result.reversed()
    }
    public func saveWarning(_ event: WarningEvent) throws {
        let stmt = try statement("INSERT OR REPLACE INTO warnings(id,time,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(event.id, to: stmt, at: 1); sqlite3_bind_double(stmt, 2, event.createdAt.timeIntervalSince1970)
        bind(try encoder.encode(event), to: stmt, at: 3)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable("Warnzustand konnte nicht gespeichert werden.") }
    }
    public func warnings(limit: Int = 2000) throws -> [WarningEvent] {
        let stmt = try statement("SELECT payload FROM warnings ORDER BY time DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }; sqlite3_bind_int(stmt, 1, Int32(limit))
        var result: [WarningEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let v = try? decoder.decode(WarningEvent.self, from: data(stmt, 0)) { result.append(v) } }
        return result
    }
    public func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        let stmt = try statement("SELECT payload FROM preferences WHERE id=?")
        defer { sqlite3_finalize(stmt) }; bind(key, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return try decoder.decode(type, from: data(stmt, 0))
    }
    public func write<T: Encodable>(_ value: T, key: String) throws {
        let stmt = try statement("INSERT OR REPLACE INTO preferences(id,payload) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }; bind(key, to: stmt, at: 1); bind(try encoder.encode(value), to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable("Einstellung konnte nicht gespeichert werden.") }
    }
    public func removeAccount(_ id: String) throws {
        let stmt = try statement("DELETE FROM observations WHERE account=?")
        defer { sqlite3_finalize(stmt) }; bind(id, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ProviderFailure.unavailable("Verlauf konnte nicht entfernt werden.") }
    }
}
