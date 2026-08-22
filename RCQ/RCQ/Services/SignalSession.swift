import Foundation
import LibSignalClient

/// Short-lived per-peer device list. A peer adds or drops an install rarely,
/// so re-asking on every send would be pure round-trip; a stale list is
/// self-correcting (a dropped device 404s on send or on its bundle, a newly
/// linked one names itself in its first message, and both drop the entry).
///
/// Fifteen minutes with a little jitter per entry (Stage 3 rule, shared with
/// Android and the web). Not a day: a peer's freshly linked device would get
/// no carbons from us for an hour, which was a real report on 2026-08-19.
/// Not five minutes either, now that the read is anonymous but still a
/// round-trip per live conversation. The jitter keeps every conversation
/// that woke together from refreshing together.
actor PeerDeviceCache {
    static let shared = PeerDeviceCache()

    private struct Entry { let devices: [Int]; let expires: Date }
    private static let ttl: TimeInterval = 15 * 60
    private static let jitter: TimeInterval = 3 * 60
    private var entries: [Int: Entry] = [:]

    func cached(_ uin: Int) -> [Int]? {
        guard let e = entries[uin], Date() < e.expires else { return nil }
        return e.devices
    }

    func store(_ uin: Int, devices: [Int]) {
        let life = Self.ttl + TimeInterval.random(in: -Self.jitter...Self.jitter)
        entries[uin] = Entry(devices: devices, expires: Date().addingTimeInterval(life))
    }

    func invalidate(_ uin: Int) {
        entries.removeValue(forKey: uin)
    }

    /// An inbound v=2 envelope named a device of [uin]. If the list we hold
    /// does not know that device, the list is stale (they linked an install
    /// since we read it) and our next send would leave it out; drop the entry
    /// so the next send re-reads. A device we already know changes nothing.
    func noteInbound(_ uin: Int, deviceId: Int) {
        guard let e = entries[uin], !e.devices.contains(deviceId) else { return }
        entries.removeValue(forKey: uin)
    }
}

/// Silence probe: notice a peer whose install was replaced under us.
///
/// A replaced install (re-claimed primary slot, reinstall, phrase restore
/// onto a new machine, revoked device) is INVISIBLE from the sending side:
/// the island takes every copy sealed to the session the peer no longer
/// holds, the receipt simply never comes, and an established session means
/// the bundle — where the new identity would show — is never read again.
/// Messages sent in that window are lost without a trace (live-tested on the
/// web 2026-08-20; that test is the reference implementation, Android
/// followed in 0.135/0.136).
///
/// Sustained silence IS the signal: if this side keeps sending and that
/// DEVICE has answered nothing — no receipt, no message, nothing naming it —
/// the next send re-reads its published identity and rebuilds the session
/// only when the identity actually changed (see `probeSession`). Tracked PER
/// DEVICE, not per account: a peer's phone answering promptly says nothing
/// about their linked browser whose session is dead. Keys are
/// "uin:deviceId"; in-memory on purpose — restart amnesia just means the
/// first send after a relaunch arms the timers afresh.
///
/// Thresholds are the web's and Android's, verbatim. Do not tune them here
/// alone: three clients probing at different rhythms is three different
/// failure modes to debug.
final class SilenceProbe: @unchecked Sendable {
    static let shared = SilenceProbe()

    /// Two minutes of active sending with nothing back arms the re-read...
    static let peerSilence: TimeInterval = 2 * 60
    /// ...and a quiet-but-healthy peer costs one FREE identity comparison
    /// per half hour, nothing else (see `probeSession` on why free).
    static let minProbeInterval: TimeInterval = 30 * 60

    private let lock = NSLock()
    /// "uin:deviceId" -> when the oldest still-unanswered v=2 copy to that
    /// device was sealed.
    private var awaitingReplySince: [String: Date] = [:]
    /// "uin:deviceId" -> when that device's probe last actually ran.
    private var lastProbeAt: [String: Date] = [:]
    /// "uin:deviceId" -> the libsignal identity that device published the
    /// last time the (free) device list was read. The probe compares against
    /// THIS instead of re-reading a bundle: a bundle read consumes one of the
    /// peer's one-time prekeys, and a probe that spends one every half hour
    /// to hear "nothing changed" drains a pool that only refills while its
    /// owner is online — leaving every later X3DH with that account without
    /// its one-time secret. The probe would erode what it exists to protect.
    private var published: [String: String] = [:]

    private static func key(_ uin: Int, _ deviceId: Int) -> String { "\(uin):\(deviceId)" }

