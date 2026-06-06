import Foundation
import LibSignalClient

/// Stage 3 session-establishment helpers. Lives in the main-app target
/// only — the NSE has no business fetching pre-key bundles. Decrypt
/// path on the NSE side hits the existing libsignal session in
/// `SignalProtocolStores`; if no session exists yet the message is a
/// `PreKeySignalMessage` which carries enough state to seed one
/// without a server round-trip.
extension SignalCryptoService {
    /// Idempotent X3DH/PQXDH session establishment. Fetches the peer's
    /// pre-key bundle (consuming one OPK on the server) and runs
    /// `processPreKeyBundle` to seed a session in the local
    /// SessionStore. Returns immediately if a session already exists.
    /// Async because of the HTTP fetch — call once before the first
    /// `encryptStage3(...)` to a given peer.
    static func ensureStage3Session(forPeerUIN uin: Int) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        let addr = try ProtocolAddress(name: String(uin), deviceId: 1)
        if let _ = try stores.loadSession(for: addr, context: ctx) {
            return
        }

        struct SignedPreKeyResp: Decodable {
            let id: UInt32
            let publicKey: String
            let signature: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
        }
        struct KyberPreKeyResp: Decodable {
            let id: UInt32
            let publicKey: String
            let signature: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
        }
        struct OPKResp: Decodable {
            let id: UInt32
            let publicKey: String
            enum CodingKeys: String, CodingKey { case id; case publicKey = "public" }
        }
        struct BundleResp: Decodable {
            let uin: Int
            let registration_id: UInt32
            let signal_identity_key: String
            let signed_prekey: SignedPreKeyResp
            let kyber_prekey: KyberPreKeyResp
            let one_time_prekey: OPKResp?
        }

        let resp: BundleResp = try await APIClient.shared.request("GET", "/keys/\(uin)/bundle")
        guard let identityBytes = Data(base64Encoded: resp.signal_identity_key),
              let signedPubBytes = Data(base64Encoded: resp.signed_prekey.publicKey),
              let signedSig      = Data(base64Encoded: resp.signed_prekey.signature),
              let kyberPubBytes  = Data(base64Encoded: resp.kyber_prekey.publicKey),
              let kyberSig       = Data(base64Encoded: resp.kyber_prekey.signature)
        else { throw CryptoError.malformedWire }

        let identityKey = try IdentityKey(bytes: identityBytes)
        let signedPub   = try PublicKey(signedPubBytes)
        let kyberPub    = try KEMPublicKey(kyberPubBytes)

        let bundle: PreKeyBundle
        if let opk = resp.one_time_prekey,
           let opkBytes = Data(base64Encoded: opk.publicKey) {
            let opkPub = try PublicKey(opkBytes)
            bundle = try PreKeyBundle(
                registrationId: resp.registration_id,
                deviceId: 1,
                prekeyId: opk.id,
                prekey: opkPub,
                signedPrekeyId: resp.signed_prekey.id,
                signedPrekey: signedPub,
                signedPrekeySignature: signedSig,
                identity: identityKey,
                kyberPrekeyId: resp.kyber_prekey.id,
                kyberPrekey: kyberPub,
                kyberPrekeySignature: kyberSig
            )
        } else {
            // Pool exhausted on the server side — fall back to a
            // bundle without an OPK. PQXDH still proceeds; we lose
            // a per-session contributory secret. Logged so dev can
            // notice if it's happening a lot (peer needs to top up).
            print("[Stage3] /keys/\(uin)/bundle returned no OPK — proceeding without")
            bundle = try PreKeyBundle(
                registrationId: resp.registration_id,
                deviceId: 1,
                signedPrekeyId: resp.signed_prekey.id,
                signedPrekey: signedPub,
                signedPrekeySignature: signedSig,
                identity: identityKey,
                kyberPrekeyId: resp.kyber_prekey.id,
                kyberPrekey: kyberPub,
                kyberPrekeySignature: kyberSig
            )
        }

        let localAddr = try stores.localAddress()
        try processPreKeyBundle(
            bundle,
            for: addr,
            ourAddress: localAddr,
            sessionStore: stores,
            identityStore: stores,
            context: ctx
        )
    }

    /// The 60-digit safety number for verifying the v=2 conversation with
    /// [uin] out-of-band (key-fingerprint verification). Closes the
    /// server-MITM gap left by TOFU: a malicious server could substitute a
    /// peer's identity key, and there was no way to detect it. Two users
    /// compare this number over a trusted channel; if it matches, no key was
    /// swapped.
    ///
    /// Computed over the PINNED libsignal identities (the keys our sessions
    /// actually use, not a fresh server-fetched one). Returns nil when there
    /// is nothing to verify: we aren't bootstrapped, or the peer is v=1-only
    /// (never published a libsignal bundle). Establishing the session first
    /// pins the peer's identity (TOFU).
    ///
    /// Cross-platform with Android: the same iterations (5200) and version (2)
    /// over the same (uin-string, identity-key) inputs, so both ends compute
    /// the identical number. The fingerprint generator orders the two halves
    /// canonically, so each side passing its own (self, peer) yields the same
    /// result.
    static func safetyNumber(forPeerUIN uin: Int) async -> String? {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        guard let local = try? stores.loadLocalIdentity(),
              let addr = try? ProtocolAddress(name: String(uin), deviceId: 1)
        else { return nil }

        // The peer's PINNED identity; establish a session first (TOFU) when
        // we have none yet so the pin exists to read back.
        var peer = try? stores.identity(for: addr, context: ctx)
        if peer == nil {
            try? await ensureStage3Session(forPeerUIN: uin)
            peer = try? stores.identity(for: addr, context: ctx)
        }
        guard let peerKey = peer else { return nil }  // v=1-only peer

        let generator = NumericFingerprintGenerator(iterations: 5200)
        guard let fingerprint = try? generator.create(
            version: 2,
            localIdentifier: Data(String(local.uin).utf8),
            localKey: local.identityKeyPair.publicKey,
            remoteIdentifier: Data(String(uin).utf8),
            remoteKey: peerKey.publicKey
        ) else { return nil }

        // displayable.formatted is the raw 60-digit string; group it in fives
        // for reading aloud, matching the Android dialog.
        let digits = Array(fingerprint.displayable.formatted)
        return stride(from: 0, to: digits.count, by: 5)
            .map { String(digits[$0 ..< min($0 + 5, digits.count)]) }
            .joined(separator: " ")
    }
}
