import Foundation
import SQLite3

/// Derived cache over the sidecars. Safe to delete; `rebuild(from:)` restores it.
public final class LibraryIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    private static let schemaVersion = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw LibraryIndexError.cannotOpen(url.path)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS recordings (
                signature TEXT PRIMARY KEY,
                device_filename TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                length_bytes INTEGER NOT NULL,
                duration_seconds REAL,
                recorded_at REAL,
                synced_at REAL NOT NULL,
                device_serial TEXT NOT NULL,
                device_model TEXT NOT NULL,
                timezone TEXT NOT NULL
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_recorded_at ON recordings(recorded_at DESC);")
        try execute("PRAGMA user_version = \(Self.schemaVersion);")
    }

    public func contains(signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT 1 FROM recordings WHERE signature = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func upsert(_ s: Sidecar) throws {
        lock.lock(); defer { lock.unlock() }
        try upsertLocked(s)
    }

    /// Caller must already hold `lock`.
    private func upsertLocked(_ s: Sidecar) throws {
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO recordings
              (signature, device_filename, relative_path, length_bytes, duration_seconds,
               recorded_at, synced_at, device_serial, device_model, timezone)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(signature) DO UPDATE SET
              device_filename=excluded.device_filename,
              relative_path=excluded.relative_path,
              length_bytes=excluded.length_bytes,
              duration_seconds=excluded.duration_seconds,
              recorded_at=excluded.recorded_at,
              synced_at=excluded.synced_at,
              device_serial=excluded.device_serial,
              device_model=excluded.device_model,
              timezone=excluded.timezone;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryIndexError.prepareFailed(lastMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, s.signature, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, s.deviceFilename, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, s.relativePath, -1, Self.transient)
        sqlite3_bind_int64(stmt, 4, Int64(s.lengthBytes))
        if let d = s.durationSeconds { sqlite3_bind_double(stmt, 5, d) } else { sqlite3_bind_null(stmt, 5) }
        if let r = s.recordedAt { sqlite3_bind_double(stmt, 6, r.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_double(stmt, 7, s.syncedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 8, s.deviceSerial, -1, Self.transient)
        sqlite3_bind_text(stmt, 9, s.deviceModel, -1, Self.transient)
        sqlite3_bind_text(stmt, 10, s.timeZoneIdentifier, -1, Self.transient)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LibraryIndexError.writeFailed(lastMessage())
        }
    }

    public func recent(limit: Int) throws -> [Sidecar] {
        // Bound and bound: a negative limit means UNLIMITED in SQLite, so an
        // interpolated -1 would quietly return the whole library.
        try query("SELECT * FROM recordings ORDER BY recorded_at DESC LIMIT ?;",
                  limit: max(0, limit))
    }

    public func all() throws -> [Sidecar] {
        try query("SELECT * FROM recordings ORDER BY recorded_at DESC;")
    }

    /// Holds the lock for the WHOLE call, inside one transaction.
    ///
    /// Dropping the lock between the DELETE and the re-inserts would let a
    /// concurrent `contains(signature:)` observe an empty table and report
    /// not-synced, which makes SyncEngine re-download files already on disk.
    /// The transaction also collapses one implicit commit per row.
    public func rebuild(from sidecars: [Sidecar]) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw LibraryIndexError.writeFailed(lastMessage())
        }
        do {
            guard sqlite3_exec(db, "DELETE FROM recordings;", nil, nil, nil) == SQLITE_OK else {
                throw LibraryIndexError.writeFailed(lastMessage())
            }
            for s in sidecars { try upsertLocked(s) }
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw LibraryIndexError.writeFailed(lastMessage())
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func query(_ sql: String, limit: Int? = nil) throws -> [Sidecar] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryIndexError.prepareFailed(lastMessage())
        }
        defer { sqlite3_finalize(stmt) }
        if let limit { sqlite3_bind_int(stmt, 1, Int32(clamping: limit)) }

        var out: [Sidecar] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let c = sqlite3_column_text(stmt, i) else { return "" }
                return String(cString: c)
            }
            func optionalDouble(_ i: Int32) -> Double? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
            }
            out.append(Sidecar(
                signature: text(0),
                deviceFilename: text(1),
                relativePath: text(2),
                lengthBytes: Int(sqlite3_column_int64(stmt, 3)),
                durationSeconds: optionalDouble(4),
                recordedAt: optionalDouble(5).map(Date.init(timeIntervalSince1970:)),
                syncedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                deviceSerial: text(7),
                deviceModel: text(8),
                timeZoneIdentifier: text(9)))
        }
        return out
    }

    private func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LibraryIndexError.writeFailed(lastMessage())
        }
    }

    private func lastMessage() -> String {
        guard let c = sqlite3_errmsg(db) else { return "unknown sqlite error" }
        return String(cString: c)
    }
}

public enum LibraryIndexError: Error {
    case cannotOpen(String)
    case prepareFailed(String)
    case writeFailed(String)
}
