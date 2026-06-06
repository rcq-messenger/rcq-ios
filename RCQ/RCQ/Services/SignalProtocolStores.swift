import Foundation
import LibSignalClient
import SQLite3

/// libsignal protocol-store interfaces backed by `SignalProtocolDB`.
/// Stateless wrapper — every call hits SQLite serialized via the DB queue.
final class SignalProtocolStores: @unchecked Sendable {
    static let shared = SignalProtocolStores()

    private let db = SignalProtocolDB.shared

    private init() {}

    /// Nil when identity hasn't been bootstrapped yet.
    var localUIN: Int? {
        return db.sync {
            guard let raw = db.selectInt(sql: "SELECT uin FROM local_identity WHERE id = 1;", bind: { _ in })
            else { return nil }
            return Int(raw)
        }
    }

    func localAddress() throws -> ProtocolAddress {
        guard let uin = localUIN else {
            throw SignalProtocolStoreError.noLocalIdentity
        }
        return try ProtocolAddress(name: String(uin), deviceId: 1)
    }

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

/// Single shared instance — store methods are independently atomic.
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
                // The peer's pinned identity key changed under a known
                // address: re-register, new device, or a server swapping
                // keys (MITM). Flag it so the contact screen can warn the
                // user to re-verify the safety number; TOFU still accepts
                // it (Signal behaviour — the user is just told). Same
                // process/handle, so we're already inside the db queue.
                _ = db.execute(
                    sql: "INSERT OR IGNORE INTO identity_changes (address) VALUES (?);",
                    bind: { stmt in self.db.bindText(stmt, 1, key) }
                )
                return IdentityChange.replacedExisting
            }
            return IdentityChange.newOrUnchanged
        }
    }

    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        // TOFU + accept rotations; a replaced key is flagged in saveIdentity
        // and surfaced as a re-verify warning rather than blocked.
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

// MARK: - Identity-change flag (safety-number-changed warning)

extension SignalProtocolStores {
    /// True when [uin]'s pinned libsignal identity was REPLACED (re-register,
    /// new device, or a server swapping keys for a MITM) and the user hasn't
    /// re-verified yet. Set in `saveIdentity` when an inbound prekey message
    /// carries a new identity for a known peer; cleared by
    /// `acknowledgePeerIdentity`.
    func peerIdentityChanged(_ uin: Int) -> Bool {
        guard let addr = try? ProtocolAddress(name: String(uin), deviceId: 1) else { return false }
        let key = addressKey(addr)
        return db.sync {
            db.selectInt(
                sql: "SELECT 1 FROM identity_changes WHERE address = ? LIMIT 1;",
                bind: { stmt in self.db.bindText(stmt, 1, key) }
            ) != nil
        }
    }

    /// Clear the change flag for [uin]. Opening the safety number to re-check
    /// counts as acknowledging the change.
    func acknowledgePeerIdentity(_ uin: Int) {
        guard let addr = try? ProtocolAddress(name: String(uin), deviceId: 1) else { return }
        let key = addressKey(addr)
        db.sync {
            _ = db.execute(
                sql: "DELETE FROM identity_changes WHERE address = ?;",
                bind: { stmt in self.db.bindText(stmt, 1, key) }
            )
        }
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
        // No-op: single rotating last-resort Kyber pre-key, reusable.
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

    /// Recovery hook: drop session so peer's next PreKeySignalMessage
    /// starts a fresh session against the current prekey bundle.
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