    /// Which envelopes may arm the probe: only one that EARNS an answer — a
    /// stored message, which the recipient receipts back. A read receipt, a
    /// reaction, an edit or a visit owes nothing in return, and since every
    /// message we RECEIVE makes us send a receipt of our own, arming on those
    /// made "armed and never cleared" the steady state of every conversation
    /// on the web. Mirrors Android's isCarbonable set.
    static func earnsAnswer(_ env: Envelope) -> Bool {
        switch env {
        case .text, .photo, .video, .voice, .file, .location: return true
        default: return false
        }
    }

    func notePublishedIdentity(_ identityB64: String, uin: Int, deviceId: Int) {
        lock.lock(); defer { lock.unlock() }
        published[Self.key(uin, deviceId)] = identityB64
    }

    func publishedIdentity(uin: Int, deviceId: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return published[Self.key(uin, deviceId)]
    }

    /// Armed AFTER a successful seal: from that moment the device owes us a
    /// receipt. First unanswered send wins — a later one must not push the
    /// clock back.
    func arm(uin: Int, deviceId: Int, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(uin, deviceId)
        if awaitingReplySince[k] == nil { awaitingReplySince[k] = now }
    }

    func probeDue(uin: Int, deviceId: Int, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(uin, deviceId)
        guard let since = awaitingReplySince[k] else { return false }
        return now.timeIntervalSince(since) > Self.peerSilence
            && now.timeIntervalSince(lastProbeAt[k] ?? .distantPast) > Self.minProbeInterval
    }

    /// The throttle is spent on a probe that actually READ something. An
    /// unreachable island must not buy the peer half an hour of not being
    /// checked, so the caller skips this on `.unreachable`.
    func noteProbeRan(uin: Int, deviceId: Int, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastProbeAt[Self.key(uin, deviceId)] = now
    }

    /// A rebuilt session starts a fresh conversation with that install: the
    /// old clock is meaningless.
    func noteRebuilt(uin: Int, deviceId: Int) {
        lock.lock(); defer { lock.unlock() }
        awaitingReplySince.removeValue(forKey: Self.key(uin, deviceId))
    }

    /// Any decrypted envelope NAMING its device — a message, a receipt,
    /// anything — proves that install can talk to us: its probe stands down.
    /// v=1 names no device and clears nothing (crediting the primary for a
    /// copy that may have come from a sibling is exactly the confusion that
    /// kept a dead device unhealed on the web).
    func noteInbound(uin: Int, deviceId: Int) {
        lock.lock(); defer { lock.unlock() }
        awaitingReplySince.removeValue(forKey: Self.key(uin, deviceId))
    }

    /// The probe measures how long a PEER has been quiet, and a stretch when
    /// THIS side had no socket measures nothing: their replies may be sitting
    /// in the queue the reconnect is about to drain.
    ///
    /// ⚠ So the clocks are PUSHED FORWARD by the gap, not reset. Resetting
    /// looked equivalent on Android and is not: a link that redials more than
    /// once every two minutes — a phone in a tunnel, a flapping VPN — would
    /// rearm every clock before any of them could reach the threshold, and
    /// the probe would never fire for exactly the users whose sessions are
    /// most likely dead (Android 0.136 rule).
    func shiftClocks(by gap: TimeInterval) {
        guard gap > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for (k, armedAt) in awaitingReplySince {
            awaitingReplySince[k] = armedAt.addingTimeInterval(gap)
        }
    }

