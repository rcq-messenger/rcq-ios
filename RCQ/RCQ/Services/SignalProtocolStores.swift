import Foundation
import LibSignalClient
import SQLite3

/// Implementation of libsignal's protocol-store interfaces against
/// `SignalProtocolDB`. All instances are stateless wrappers — every
/// call hits SQLite. Acceptable: typical message volume is single
/// digits per second, SQLite handles that with margin.
///
/// Ownership: the main app and the NSE each construct their own
/// instance of `SignalProtocolStores` at startup, but they share the
/// underlying SQLite file via the App Group container. WAL journal
/// mode keeps cross-process readers from blocking on writers.
///
/// Thread-safety: each individual operation locks `SignalProtocolDB`'s
/// serial queue, so concurrent callers are serialized at the DB layer.
/// The libsignal Swift bindings call our protocol methods
/// synchronously from inside `signalEncrypt` / `signalDecryptPreKey`
/// etc., so this is fine.
final class SignalProtocolStores: @unchecked Sendable {
    static let shared = SignalProtocolStores()

    private let db = SignalProtocolDB.shared

    private init() {}

    /// Local UIN, loaded from the singleton `local_identity` row. Nil
    /// when the identity hasn't been bootstrapped yet (pre-Stage-3
    /// account, or fresh install). Callers gate on this.
    var localUIN: Int? {
        return db.sync {
            guard let raw = db.selectInt(sql: "SELECT uin FROM local_identity WHERE id = 1;", bind: { _ in })
            else { return nil }
            return Int(raw)
        }
    }

    /// `(name, deviceId=1)` ProtocolAddress for the local user. Used
    /// as the `localAddress` argument to encrypt/decrypt. Nil when the
    /// identity hasn't been bootstrapped yet.
    func localAddress() throws -> ProtocolAddress {
        guard let uin = localUIN else {
            throw SignalProtocolStoreError.noLocalIdentity
        }
        return try ProtocolAddress(name: String(uin), deviceId: 1)
    }

    /// Set the singleton local identity row. Called from the bootstrap
    /// flow after generating a fresh IdentityKeyPair and registrationId.
    /// Wipes any prior row — a re-bootstrap nukes existing sessions
    /// implicitly via SignalProtocolDB.wipe() (called by AppState before
    /// re-bootstrap).
    func storeLocalIdentity(uin: Int, identityKeyPair: IdentityKeyPair, registrationId: UInt32) {
        db.sync {
            _ = db.execute(
                sql: "DELETE FROM local_identity;",
                bind: { _ in }
            )
            let serialized = identityKeyPair.serialize()
            _ = db.execute(
                sql: "INSERT INTO local_identity (id, uin, identity_keypair, registration_id) VALUES (1, ?, ?, ?);",
                bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(uin))
                    self.db.bindBlob(stmt, 2, serialized)
                    sqlite3_bind_int64(stmt, 3, Int64(registrationId))
                }
            )
        }
    }

    /// Read the local identity. Returns nil if not bootstrapped yet.
    func loadLocalIdentity() throws -> (uin: Int, identityKeyPair: IdentityKeyPair, registrationId: UInt32)? {
        return try db.sync {
            var found: (uin: Int, kp: Data, regId: UInt32)?
            var stmt: OpaquePointer?
            let sql = "SELECT uin, identity_keypair, registration_id FROM local_identity WHERE id = 1;"
            guard sqlite3_prepare_v2(db.db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let uin = Int(sqlite3_column_int64(stmt, 0))
                guard let bytes = sqlite3_column_blob(stmt, 1) else { return nil }
                let len = Int(sqlite3_column_bytes(stmt, 1))
                let kp = Data(bytes: bytes, count: len)
                let regId = UInt32(sqlite3_column_int64(stmt, 2))
                found = (uin, kp, regId)
            }
            guard let f = found else { return nil }
            let identity = try IdentityKeyPair(bytes: f.kp)
            return (f.uin, identity, f.regId)
        }
    }
}

enum SignalProtocolStoreError: Error, LocalizedError {
    case noLocalIdentity
    case missingPreKey(UInt32)
    case missingSignedPreKey(UInt32)
    case missingKyberPreKey(UInt32)

    var errorDescription: String? {
        switch self {
        case .noLocalIdentity:               return "no local libsignal identity (not bootstrapped)"
        case .missingPreKey(let id):         return "no pre-key id=\(id)"
        case .missingSignedPreKey(let id):   return "no signed pre-key id=\(id)"
        case .missingKyberPreKey(let id):    return "no kyber pre-key id=\(id)"
        }
    }
}

