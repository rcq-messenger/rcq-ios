import Foundation
import LibSignalClient

/// Stage 3 bootstrap: makes sure the local libsignal identity, signed
/// pre-key, Kyber pre-key, and a fresh OPK pool are present and the
/// matching public material is uploaded to the backend.
///
/// Idempotent. Called once on every successful auth bootstrap (after
/// register or after token validation), so a Stage 2 user upgrading to
/// Stage 3 just lands here on first launch with the new build, runs
/// the generation+upload exactly once, and returns instantly forever
/// after.
enum SignalIdentityBootstrap {
    /// Pool size we keep on the server. Top-up triggers below ~25.
    static let targetOPKCount = 100
    static let topUpThreshold = 25

    /// Call this from `AuthService.bootstrapIfNeeded` once `ownUIN` is
    /// known and `APIClient` has a token. Throws if generation or
    /// upload fails so the caller can surface "Stage 3 not ready"
    /// state — encrypt path will then pick the v=1 fallback per peer
    /// instead.
    static func ensureBootstrapped(ownUIN: Int) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared

        if let existing = try stores.loadLocalIdentity() {
            // Sanity: if the saved UIN drifted (e.g. local DB survived
            // a server-side wipe + re-register), throw out the stale
            // libsignal state and rebootstrap. Better to rotate keys
            // than ship with mismatched UIN.
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

        // 1. Identity + registrationId. registrationId is a 14-bit value
        // libsignal uses to disambiguate co-existing devices behind one
        // identity; we run single-device today but pick a fresh one
        // anyway so a future multi-device split is mechanical.
        let identity = IdentityKeyPair.generate()
        let registrationId = UInt32.random(in: 1...16380)
        stores.storeLocalIdentity(uin: ownUIN, identityKeyPair: identity, registrationId: registrationId)

        // 2. Signed pre-key. Rotation cadence isn't enforced yet; for
        // now bootstrap-once-and-forget. Future polish: rotate every
        // ~7 days from a launch hook.
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

        // 3. Kyber pre-key. Single rotating "last-resort" key; reuse
        // is acceptable per PQXDH design (FS comes from EC ephemeral).
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

        // 4. OPK pool — one-time EC pre-keys consumed at X3DH
        // initiation. We also stash the public halves so the upload
        // payload doesn't need to deserialize records we just made.
        struct LocalOPK { let id: UInt32; let pub: String }
        var opks: [LocalOPK] = []
        for _ in 0..<targetOPKCount {
            let id = UInt32.random(in: 1...0x7FFFFFFF)
            let priv = PrivateKey.generate()
            let record = try PreKeyRecord(id: id, privateKey: priv)
            try stores.storePreKey(record, id: id, context: ctx)
            opks.append(LocalOPK(id: id, pub: priv.publicKey.serialize().base64EncodedString()))
        }

        // 5. Upload the bundle. Backend overwrites prior libsignal
        // material atomically — see /keys/bundle.
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

    /// Called on every successful re-auth. Pings the server's pool
    /// status and replenishes if low. Fails silently — this is a
    /// best-effort top-up, real bootstrap already happened.
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
                // Server forgot us (db wipe). Force a fresh bootstrap
                // by clearing the local stores and recursing. Cheap —
                // generate cost is sub-second.
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