    /// Account switch / burn: the keys are peer uins, which mean nothing on
    /// another island — a probe carried across would re-key somebody else's
    /// namesake.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        awaitingReplySince.removeAll()
        lastProbeAt.removeAll()
        published.removeAll()
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
    ///
    /// On an island that serves key lookups open (Stage 3) the list is read
    /// with no session token: it is public material, and the token only told
    /// the island whose keys we were reading. The list carries no label any
    /// more and nothing here ever read one.
    static func peerDeviceIDs(forPeerUIN uin: Int) async -> [Int]? {
        if let cached = await PeerDeviceCache.shared.cached(uin) { return cached }
        struct DeviceResp: Decodable { let device_id: Int; let signal_identity_key: String? }
        struct DevicesResp: Decodable { let uin: Int; let devices: [DeviceResp] }
        let anonymous = await anonymousKeyLookup()
        guard let resp: DevicesResp = try? await APIClient.shared.request(
            "GET", "/keys/\(uin)/devices", authenticated: !anonymous
        ) else { return nil }
        // The list carries each install's published identity, and recording it
        // is what lets the silence probe ask its question for FREE later — a
        // bundle read gives the same answer and costs the peer a one-time
        // prekey on the way. Absent on an island too old to publish it.
        for d in resp.devices {
            if let ik = d.signal_identity_key, !ik.isEmpty {
                SilenceProbe.shared.notePublishedIdentity(ik, uin: uin, deviceId: d.device_id)
            }
        }
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

    /// An inbound v=2 envelope from [uin] named [deviceId] as its sender. A
    /// device the cached list does not know is a device the peer linked after
    /// we read it; see `PeerDeviceCache.noteInbound`.
    static func noteInboundDevice(forPeerUIN uin: Int, deviceId: Int) async {
        await PeerDeviceCache.shared.noteInbound(uin, deviceId: deviceId)
    }

    /// Whether the ACTIVE island serves the three key lookups without a
    /// session token (Stage 3). Both flags, never one: `anon_keys` alone
    /// would hand out the bundle minus its one-time prekey to an anonymous
    /// caller, and `deposit_auth` alone is an island that still wants the
    /// bearer on the lookup. An island that advertises neither gets exactly
    /// the old authenticated wire.
    private static func anonymousKeyLookup() async -> Bool {
        let caps = await MainActor.run { AppState.shared.serverCapabilities }
        return caps.anonKeys && caps.depositAuth
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
            return try await fetchBundle(path: "/keys/\(uin)/devices/\(deviceId)/bundle")
        } catch {
            // 404 = the list we are fanning out over names a device the island
            // will not serve (revoked, or a registration that never finished).
            // Kept for the rest of its TTL, that list costs a doomed bundle
            // fetch on every send until it expires.
            if let api = error as? APIError, case .http(404, _) = api {
                await invalidatePeerDevices(forPeerUIN: uin)
            }
            guard deviceId == 1 else { throw error }
            return try await fetchBundle(path: "/keys/\(uin)/bundle")
        }
    }