// MARK: - StoreContext

/// libsignal threads a `StoreContext` through every store callback so
/// they can share state (e.g. a transactional handle) within one
/// encrypt/decrypt call. We don't need per-call state — every method
/// is independently atomic via the shared SQLite queue — so a single
/// shared singleton suffices.
final class RCQStoreContext: StoreContext, @unchecked Sendable {
    static let shared = RCQStoreContext()
    private init() {}
}

// MARK: - IdentityKeyStore

extension SignalProtocolStores: IdentityKeyStore {
    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        guard let row = try loadLocalIdentity() else {
            throw SignalProtocolStoreError.noLocalIdentity
        }
        return row.identityKeyPair
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        guard let row = try loadLocalIdentity() else {
            throw SignalProtocolStoreError.noLocalIdentity
        }
        return row.registrationId
    }

    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let key = addressKey(address)
        return db.sync {
            let existing = db.selectBlob(
                sql: "SELECT identity_key FROM identities WHERE address = ?;",
                bind: { stmt in self.db.bindText(stmt, 1, key) }
            )
            let serialized = identity.publicKey.serialize()
            _ = db.execute(
                sql: """
                INSERT INTO identities (address, identity_key) VALUES (?, ?)
                ON CONFLICT(address) DO UPDATE SET identity_key = excluded.identity_key;
                """,
                bind: { stmt in
                    self.db.bindText(stmt, 1, key)
                    self.db.bindBlob(stmt, 2, serialized)
                }
            )
            if let existing, existing != serialized {
                return IdentityChange.replacedExisting
            }
            return IdentityChange.newOrUnchanged
        }
    }

    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        // Trust-on-first-use AND accept identity rotations. The
        // previous version refused decryption when a peer's identity
        // changed (re-register, account burn, fresh install + new
        // keys), which silently dropped every message until both
        // sides reset state. That's brutal UX in early-beta where
        // accounts churn often, and even in steady-state the only
        // safer alternative — out-of-band verification (safety
        // numbers / QR confirm) — isn't built yet.
        //
        // Returning `true` unconditionally tells libsignal to accept
        // the new identity and call `saveIdentity` to overwrite the
        // cached one. Same posture Signal calls "TOFU + warn"; until
        // we have the warn UI we just trust silently. Revisit when
        // we add safety numbers and a "verify peer" affordance.
        return true
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        let key = addressKey(address)
        let blob: Data? = db.sync {
            db.selectBlob(
                sql: "SELECT identity_key FROM identities WHERE address = ?;",
                bind: { stmt in self.db.bindText(stmt, 1, key) }
            )
        }
        guard let blob else { return nil }
        return try IdentityKey(bytes: blob)
    }

    private func addressKey(_ address: ProtocolAddress) -> String {
        return "\(address.name):\(address.deviceId)"
    }
}

// MARK: - PreKeyStore

extension SignalProtocolStores: PreKeyStore {
    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        let blob: Data? = db.sync {
            db.selectBlob(
                sql: "SELECT record FROM prekeys WHERE prekey_id = ?;",
                bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(id)) }
            )
        }
        guard let blob else { throw SignalProtocolStoreError.missingPreKey(id) }
        return try PreKeyRecord(bytes: blob)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        let serialized = record.serialize()
        db.sync {
            _ = db.execute(
                sql: """
                INSERT INTO prekeys (prekey_id, record) VALUES (?, ?)
                ON CONFLICT(prekey_id) DO UPDATE SET record = excluded.record;
                """,
                bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(id))
                    self.db.bindBlob(stmt, 2, serialized)
                }
            )
        }
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        db.sync {
            _ = db.execute(
                sql: "DELETE FROM prekeys WHERE prekey_id = ?;",
                bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(id)) }
            )
        }
    }
}

// MARK: - SignedPreKeyStore

extension SignalProtocolStores: SignedPreKeyStore {
    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        let blob: Data? = db.sync {
            db.selectBlob(
                sql: "SELECT record FROM signed_prekeys WHERE signed_prekey_id = ?;",
                bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(id)) }
            )
        }
        guard let blob else { throw SignalProtocolStoreError.missingSignedPreKey(id) }
        return try SignedPreKeyRecord(bytes: blob)
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        let serialized = record.serialize()
        db.sync {
            _ = db.execute(
                sql: """
                INSERT INTO signed_prekeys (signed_prekey_id, record) VALUES (?, ?)
                ON CONFLICT(signed_prekey_id) DO UPDATE SET record = excluded.record;
                """,
                bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(id))
                    self.db.bindBlob(stmt, 2, serialized)
                }
            )
        }
    }
}

