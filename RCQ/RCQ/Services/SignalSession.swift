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
}