    /// One bundle GET, anonymous where the island allows it (Stage 3).
    ///
    /// The bearer token is replaced by a single-use deposit token in
    /// `X-Deposit-Token`: the island spends it to hand out the one-time
    /// prekey and learns nothing about who asked. One token per fetch. The
    /// island's three answers, and what each does to the token:
    ///   200: spent, the bundle carries the prekey;
    ///   403: refused (the epoch rotated under the cached params, or the
    ///        island stopped issuing). The cached params and every token
    ///        minted under them are dropped, one fresh token is tried, and
    ///        a second refusal falls back to the session token for THIS
    ///        fetch rather than losing the send;
    ///   404: no such bundle or device, the token was NOT spent and goes
    ///        back to the reserve. The caller reads the 404 as it always did.
    /// A token that could not be minted at all (no params, PoW not solved,
    /// issue refused) also means the session-token path: the island does
    /// still accept it, and a send is worth more than the metadata it leaks.
    private static func fetchBundle(path: String) async throws -> BundleResp {
        guard await anonymousKeyLookup() else {
            return try await APIClient.shared.request("GET", path)
        }
        guard let host = APIClient.shared.baseURL.host else {
            return try await APIClient.shared.request("GET", path)
        }
        let masquerade = await APIClient.shared.currentServerToken()
        var retried = false
        while true {
            guard let token = await DepositAuthStore.shared.tokenFor(host: host, masquerade: masquerade),
                  let header = DepositAuthStore.headerValue(token)
            else {
                print("[Stage3] no deposit token for \(host); bundle read with the session token")
                return try await APIClient.shared.request("GET", path)
            }
            do {
                return try await APIClient.shared.request(
                    "GET", path, authenticated: false, headers: ["X-Deposit-Token": header]
                )
            } catch let api as APIError {
                if case .http(404, _) = api {
                    await DepositAuthStore.shared.giveBack(token, host: host)
                    throw api
                }
                guard case .http(403, _) = api else { throw api }
                if retried {
                    print("[Stage3] deposit token refused twice by \(host); bundle read with the session token")
                    return try await APIClient.shared.request("GET", path)
                }
                print("[Stage3] deposit token refused by \(host); re-minting once")
                retried = true
                await DepositAuthStore.shared.forget(host: host)
            }
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
    ///
    /// [force] is the silence probe replacing a session it has decided is
    /// dead — the whole point there is to run the handshake again over one
    /// that still looks usable. ⚠ NOT delete-then-establish: libsignal's own
    /// handshake ARCHIVES the session it replaces, and archived states still
    /// decrypt — whatever that device sealed to the old session before it
    /// vanished (a message in flight, a queued backlog) keeps opening.
    /// Deleting first would throw exactly that away, which is the loss the
    /// probe exists to prevent.
    static func ensureStage3Session(forPeerUIN uin: Int, deviceId: UInt32 = 1, force: Bool = false) async throws {
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
        if !force && hasSession && !needsOuterKey { return }

        let resp = try await fetchBundle(uin: uin, deviceId: deviceId)
        if deviceId != 1,
           let outerB64 = resp.sealed_sender_pub,
           let outerBytes = Data(base64Encoded: outerB64), !outerBytes.isEmpty {
            stores.storePeerDeviceOuterKey(outerBytes, forPeerUIN: uin, deviceId: deviceId)
        }
        if !force && hasSession { return }

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

    /// What a silence probe found when it re-checked a peer device.
    enum ProbeResult {
        /// Nothing could be read (no published identity, no bundle) —
        /// nothing was touched, and the probe throttle must not be spent.
        case unreachable
        /// The peer still publishes the identity our session was built on,
        /// so the session is fine and their silence means something else
        /// (offline, asleep, or replying over v=1 which names no device and
        /// can never clear the probe). Nothing was touched.
        case unchanged
        /// The identity behind that device changed — the install we shared a
        /// ratchet with is gone — and the session was rebuilt.
        case rebuilt
    }

    /// Re-check [uin]/[deviceId] and rebuild the session ONLY if the
    /// identity behind it actually changed.
    ///
    /// ⚠ Deliberately NOT an unconditional rebuild. Dropping a session
    /// destroys our RECEIVING chains too: anything that device already
    /// sealed to it — a message in flight, a whole offline backlog in the
    /// queue — stops decrypting, and the drain acks those rows away. Doing
    /// that on a hunch every time a peer is quiet turns a probe meant to
    /// RECOVER messages into one that loses them, and a peer whose client
    /// answers in v=1 is quiet by that definition forever. A changed
    /// identity key is the one signal that the session is genuinely dead,
    /// and it is exactly what a replaced install publishes.
    ///
    /// ⚠ The comparison comes FIRST, and it is free: the published identity
    /// is what the device list said (recorded in `peerDeviceIDs`). Reading a
    /// bundle instead would consume one of the peer's one-time prekeys every
    /// time, and "unchanged" is the answer almost every time. Same rule as
    /// Android 0.136 and the web.
    ///
    /// The residual case — a dead session behind an UNCHANGED identity — is
    /// not silently accepted: it is logged, and the peer's next message
    /// re-keys this side through its own prekey material.
    static func probeSession(forPeerUIN uin: Int, deviceId: Int) async -> ProbeResult {
        guard (1...127).contains(deviceId),
              let addr = try? ProtocolAddress(name: String(uin), deviceId: UInt32(deviceId))
        else { return .unreachable }
        guard let publishedB64 = SilenceProbe.shared.publishedIdentity(uin: uin, deviceId: deviceId),
              let publishedBytes = Data(base64Encoded: publishedB64),
              let published = try? IdentityKey(bytes: publishedBytes)
        else {
            // An island too old to publish identities in the device list. We
            // will not spend a prekey to guess; the peer's own next message
            // re-keys us through its prekey material.
            print("[SilenceProbe] \(uin)/\(deviceId): no published identity — nothing done")
            return .unreachable
        }
        let stores = SignalProtocolStores.shared
        let pinned = try? stores.identity(for: addr, context: RCQStoreContext.shared)
        if let pinned, pinned.serialize() == published.serialize() {
            print("[SilenceProbe] \(uin)/\(deviceId) unchanged; session kept")
            return .unchanged
        }
        // The identity behind that device really did change (or we hold no
        // pin): the install we shared a ratchet with is gone, and a bundle
        // read — with the prekey it costs — is now the right thing to spend.
        // `force` runs the handshake over the session that still looks
        // usable; see ensureStage3Session on why that never deletes first.
        print("[SilenceProbe] identity changed behind \(uin)/\(deviceId) — fresh X3DH")
        do {
            try await ensureStage3Session(forPeerUIN: uin, deviceId: UInt32(deviceId), force: true)
            return .rebuilt
        } catch {
            print("[SilenceProbe] rebuild for \(uin)/\(deviceId) failed: \(error)")
            return .unreachable
        }
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
