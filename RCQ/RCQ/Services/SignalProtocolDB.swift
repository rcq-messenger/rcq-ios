import Foundation
import SQLite3

/// SQLite wrapper for libsignal protocol stores. File lives in the App Group
/// container so the NSE can write back ratchet state from push decrypts.
///
/// ## Per-account layout (v0.3+)
///
/// libsignal stores (identity, prekeys, sessions, sender keys) are
/// per-account: a device with two accounts on the same backend has
/// two completely separate libsignal identities, prekey pools and
/// session ratchets. Without isolation, registering a second account
/// would overwrite the first account's identity row in
/// `local_identity`, leaking the new account's libsignal material
/// into the old account's slot and breaking v=2 decryption for the
/// original account.
///
/// File layout:
///   `<AppGroup.signalStoreURL>/<accountUUID>/signal-stores.sqlite`
///
/// Path resolution reads `AppGroup.readActiveAccountID()` — the same
/// flat file the per-account Keychain prefix and per-account
/// MessageDB use, written by `AccountManager` whenever active
/// changes. Pre-onboarding installs (no active account yet) fall
/// back to the legacy unprefixed path so the very first registration
/// has somewhere to write to; `AccountManager.migrateLegacyIfPresent`
/// then moves that file under the freshly-minted Account[0]'s
/// directory on next launch.
final class SignalProtocolDB: @unchecked Sendable {
    static let shared = SignalProtocolDB()

    var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.rcq.signal.db")
    private var dbURL: URL

    private init() {
        let url = Self.currentDBURL()
        self.dbURL = url
        Self.openConnection(at: url, into: &db)
    }

    deinit {
        if let db = db { sqlite3_close_v2(db) }
    }

    /// Close the current SQLite handle and re-open against whatever
    /// per-account path the App Group activeAccountID file currently
    /// points at. Called by `AppState.rebootForActiveAccount` after
    /// an account switch — the new active account has its own
    /// libsignal stores in a separate file, so this is what swaps
    /// the in-memory handle over to read/write the new one.
    ///
    /// Runs synchronously on the SQLite queue so any in-flight
    /// libsignal read/write completes against the old handle before
    /// the swap.
    func reload() {
        queue.sync {
            if let db = db { sqlite3_close_v2(db) }
            self.db = nil
            let url = Self.currentDBURL()
            self.dbURL = url
            Self.openConnection(at: url, into: &db)
        }
    }

    // MARK: - file paths

    /// Resolve the SQLite path for whichever account is currently
    /// active. Pre-onboarding (no active account yet) falls through
    /// to the legacy unprefixed path under the App Group root.
    /// Per-account paths nest under a per-account directory so the
    /// directory itself can be wiped wholesale to remove an account.
    private static func currentDBURL() -> URL {
        if let accountID = AppGroup.readActiveAccountID() {
            let dir = AppGroup.signalStoreURL
                .appendingPathComponent(accountID.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            return dir.appendingPathComponent("signal-stores.sqlite")
        }
        return AppGroup.signalStoreURL.appendingPathComponent("signal-stores.sqlite")
    }

    private static func openConnection(at url: URL, into handle: inout OpaquePointer?) {
        var local: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &local, flags, nil) == SQLITE_OK {
            handle = local
            // WAL for concurrent read/write between main app and NSE.
            _ = sqlite3_exec(local, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            _ = sqlite3_exec(local, "PRAGMA foreign_keys=ON;", nil, nil, nil)
            createSchema(on: local)
        } else {
            print("[SignalProtocolDB] open failed: \(url.path)")
        }
    }

    /// One-shot migration of the legacy pre-v0.3 stores file under
    /// the OLDEST account's per-account directory. Called by
    /// `AccountManager` from its init after the roster is loaded
    /// and the active-account-id App Group file is written.
    ///
    /// Only migrates when EXACTLY one account is in the roster. With
    /// two or more accounts the legacy stores file is unreliable —
    /// the most recent `/auth/register` from a second account
    /// overwrote `local_identity` and possibly other rows, so the
    /// data no longer maps cleanly to any one account. In that case
    /// we leave the legacy file orphan and every account starts
    /// with a fresh empty store; `SignalIdentityBootstrap` will
    /// detect missing local_identity on next bootstrap and
    /// re-register libsignal material per-account.
    static func migrateLegacyIfPresent(oldestAccountID: UUID, accountCount: Int) {
        guard accountCount == 1 else { return }
        let legacyURL = AppGroup.signalStoreURL.appendingPathComponent("signal-stores.sqlite")
        let perAccountDir = AppGroup.signalStoreURL
            .appendingPathComponent(oldestAccountID.uuidString, isDirectory: true)
        let perAccountURL = perAccountDir.appendingPathComponent("signal-stores.sqlite")

        guard !FileManager.default.fileExists(atPath: perAccountURL.path),
              FileManager.default.fileExists(atPath: legacyURL.path)
        else { return }

        try? FileManager.default.createDirectory(at: perAccountDir, withIntermediateDirectories: true)
        // Move main file + WAL/SHM sidecars. Each move is atomic per
        // file; a half-completed migration where only the main file
        // moved still works because SQLite recreates missing
        // sidecars on next open.
        for suffix in ["", "-wal", "-shm"] {
            let from = AppGroup.signalStoreURL.appendingPathComponent("signal-stores.sqlite" + suffix)
            let to = perAccountDir.appendingPathComponent("signal-stores.sqlite" + suffix)
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// Delete the entire libsignal store directory for a given
    /// account. Used by burn-account flows in S3+ to leave no
    /// libsignal residue when a second account is removed.
    static func wipeFiles(accountID: UUID) {
        let dir = AppGroup.signalStoreURL
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Static so it can run against either the instance's
    /// stored `db` handle or any other handle (used during the
    /// reopen path in `openConnection`).
    private static func createSchema(on db: OpaquePointer?) {
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

    func sync<T>(_ block: () throws -> T) rethrows -> T {
        return try queue.sync(execute: block)
    }

    // MARK: - low-level prepared-statement helpers

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

    func selectInt(sql: String, bind: (OpaquePointer) -> Void) -> Int64? {
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    @discardableResult
    func execute(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return false }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// SQLITE_TRANSIENT: sqlite copies the buffer immediately.
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
