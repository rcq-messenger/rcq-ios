import Foundation
import SQLite3

/// SQLite wrapper for the libsignal protocol stores. Single file in the
/// shared App Group container so the NSE can write back any new ratchet
/// state derived while decrypting a push. Tables are simple BLOB
/// key-value: libsignal records serialize themselves and we treat the
/// bytes as opaque.
///
/// Schema layout (all rows are `Data` blobs unless noted):
///
///   local_identity (singleton — id always 1)
///     id                    INTEGER PK
///     uin                   INTEGER
///     identity_keypair      BLOB    (libsignal IdentityKeyPair.serialize)
///     registration_id       INTEGER (libsignal registrationId)
///
///   prekeys             — one-time EC pre-keys
///     prekey_id  INTEGER PK
///     record     BLOB    (PreKeyRecord.serialize)
///
///   signed_prekeys      — rotating signed EC pre-keys
///     signed_prekey_id INTEGER PK
///     record           BLOB (SignedPreKeyRecord.serialize)
///
///   kyber_prekeys       — rotating last-resort Kyber pre-keys
///     kyber_prekey_id INTEGER PK
///     record          BLOB (KyberPreKeyRecord.serialize)
///
///   sessions
///     address  TEXT PK   ("<uin>:<deviceId>")
///     record   BLOB      (SessionRecord.serialize)
///
///   identities          — TOFU table for remote identities
///     address      TEXT PK
///     identity_key BLOB
///
///   sender_keys
///     sender_address  TEXT
///     distribution_id BLOB   (16-byte UUID)
///     record          BLOB
///     PRIMARY KEY (sender_address, distribution_id)
///
/// Concurrency: callers serialize on the dedicated `queue` (a
/// `DispatchQueue` constructed with `attributes: []` so it's serial).
/// libsignal's stores are called synchronously from the encrypt/decrypt
/// helpers, so we don't need async/await plumbing here.
final class SignalProtocolDB: @unchecked Sendable {
    /// Shared instance. Both the main app and the NSE construct on
    /// first access; the SQLite file is the same path in the App Group
    /// container so they're working on one db. SQLite handles
    /// concurrent process opens via its file-locking model.
    static let shared = SignalProtocolDB()

    var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.rcq.signal.db")
    private let dbURL: URL

    private init() {
        self.dbURL = AppGroup.signalStoreURL.appendingPathComponent("signal-stores.sqlite")
        // SQLITE_OPEN_FULLMUTEX so the connection is safe across
        // threads if anyone reaches in outside our queue. Cheap on
        // a low-volume store like this.
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &handle, flags, nil) == SQLITE_OK {
            self.db = handle
            // WAL gives better concurrent read/write between main app
            // and NSE without us having to coordinate manually.
            _ = sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            _ = sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil)
            createSchema()
        } else {
            print("[SignalProtocolDB] open failed: \(dbURL.path)")
        }
    }

    deinit {
        if let db = db { sqlite3_close_v2(db) }
    }

    private func createSchema() {
        let stmts = [
            """
            CREATE TABLE IF NOT EXISTS local_identity (
                id INTEGER PRIMARY KEY,
                uin INTEGER NOT NULL,
                identity_keypair BLOB NOT NULL,
                registration_id INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS prekeys (
                prekey_id INTEGER PRIMARY KEY,
                record BLOB NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS signed_prekeys (
                signed_prekey_id INTEGER PRIMARY KEY,
                record BLOB NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS kyber_prekeys (
                kyber_prekey_id INTEGER PRIMARY KEY,
                record BLOB NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sessions (
                address TEXT PRIMARY KEY,
                record BLOB NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS identities (
                address TEXT PRIMARY KEY,
                identity_key BLOB NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sender_keys (
                sender_address TEXT NOT NULL,
                distribution_id BLOB NOT NULL,
                record BLOB NOT NULL,
                PRIMARY KEY (sender_address, distribution_id)
            );
            """,
        ]
        for sql in stmts {
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    /// Run `block` on the serial queue. Used to wrap multi-statement
    /// operations so a libsignal store callback completes atomically
    /// without another callback racing in.
    func sync<T>(_ block: () throws -> T) rethrows -> T {
        return try queue.sync(execute: block)
    }

    // MARK: - low-level prepared-statement helpers

    /// Run a SELECT-one-row, returning the first column as Data.
    func selectBlob(sql: String, bind: (OpaquePointer) -> Void) -> Data? {
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: bytes, count: length)
    }

    /// Run a SELECT-one-row, returning the first column as Int64.
    func selectInt(sql: String, bind: (OpaquePointer) -> Void) -> Int64? {
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Run an INSERT/UPDATE/DELETE.
    @discardableResult
    func execute(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return false }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// SQLITE_TRANSIENT — sqlite copies the buffer immediately, so the
    /// caller's Data may be released right after `sqlite3_bind_*`.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - convenience accessors

    func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let base = buffer.baseAddress
            sqlite3_bind_blob(stmt, index, base, Int32(buffer.count), Self.transient)
        }
    }

    func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, Self.transient)
    }

    // MARK: - bulk wipes (used by burn-account)

    /// Drop every row from every table. Called from `AppState.burnAccount()`
    /// so a re-registered identity doesn't inherit stale sessions.
    func wipe() {
        sync {
            for table in ["local_identity", "prekeys", "signed_prekeys",
                          "kyber_prekeys", "sessions", "identities",
                          "sender_keys"] {
                _ = sqlite3_exec(db, "DELETE FROM \(table);", nil, nil, nil)
            }
        }
    }
}
