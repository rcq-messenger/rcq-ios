import Foundation
import LibSignalClient

/// Idempotent Stage 3 bootstrap — ensures local libsignal identity,
/// signed pre-key, Kyber pre-key, and OPK pool exist and the matching
/// public material is uploaded.
enum SignalIdentityBootstrap {
    /// Server-side pool target. Top-up below ~25.
    static let targetOPKCount = 100
    static let topUpThreshold = 25

    /// Throws if generation or upload fails so the caller can surface
    /// "Stage 3 not ready" — encrypt path falls back to v=1 per peer.
    static func ensureBootstrapped(ownUIN: Int) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared

        if let existing = try stores.loadLocalIdentity() {
            // UIN drift (local DB survived server-side wipe + re-register):
            // throw out stale libsignal state and rebootstrap.
            if existing.uin != ownUIN {
                print("[SignalBootstrap] uin drift \(existing.uin)→\(ownUIN), rebootstrapping")
                SignalProtocolDB.shared.wipe()
            } else {
                await topUpIfNeeded()
                return
            }
        }

        try await freshBootstrap(ownUIN: ownUIN, ctx: ctx)
    }

    private static func freshBootstrap(ownUIN: Int, ctx: StoreContext) async throws {
        let stores = SignalProtocolStores.shared

        // 1. Identity + registrationId (14-bit, libsignal device disambiguator).
        let identity = IdentityKeyPair.generate()
        let registrationId = UInt32.random(in: 1...16380)
        stores.storeLocalIdentity(uin: ownUIN, identityKeyPair: identity, registrationId: registrationId)

        // 2. Signed pre-key. TODO: rotate every ~7 days from a launch hook.
        let signedId = UInt32.random(in: 1...0x7FFFFFFF)
        let signedPriv = PrivateKey.generate()
        let signedPubBytes = signedPriv.publicKey.serialize()
        let signedSig = identity.privateKey.generateSignature(message: signedPubBytes)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let signedRecord = try SignedPreKeyRecord(
            id: signedId,
            timestamp: nowMs,
            privateKey: signedPriv,
            signature: signedSig
        )
        try stores.storeSignedPreKey(signedRecord, id: signedId, context: ctx)

        // 3. Kyber pre-key. Reuse is OK per PQXDH (FS comes from EC ephemeral).
        let kyberId = UInt32.random(in: 1...0x7FFFFFFF)
        let kyberKp = KEMKeyPair.generate()
        let kyberPubBytes = kyberKp.publicKey.serialize()
        let kyberSig = identity.privateKey.generateSignature(message: kyberPubBytes)
        let kyberRecord = try KyberPreKeyRecord(
            id: kyberId,
            timestamp: nowMs,
            keyPair: kyberKp,
            signature: kyberSig
        )
        try stores.storeKyberPreKey(kyberRecord, id: kyberId, context: ctx)

        // 4. OPK pool — one-time pre-keys consumed at X3DH initiation.
        struct LocalOPK { let id: UInt32; let pub: String }
        var opks: [LocalOPK] = []
        for _ in 0..<targetOPKCount {
            let id = UInt32.random(in: 1...0x7FFFFFFF)
            let priv = PrivateKey.generate()
            let record = try PreKeyRecord(id: id, privateKey: priv)
            try stores.storePreKey(record, id: id, context: ctx)
            opks.append(LocalOPK(id: id, pub: priv.publicKey.serialize().base64EncodedString()))
        }

        // 5. Upload bundle. Backend overwrites prior material atomically.
        struct SignedPreKeyOut: Encodable { let id: UInt32; let publicKey: String; let signature: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
        }
        struct KyberPreKeyOut: Encodable { let id: UInt32; let publicKey: String; let signature: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
        }
        struct OPKOut: Encodable { let id: UInt32; let publicKey: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public" }
        }
        struct BundleBody: Encodable {
            let signal_identity_key: String
            let registration_id: UInt32
            let signed_prekey: SignedPreKeyOut
            let kyber_prekey: KyberPreKeyOut
            let one_time_prekeys: [OPKOut]
        }

        let identityKeyB64 = identity.publicKey.serialize().base64EncodedString()
        let body = BundleBody(
            signal_identity_key: identityKeyB64,
            registration_id: registrationId,
            signed_prekey: SignedPreKeyOut(
                id: signedId,
                publicKey: signedPubBytes.base64EncodedString(),
                signature: signedSig.base64EncodedString()
            ),
            kyber_prekey: KyberPreKeyOut(
                id: kyberId,
                publicKey: kyberPubBytes.base64EncodedString(),
                signature: kyberSig.base64EncodedString()
            ),
            one_time_prekeys: opks.map { OPKOut(id: $0.id, publicKey: $0.pub) }
        )
        let _: EmptyResponse = try await APIClient.shared.request("POST", "/keys/bundle", body: body)
        print("[SignalBootstrap] uploaded fresh bundle for UIN=\(ownUIN), OPKs=\(opks.count)")
    }

    /// Rotate the libsignal identity in place: mint a brand-new identity + prekey
    /// bundle, upload it (REPLACING the old one), then swap local state to match.
    /// Upload-FIRST so a failed network call leaves the existing (working)
    /// identity untouched instead of desyncing local vs server. Used by account
    /// key re-issue — a new libsignal identity changes our safety number so
    /// contacts get a "safety number changed" warning on their next session.
    static func rebootstrap(ownUIN: Int) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared

        let identity = IdentityKeyPair.generate()
        let registrationId = UInt32.random(in: 1...16380)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let signedId = UInt32.random(in: 1...0x7FFFFFFF)
        let signedPriv = PrivateKey.generate()
        let signedPubBytes = signedPriv.publicKey.serialize()
        let signedSig = identity.privateKey.generateSignature(message: signedPubBytes)

        let kyberId = UInt32.random(in: 1...0x7FFFFFFF)
        let kyberKp = KEMKeyPair.generate()
        let kyberPubBytes = kyberKp.publicKey.serialize()
        let kyberSig = identity.privateKey.generateSignature(message: kyberPubBytes)

        struct GenOPK { let id: UInt32; let priv: PrivateKey }
        var gen: [GenOPK] = []
        for _ in 0..<targetOPKCount {
            gen.append(GenOPK(id: UInt32.random(in: 1...0x7FFFFFFF), priv: PrivateKey.generate()))
        }

        struct SignedPreKeyOut: Encodable { let id: UInt32; let publicKey: String; let signature: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
        }
        struct KyberPreKeyOut: Encodable { let id: UInt32; let publicKey: String; let signature: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
        }
        struct OPKOut: Encodable { let id: UInt32; let publicKey: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public" }
        }
        struct BundleBody: Encodable {
            let signal_identity_key: String
            let registration_id: UInt32
            let signed_prekey: SignedPreKeyOut
            let kyber_prekey: KyberPreKeyOut
            let one_time_prekeys: [OPKOut]
        }

        let body = BundleBody(
            signal_identity_key: identity.publicKey.serialize().base64EncodedString(),
            registration_id: registrationId,
            signed_prekey: SignedPreKeyOut(
                id: signedId,
                publicKey: signedPubBytes.base64EncodedString(),
                signature: signedSig.base64EncodedString()
            ),
            kyber_prekey: KyberPreKeyOut(
                id: kyberId,
                publicKey: kyberPubBytes.base64EncodedString(),
                signature: kyberSig.base64EncodedString()
            ),
            one_time_prekeys: gen.map {
                OPKOut(id: $0.id, publicKey: $0.priv.publicKey.serialize().base64EncodedString())
            }
        )
        // Upload BEFORE touching local state.
        let _: EmptyResponse = try await APIClient.shared.request("POST", "/keys/bundle", body: body)

        // Server accepted the new bundle — swap local libsignal state to match.
        SignalProtocolDB.shared.wipe()
        stores.storeLocalIdentity(uin: ownUIN, identityKeyPair: identity, registrationId: registrationId)
        let signedRecord = try SignedPreKeyRecord(
            id: signedId, timestamp: nowMs, privateKey: signedPriv, signature: signedSig
        )
        try stores.storeSignedPreKey(signedRecord, id: signedId, context: ctx)
        let kyberRecord = try KyberPreKeyRecord(
            id: kyberId, timestamp: nowMs, keyPair: kyberKp, signature: kyberSig
        )
        try stores.storeKyberPreKey(kyberRecord, id: kyberId, context: ctx)
        for o in gen {
            let record = try PreKeyRecord(id: o.id, privateKey: o.priv)
            try stores.storePreKey(record, id: o.id, context: ctx)
        }
        print("[SignalBootstrap] re-issued libsignal identity for UIN=\(ownUIN)")
    }

    private static func topUpIfNeeded() async {
        struct StatusOut: Decodable {
            let has_bundle: Bool
            let one_time_prekey_count: Int
            let target_count: Int
            let signed_prekey_age_seconds: Int?
        }
        do {
            let status: StatusOut = try await APIClient.shared.request("GET", "/keys/me/status")
            if !status.has_bundle {
                // Server forgot us (db wipe) — clear local stores and rebootstrap.
                print("[SignalBootstrap] server has no bundle, re-bootstrapping")
                if let row = try SignalProtocolStores.shared.loadLocalIdentity() {
                    SignalProtocolDB.shared.wipe()
                    try await freshBootstrap(ownUIN: row.uin, ctx: RCQStoreContext.shared)
                }
                return
            }
            if status.one_time_prekey_count < topUpThreshold {
                let needed = max(targetOPKCount - status.one_time_prekey_count, 0)
                try await replenishOPKs(count: needed)
            }
        } catch {
            print("[SignalBootstrap] top-up check failed: \(error)")
        }
    }

    private static func replenishOPKs(count: Int) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        struct OPKOut: Encodable { let id: UInt32; let publicKey: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public" }
        }
        struct Body: Encodable { let one_time_prekeys: [OPKOut] }
        var batch: [OPKOut] = []
        for _ in 0..<count {
            let id = UInt32.random(in: 1...0x7FFFFFFF)
            let priv = PrivateKey.generate()
            let record = try PreKeyRecord(id: id, privateKey: priv)
            try stores.storePreKey(record, id: id, context: ctx)
            batch.append(OPKOut(id: id, publicKey: priv.publicKey.serialize().base64EncodedString()))
        }
        let _: EmptyResponse = try await APIClient.shared.request(
            "POST", "/keys/prekeys", body: Body(one_time_prekeys: batch)
        )
        print("[SignalBootstrap] replenished \(batch.count) OPKs")
    }
}