// MARK: - KyberPreKeyStore

extension SignalProtocolStores: KyberPreKeyStore {
    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        let blob: Data? = db.sync {
            db.selectBlob(
                sql: "SELECT record FROM kyber_prekeys WHERE kyber_prekey_id = ?;",
                bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(id)) }
            )
        }
        guard let blob else { throw SignalProtocolStoreError.missingKyberPreKey(id) }
        return try KyberPreKeyRecord(bytes: blob)
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        let serialized = record.serialize()
        db.sync {
            _ = db.execute(
                sql: """
                INSERT INTO kyber_prekeys (kyber_prekey_id, record) VALUES (?, ?)
                ON CONFLICT(kyber_prekey_id) DO UPDATE SET record = excluded.record;
                """,
                bind: { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(id))
                    self.db.bindBlob(stmt, 2, serialized)
                }
            )
        }
    }

    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        // No-op. We ship a single rotating "last-resort" Kyber pre-key
        // that's intentionally reusable; per-message use-tracking would
        // immediately exhaust the pool. Rotation happens when the
        // bootstrap flow uploads a fresh bundle.
    }
}

// MARK: - SessionStore

extension SignalProtocolStores: SessionStore {
    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        let key = addressKey(address)
        let blob: Data? = db.sync {
            db.selectBlob(
                sql: "SELECT record FROM sessions WHERE address = ?;",
                bind: { stmt in self.db.bindText(stmt, 1, key) }
            )
        }
        guard let blob else { return nil }
        return try SessionRecord(bytes: blob)
    }

    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        return try addresses.compactMap { try loadSession(for: $0, context: context) }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        let key = addressKey(address)
        let serialized = record.serialize()
        db.sync {
            _ = db.execute(
                sql: """
                INSERT INTO sessions (address, record) VALUES (?, ?)
                ON CONFLICT(address) DO UPDATE SET record = excluded.record;
                """,
                bind: { stmt in
                    self.db.bindText(stmt, 1, key)
                    self.db.bindBlob(stmt, 2, serialized)
                }
            )
        }
    }

    /// Drop the libsignal session for one address. Used as a recovery
    /// hook when decryption fails with a permanent error such as
    /// `missingSignedPreKey` — the session is referencing a prekey
    /// the recipient no longer has, so the chain can't advance.
    /// Clearing the row forces the next inbound `PreKeySignalMessage`
    /// from this peer to start a fresh session against the
    /// recipient's CURRENT prekey bundle.
    func deleteSession(for address: ProtocolAddress) {
        let key = addressKey(address)
        db.sync {
            _ = db.execute(
                sql: "DELETE FROM sessions WHERE address = ?;",
                bind: { stmt in self.db.bindText(stmt, 1, key) }
            )
        }
    }
}

// MARK: - SenderKeyStore

extension SignalProtocolStores: SenderKeyStore {
    func storeSenderKey(from sender: ProtocolAddress, distributionId: UUID, record: SenderKeyRecord, context: StoreContext) throws {
        let key = addressKey(sender)
        let did = uuidBytes(distributionId)
        let serialized = record.serialize()
        db.sync {
            _ = db.execute(
                sql: """
                INSERT INTO sender_keys (sender_address, distribution_id, record) VALUES (?, ?, ?)
                ON CONFLICT(sender_address, distribution_id) DO UPDATE SET record = excluded.record;
                """,
                bind: { stmt in
                    self.db.bindText(stmt, 1, key)
                    self.db.bindBlob(stmt, 2, did)
                    self.db.bindBlob(stmt, 3, serialized)
                }
            )
        }
    }

    func loadSenderKey(from sender: ProtocolAddress, distributionId: UUID, context: StoreContext) throws -> SenderKeyRecord? {
        let key = addressKey(sender)
        let did = uuidBytes(distributionId)
        let blob: Data? = db.sync {
            db.selectBlob(
                sql: "SELECT record FROM sender_keys WHERE sender_address = ? AND distribution_id = ?;",
                bind: { stmt in
                    self.db.bindText(stmt, 1, key)
                    self.db.bindBlob(stmt, 2, did)
                }
            )
        }
        guard let blob else { return nil }
        return try SenderKeyRecord(bytes: blob)
    }

    private func uuidBytes(_ uuid: UUID) -> Data {
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}
