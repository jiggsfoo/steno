import Foundation
import SQLite3

/// Derived cache over the sidecars. Safe to delete; `rebuild(from:)` restores it.
public final class LibraryIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    private static let schemaVersion = 2
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// True when THIS open found a schema below current and had `migrate(to:)`
    /// drop and recreate `recordings` — i.e. the table just came back EMPTY.
    /// `AppModel.start()` reads this to know when it must call
    /// `rebuildIndex()` to refill it from sidecars: without that call, any
    /// recording excluded from `pending` (a valid transcript AND a non-nil
    /// `transcribedAt`) is never re-upserted, and stays missing from the
    /// index until someone presses "Rebuild Index" by hand.
    private(set) var didRecreateTable = false

    public convenience init(url: URL) throws {
        try self.init(url: url, schemaVersionOverride: Self.schemaVersion)
    }

    /// `schemaVersionOverride` exists only so tests can build a v1 database and
    /// prove the migration. Production always goes through `init(url:)`.
    init(url: URL, schemaVersionOverride: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            // SQLite allocates a handle even on failure; close it before
            // throwing or it leaks.
            sqlite3_close(db)
            throw LibraryIndexError.cannotOpen(url.path)
        }
        try execute("PRAGMA journal_mode=WAL;")
        didRecreateTable = try migrate(to: schemaVersionOverride)
    }

    deinit { sqlite3_close(db) }

    /// The index is a DERIVED cache, so a schema change does not need an ALTER
    /// path. Dropping and recreating is correct and total; `AppModel` calls
    /// `rebuildIndex()` afterwards and the sidecars refill it -- see
    /// `didRecreateTable`, the return value here, for how it knows to.
    @discardableResult
    private func migrate(to version: Int) throws -> Bool {
        let recreated = currentUserVersion() < version
        if recreated {
            try execute("DROP TABLE IF EXISTS recordings;")
        }
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
                timezone TEXT NOT NULL,
                title TEXT,
                topic TEXT,
                transcribed_at REAL,
                transcript_backend TEXT
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_recorded_at ON recordings(recorded_at DESC);")
        try execute("PRAGMA user_version = \(version);")
        return recreated
    }

    private func currentUserVersion() -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
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
               recorded_at, synced_at, device_serial, device_model, timezone,
               title, topic, transcribed_at, transcript_backend)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(signature) DO UPDATE SET
              device_filename=excluded.device_filename,
              relative_path=excluded.relative_path,
              length_bytes=excluded.length_bytes,
              duration_seconds=excluded.duration_seconds,
              recorded_at=excluded.recorded_at,
              synced_at=excluded.synced_at,
              device_serial=excluded.device_serial,
              device_model=excluded.device_model,
              timezone=excluded.timezone,
              title=excluded.title,
              topic=excluded.topic,
              transcribed_at=excluded.transcribed_at,
              transcript_backend=excluded.transcript_backend;
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
        if let t = s.title { sqlite3_bind_text(stmt, 11, t, -1, Self.transient) } else { sqlite3_bind_null(stmt, 11) }
        if let t = s.topic { sqlite3_bind_text(stmt, 12, t, -1, Self.transient) } else { sqlite3_bind_null(stmt, 12) }
        if let d = s.transcribedAt { sqlite3_bind_double(stmt, 13, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 13) }
        if let b = s.transcriptBackend { sqlite3_bind_text(stmt, 14, b, -1, Self.transient) } else { sqlite3_bind_null(stmt, 14) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LibraryIndexError.writeFailed(lastMessage())
        }
    }

    /// The full indexed row for one signature, or nil if none.
    ///
    /// `SyncEngine.isAlreadySynced` uses this to locate a recording by the path
    /// the index actually recorded for it, rather than a freshly recomputed
    /// one — this is what makes `relative_path` load-bearing instead of a
    /// column nothing reads.
    public func record(signature: String) -> Sidecar? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT * FROM recordings WHERE signature = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.decode(stmt)
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
            out.append(Self.decode(stmt))
        }
        return out
    }

    /// Decodes one `recordings` row at the statement's current step. Shared by
    /// `query` and `record(signature:)` so there is exactly one place that
    /// knows the column order.
    private static func decode(_ stmt: OpaquePointer?) -> Sidecar {
        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func optionalDouble(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
        }
        func optionalText(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        return Sidecar(
            signature: text(0),
            deviceFilename: text(1),
            relativePath: text(2),
            lengthBytes: Int(sqlite3_column_int64(stmt, 3)),
            durationSeconds: optionalDouble(4),
            recordedAt: optionalDouble(5).map(Date.init(timeIntervalSince1970:)),
            syncedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            deviceSerial: text(7),
            deviceModel: text(8),
            timeZoneIdentifier: text(9),
            title: optionalText(10),
            topic: optionalText(11),
            transcribedAt: optionalDouble(12).map(Date.init(timeIntervalSince1970:)),
            transcriptBackend: optionalText(13),
            transcriptionAttempts: nil)
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

extension LibraryIndexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return "Your recordings index couldn't be opened."
        case .prepareFailed, .writeFailed:
            return "Your recordings index couldn't be updated."
        }
    }
}
