import Foundation
import LibSignalClient

/// Short-lived per-peer device list. A peer adds or drops an install rarely,
/// so re-asking on every send would be pure round-trip; a stale list is
/// self-correcting (a dropped device 404s on send, a new one starts
/// receiving on the next refresh).
actor PeerDeviceCache {
    static let shared = PeerDeviceCache()

    private struct Entry { let devices: [Int]; let at: Date }
    private static let ttl: TimeInterval = 5 * 60
    private var entries: [Int: Entry] = [:]

    func cached(_ uin: Int) -> [Int]? {
        guard let e = entries[uin], Date().timeIntervalSince(e.at) < Self.ttl else { return nil }
        return e.devices
    }

    func store(_ uin: Int, devices: [Int]) {
        entries[uin] = Entry(devices: devices, at: Date())
    }

    func invalidate(_ uin: Int) {
        entries.removeValue(forKey: uin)
    }
}

/// Stage 3 session-establishment helpers. Lives in the main-app target
/// only — the NSE has no business fetching pre-key bundles. Decrypt
/// path on the NSE side hits the existing libsignal session in
/// `SignalProtocolStores`; if no session exists yet the message is a
/// `PreKeySignalMessage` which carries enough state to seed one
/// without a server round-trip.
extension SignalCryptoService {
    /// Every libsignal device of [uin] a sender has to reach, primary
    /// included. `nil` (endpoint missing, unreachable, or empty) means "no
    /// usable answer" and callers fall back to the single-device wire.
    static func peerDeviceIDs(forPeerUIN uin: Int) async -> [Int]? {
        if let cached = await PeerDeviceCache.shared.cached(uin) { return cached }
        struct DeviceResp: Decodable { let device_id: Int; let label: String? }
        struct DevicesResp: Decodable { let uin: Int; let devices: [DeviceResp] }
        guard let resp: DevicesResp = try? await APIClient.shared.request("GET", "/keys/\(uin)/devices")
        else { return nil }
        let ids = resp.devices.map { $0.device_id }.sorted()
        guard !ids.isEmpty else { return nil }
        await PeerDeviceCache.shared.store(uin, devices: ids)
        return ids
    }

    /// Drop the cached device list for [uin] — a send that 404s (device
    /// revoked) and a session reset both mean what we hold is no longer what
    /// the peer runs.
    static func invalidatePeerDevices(forPeerUIN uin: Int) async {
        await PeerDeviceCache.shared.invalidate(uin)
    }

    private struct SignedPreKeyResp: Decodable {
        let id: UInt32
        let publicKey: String
        let signature: String
        enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
    }
    private struct KyberPreKeyResp: Decodable {
        let id: UInt32
        let publicKey: String
        let signature: String
        enum CodingKeys: String, CodingKey { case id; case publicKey = "public"; case signature }
    }
    private struct OPKResp: Decodable {
        let id: UInt32
        let publicKey: String
        enum CodingKeys: String, CodingKey { case id; case publicKey = "public" }
    }
    private struct BundleResp: Decodable {
        let uin: Int
        let registration_id: UInt32
        let signal_identity_key: String
        /// The X25519 key the OUTER sealed-sender layer goes to for this
        /// device. Equal to the account identity key for the primary; a
        /// secondary install holds one of its own. Absent on an island that
        /// predates per-device keys.
        let sealed_sender_pub: String?
        let signed_prekey: SignedPreKeyResp
        let kyber_prekey: KyberPreKeyResp
        let one_time_prekey: OPKResp?
    }

    /// One pre-key bundle of [uin], consuming one of that device's OPKs.
    ///
    /// The per-device path serves device 1 too, and it is the one to ask:
    /// `/keys/{uin}/bundle` deliberately 404s while the account has a linked
    /// web session, so the legacy path would drop the peer's PRIMARY install
    /// out of the fan-out. It stays as the fallback for an island that has no
    /// per-device route at all — there the single bundle is all there is.
    private static func fetchBundle(uin: Int, deviceId: UInt32) async throws -> BundleResp {
        do {
            return try await APIClient.shared.request("GET", "/keys/\(uin)/devices/\(deviceId)/bundle")
        } catch {
            // 404 = the list we are fanning out over names a device the island
            // will not serve (revoked, or a registration that never finished).
            // Kept for the rest of its TTL, that list costs a doomed bundle
            // fetch on every send until it expires.
            if let api = error as? APIError, case .http(404, _) = api {
                await invalidatePeerDevices(forPeerUIN: uin)
            }
            guard deviceId == 1 else { throw error }
            return try await APIClient.shared.request("GET", "/keys/\(uin)/bundle")
        }
    }

    /// What a device of [uin] publishes as its libsignal identity. The
    /// bootstrap uses it to recognise a device row it registered itself and
    /// whose id it never got to keep. Costs that device one OPK, same as any
    /// bundle fetch, so it is for the registration path only.
    static func deviceIdentity(
        uin: Int, deviceId: UInt32
    ) async -> (identityKey: String, registrationId: UInt32)? {
        guard let resp = try? await fetchBundle(uin: uin, deviceId: deviceId) else { return nil }
        return (resp.signal_identity_key, resp.registration_id)
    }

    /// Idempotent X3DH/PQXDH session establishment. Fetches the peer's
    /// pre-key bundle (consuming one OPK on the server) and runs
    /// `processPreKeyBundle` to seed a session in the local
    /// SessionStore. Returns immediately if a session we can SEND from
    /// already exists.
    /// Async because of the HTTP fetch — call once before the first
    /// `encryptStage3(...)` to a given peer device.
    static func ensureStage3Session(forPeerUIN uin: Int, deviceId: UInt32 = 1) async throws {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        let addr = try ProtocolAddress(name: String(uin), deviceId: deviceId)
        // A record whose current state has been ARCHIVED still opens what is
        // in flight to it, but it can no longer send: `archiveAllSessions`
        // leaves exactly that behind when this install changes device id.
        // Presence of a row is therefore not the question — a usable sending
        // chain is.
        let hasSession = try stores.loadSession(for: addr, context: ctx)?.hasCurrentState == true
        // A session says nothing about the device's OUTER key, and a secondary
        // install has one of its own: when THEY opened the conversation, the
        // session was seeded from their PreKeySignalMessage and we never saw a
        // bundle. Asking for one costs a one-time prekey, so it happens once
        // per device and the answer is kept.
        let needsOuterKey = deviceId != 1 && stores.peerDeviceOuterKey(forPeerUIN: uin, deviceId: deviceId) == nil
        if hasSession && !needsOuterKey { return }

        let resp = try await fetchBundle(uin: uin, deviceId: deviceId)
        if deviceId != 1,
           let outerB64 = resp.sealed_sender_pub,
           let outerBytes = Data(base64Encoded: outerB64), !outerBytes.isEmpty {
            stores.storePeerDeviceOuterKey(outerBytes, forPeerUIN: uin, deviceId: deviceId)
        }
        if hasSession { return }

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
                deviceId: deviceId,
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
            print("[Stage3] bundle of \(uin)/\(deviceId) returned no OPK — proceeding without")
            bundle = try PreKeyBundle(
                registrationId: resp.registration_id,
                deviceId: deviceId,
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
    ///
    /// Reads the peer's PRIMARY device. Each install of theirs carries its own
    /// libsignal identity, so a number verified here says nothing about their
    /// second device.
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
