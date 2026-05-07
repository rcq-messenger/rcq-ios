import Combine
import CryptoKit
import Foundation
import MultipeerConnectivity

/// Local radio chat over Apple's MultipeerConnectivity (Bluetooth
/// + Wi-Fi-Direct, transport chosen by the framework). Two surface
/// modes hosted by one service:
///
///   - **1:1**: ephemeral X25519 key-agreement at invite time,
///     AES-GCM for every message. Both sides see anonymous display
///     names (`NearbyService.mintDisplayName`); the user can opt
///     into "Add as contact" after the session.
///
///   - **Room**: shared AES key derived from the room id (open) or
///     PBKDF2 over a password (closed). 2-8 participants per room,
///     limited by `MCSession`'s 8-peer cap.
///
/// All state is in-memory. History is dropped on disconnect — same
/// posture as Random Chat.
@MainActor
final class RadioService: NSObject, ObservableObject {
    static let shared = RadioService()

    /// Bonjour service name. Must match the entries declared in
    /// `Info.plist`'s `NSBonjourServices` (without the `_tcp` /
    /// `_udp` suffix).
    private static let serviceType = "rcq-radio"
    /// MultipeerConnectivity hard cap. We surface "room full" UI
    /// before actually inviting beyond this.
    static let maxRoomPeers = 8

    // MARK: - Published surface

    @Published private(set) var isOnline = false
    @Published private(set) var discovered: [RadioPeer] = []
    /// Currently active 1:1 chat — present iff a session is up
    /// with exactly one peer in `.oneToOne` mode.
    @Published private(set) var activeOneToOne: RadioPeer?
    /// Currently active room — set when we joined or hosted a
    /// room. Nil when no room is open.
    @Published private(set) var activeRoom: RadioRoomMetadata?
    /// Pending room join — set the moment the joiner taps "Join"
    /// with a password, cleared once the host's first sealed frame
    /// (the roster on `.connected`) successfully decrypts under our
    /// derived key (key matches → password was right) OR fails to
    /// decrypt (key mismatches → wrong password, surface error and
    /// never enter the room). This gate prevents the brief
    /// "fake-enter-then-bounce" that was happening before — a
    /// joiner with the wrong password would sit inside the chat
    /// view for a few seconds while MC negotiated, then get kicked
    /// out on first frame. Now they stay on discovery with a
    /// "joining…" overlay until we know one way or the other.
    @Published private(set) var pendingRoomJoin: RadioRoomMetadata?
    /// Live message log for the active session (1:1 OR room).
    /// Cleared on disconnect.
    @Published private(set) var messages: [RadioMessage] = []
    /// Display names of peers currently in the active session,
    /// keyed by `MCPeerID.displayName`. Roster events from peers
    /// (`RadioPayload.roster`) update this so room headers can
    /// say "3 inside" with real labels.
    @Published private(set) var roster: [String: String] = [:]
    /// Pending 1:1 invitation from another peer — surfaces a
    /// modal "X wants to chat. Accept?" on the discovery screen.
    @Published var pendingInvite: PendingInvite?
    /// Latest soft error to render in the discovery / chat UI.
    @Published var lastError: String?
    /// True while the local user is holding the PTT button. UI
    /// flips the mic icon red and the chat shows a self-talking
    /// indicator.
    @Published private(set) var isTalking: Bool = false
    /// Display names of remote peers currently transmitting voice.
    /// Driven by `voiceTalkStart` / `voiceTalkStop` payloads (with
    /// a fallback insert on first `voiceFrame` in case the start
    /// frame got lost). Powers the "🔴 Alice, Bob…" pill above the
    /// chat composer.
    @Published private(set) var activeSpeakers: Set<String> = []

    struct PendingInvite: Identifiable {
        let id = UUID()
        let fromDisplayName: String
        let peerID: MCPeerID
        let invitationContext: Data?
        let invitationHandler: (Bool, MCSession?) -> Void
    }

    // MARK: - Internals

    /// Local peer id — fresh per app launch so no UIN-style
    /// fingerprint persists across radio sessions. Display name
    /// is the anonymous handle minted by NearbyService.
    private lazy var localPeer: MCPeerID = {
        let name = NearbyService.shared.displayName
        return MCPeerID(displayName: name.isEmpty ? "Stranger \(Int.random(in: 1000...9999))" : name)
    }()
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?

    /// Mode the service is currently advertising in. Drives what
    /// `discoveryInfo` keys go on the wire and how invites are
    /// interpreted on the receive side.
    private var advertiseMode: AdvertiseMode = .off
    private enum AdvertiseMode {
        case off
        case oneToOne
        case room(RadioRoomMetadata, password: String?)
    }

    /// Per-1:1-session ephemeral keys. Stored only for the lifetime
    /// of the session; cleared on disconnect.
    private var oneToOneKeys: RadioCrypto.EphemeralKeys?
    /// Cached symmetric key for the currently active session
    /// (1:1 derived from ECDH; room derived from id+password).
    private var sessionKey: SymmetricKey?
    /// Room password we used to derive the active room key —
    /// kept in memory so the host can re-issue challenges to
    /// late joiners.
    private var activeRoomPassword: String?
    /// Timestamp of the last `foundPeer` callback per peer. Used by
    /// the ghost-pruning sweep to drop stale rows when MC's
    /// `lostPeer` doesn't fire (host crashed, app force-quit, the
    /// device walked out of range without a clean stop).
    private var lastSeenAt: [MCPeerID: Date] = [:]
    private var refreshTimer: Timer?
    /// How long a peer can go without a fresh `foundPeer` callback
    /// before it's pruned from the discovery list. Browser is
    /// restarted every `Self.refreshInterval` so live peers re-fire
    /// `foundPeer` on each cycle; ghosts simply don't.
    private static let staleAfter: TimeInterval = 25
    private static let refreshInterval: TimeInterval = 12
    /// True iff we created the active room (vs joined someone else's).
    /// Drives the wrong-password gate on the joiner side: a sealed
    /// frame that fails to decrypt is interpreted as "host's
    /// roster encrypted with a different key → my password was
    /// wrong → self-eject". Hosts never self-eject on a bad
    /// decrypt — that just means a peer joined with the wrong key
    /// and their own client will leave.
    private var isRoomHost: Bool = false

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    override private init() { super.init() }

    // MARK: - Discovery lifecycle

    /// Start scanning + advertising 1:1 readiness. Call from the
    /// discovery screen's `task`; pair with `stop()` on disappear.
    func startDiscovery() {
        startSessionIfNeeded()
        startBrowser()
        startAdvertiser(.oneToOne)
        isOnline = true
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session?.disconnect()
        browser = nil
        advertiser = nil
        session = nil
        advertiseMode = .off
        discovered.removeAll()
        lastSeenAt.removeAll()
        messages.removeAll()
        roster.removeAll()
        activeOneToOne = nil
        activeRoom = nil
        pendingRoomJoin = nil
        sessionKey = nil
        activeRoomPassword = nil
        oneToOneKeys = nil
        pendingInvite = nil
        isOnline = false
        isTalking = false
        activeSpeakers.removeAll()
        RadioVoiceEngine.shared.stop()
    }

    /// User-driven refresh — wired to the discovery screen's
    /// pull-to-refresh. Prunes peers older than `staleAfter` and
    /// restarts the browser so live peers re-fire `foundPeer`
    /// immediately. Call this on RefreshControl pulls.
    func refreshDiscovery() {
        pruneStalePeers()
        restartBrowser()
    }

    // MARK: - 1:1 invite / accept

    /// Invite a discovered 1:1 peer. Bundles our ephemeral
    /// Curve25519 public key into the invitation context — the
    /// acceptor pairs it with their own and runs ECDH to derive
    /// the AES session key. Apple's TLS protects this exchange
    /// at the wire layer.
    func inviteOneToOne(_ peer: RadioPeer) {
        guard peer.kind == .oneToOne, let session else { return }
        let keys = RadioCrypto.makeEphemeralKeys()
        oneToOneKeys = keys
        var ctx: [String: String] = [:]
        ctx["pub"] = keys.pub.base64EncodedString()
        ctx["dn"] = localPeer.displayName
        let data = (try? JSONEncoder().encode(ctx)) ?? Data()
        browser?.invitePeer(peer.peerID, to: session, withContext: data, timeout: 30)
        markPeer(peer.peerID, state: .inviting)
    }

    /// Accept an inbound 1:1 invite. The invitation context carries
    /// the inviter's ephemeral pub; we derive `sessionKey` from
    /// it immediately so the very first frame we receive can be
    /// decrypted. Our own pub gets sent back as a handshake frame
    /// the moment the session establishes (see `session(:peer:
    /// didChange: .connected)`), letting the inviter derive their
    /// half of the key.
    func acceptInvite(_ invite: PendingInvite) {
        guard let session else {
            invite.invitationHandler(false, nil)
            return
        }
        if let ctxData = invite.invitationContext,
           let ctx = try? JSONDecoder().decode([String: String].self, from: ctxData),
           let theirPubB64 = ctx["pub"],
           let theirPub = Data(base64Encoded: theirPubB64) {
            let keys = RadioCrypto.makeEphemeralKeys()
            self.oneToOneKeys = keys
            do {
                self.sessionKey = try RadioCrypto.deriveSessionKey(
                    myPriv: keys.priv, theirPub: theirPub,
                )
            } catch {
                lastError = "Couldn't derive session key"
                invite.invitationHandler(false, nil)
                return
            }
        }
        invite.invitationHandler(true, session)
        pendingInvite = nil
    }

    func declineInvite(_ invite: PendingInvite) {
        invite.invitationHandler(false, nil)
        pendingInvite = nil
    }

    // MARK: - Room lifecycle

    /// Create + advertise a new room. Becomes the host. The room
    /// id is generated locally; the password (if any) is kept in
    /// memory so we can challenge late joiners.
    func createRoom(name: String, password: String?) {
        let roomID = UUID().uuidString.lowercased()
        // Trim leading/trailing whitespace on the password before
        // it ever hits PBKDF2 — autocorrect / smart-quote
        // substitution / accidental paste of "abc " (trailing
        // space) would otherwise derive a different key than the
        // joiner who typed "abc" cleanly. Same trim applied on
        // joinRoom so the two sides agree.
        let cleanPwd = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsPwd = !(cleanPwd ?? "").isEmpty
        let meta = RadioRoomMetadata(roomID: roomID, name: name, needsPassword: needsPwd)
        sessionKey = RadioCrypto.roomKey(roomID: roomID, password: cleanPwd)
        activeRoom = meta
        activeRoomPassword = cleanPwd
        isRoomHost = true
        startSessionIfNeeded()
        startBrowser()
        startAdvertiser(.room(meta, password: cleanPwd))
        isOnline = true
    }

    /// Join an already-advertised room. We invite the host through
    /// the same Multipeer browse + invite path, with the room id
    /// in our context so the host can route us into the right
    /// session. For password rooms the host issues a challenge
    /// over the data channel after the link is up.
    func joinRoom(_ peer: RadioPeer, password: String?) {
        guard peer.kind == .room, let meta = peer.room, let session else { return }
        // Match host's whitespace trim — see `createRoom`.
        let cleanPwd = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionKey = RadioCrypto.roomKey(roomID: meta.roomID, password: cleanPwd)
        // Don't set `activeRoom` yet — wait for the host's first
        // sealed frame to decrypt successfully. See `pendingRoomJoin`.
        pendingRoomJoin = meta
        activeRoomPassword = cleanPwd
        isRoomHost = false
        let ctx: [String: String] = ["rid": meta.roomID, "dn": localPeer.displayName]
        let data = (try? JSONEncoder().encode(ctx)) ?? Data()
        browser?.invitePeer(peer.peerID, to: session, withContext: data, timeout: 30)
        markPeer(peer.peerID, state: .connecting)
    }

    func leaveActiveSession() {
        if isTalking {
            RadioVoiceEngine.shared.stopCapture()
            isTalking = false
        }
        RadioVoiceEngine.shared.stop()
        activeSpeakers.removeAll()
        session?.disconnect()
        messages.removeAll()
        roster.removeAll()
        activeOneToOne = nil
        activeRoom = nil
        pendingRoomJoin = nil
        sessionKey = nil
        activeRoomPassword = nil
        oneToOneKeys = nil
        isRoomHost = false
        // Resume 1:1 advertising so the discovery screen we
        // bounce back to is live again.
        startAdvertiser(.oneToOne)
    }

    // MARK: - Send

    /// Compose + send a text message. Encrypts with the active
    /// session key (1:1 ECDH-derived OR room shared key) and
    /// fans out to every peer in the session.
    func send(text: String, replyTo: RadioMessage? = nil) {
        guard let session, !session.connectedPeers.isEmpty,
              let key = sessionKey else { return }
        let msg = RadioMessage(
            id: UUID().uuidString.lowercased(),
            senderDisplayName: localPeer.displayName,
            isFromMe: true,
            text: text,
            timestamp: Date(),
            replyToID: replyTo?.id,
            replyToSender: replyTo?.senderDisplayName,
            replyToBody: replyTo.map { String($0.text.prefix(160)) },
            reactions: [:],
        )
        messages.append(msg)
        sendPayload(.message(msg), key: key, to: session.connectedPeers, on: session)
    }

    func toggleReaction(_ asset: String, on message: RadioMessage) {
        guard let session, !session.connectedPeers.isEmpty,
              let key = sessionKey else { return }
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        var live = messages[idx]
        let me = localPeer.displayName
        if live.reactions[me] == asset {
            live.reactions.removeValue(forKey: me)
        } else {
            live.reactions[me] = asset
        }
        messages[idx] = live
        sendPayload(
            .reaction(messageID: message.id, reactor: me, asset: live.reactions[me]),
            key: key, to: session.connectedPeers, on: session,
        )
    }

    // MARK: - Push-to-talk

    /// Begin transmitting voice. Spins up the audio engine + mic
    /// tap, fires a reliable `voiceTalkStart` so peers can
    /// pre-render the "talking" pill, then streams AAC packets
    /// `.unreliable` to every connected peer (works in both 1:1
    /// and rooms — the existing fanout already covers both).
    func startTalking() {
        guard let session, !session.connectedPeers.isEmpty,
              sessionKey != nil else { return }
        guard !isTalking else { return }
        // Resolve mic permission asynchronously. `.undetermined`
        // pops the system prompt; `.denied` short-circuits to a
        // friendly error instead of trying to spin up the engine
        // and producing silent garbage.
        RadioVoiceEngine.requestMicPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.beginCapture(granted: granted, session: session)
            }
        }
    }

    private func beginCapture(granted: Bool, session: MCSession) {
        guard granted else {
            lastError = "radio.error.mic_denied".localized
            return
        }
        guard let key = sessionKey, !session.connectedPeers.isEmpty,
              !isTalking else { return }
        do {
            try RadioVoiceEngine.shared.startCapture { [weak self] seq, data in
                // Off-engine-queue. Hop to MainActor so we can touch
                // `self.session` / `self.sessionKey` safely.
                Task { @MainActor [weak self] in
                    self?.broadcastVoiceFrame(seq: seq, data: data)
                }
            }
        } catch RadioVoiceEngine.RadioVoiceError.invalidInputFormat {
            print("[Radio] PTT failed: invalidInputFormat (hwFormat sampleRate=0)")
            #if targetEnvironment(simulator)
            lastError = "radio.error.mic_simulator".localized
            #else
            lastError = "radio.error.voice_start_failed".localized
            #endif
            return
        } catch RadioVoiceEngine.RadioVoiceError.audioSessionFailed(let detail) {
            print("[Radio] PTT failed: audioSessionFailed — \(detail)")
            lastError = "radio.error.voice_start_failed".localized
            return
        } catch RadioVoiceEngine.RadioVoiceError.encoderUnavailable {
            print("[Radio] PTT failed: encoderUnavailable (AVAudioConverter init returned nil)")
            lastError = "radio.error.voice_start_failed".localized
            return
        } catch RadioVoiceEngine.RadioVoiceError.micPermissionDenied {
            print("[Radio] PTT failed: micPermissionDenied")
            lastError = "radio.error.mic_denied".localized
            return
        } catch {
            print("[Radio] PTT failed: unknown error — \(error)")
            lastError = "radio.error.voice_start_failed".localized
            return
        }
        isTalking = true
        sendPayload(
            .voiceTalkStart(speaker: localPeer.displayName),
            key: key,
            to: session.connectedPeers,
            on: session
        )
    }

    /// Release PTT — stop the mic tap and tell peers to tear down
    /// our player node on their side. Reliable because losing the
    /// stop event would leave a stale "talking" pill on every peer.
    func stopTalking() {
        guard isTalking else { return }
        RadioVoiceEngine.shared.stopCapture()
        isTalking = false
        if let session, let key = sessionKey, !session.connectedPeers.isEmpty {
            sendPayload(
                .voiceTalkStop(speaker: localPeer.displayName),
                key: key,
                to: session.connectedPeers,
                on: session
            )
        }
    }

    /// Encode + ship a single AAC packet to all connected peers.
    /// Sealed with the active session key (1:1 ECDH or room
    /// shared) and sent unreliable — drops are an acceptable
    /// trade-off for low latency, and the voice engine
    /// auto-tolerates gaps (the player node just plays a
    /// silent stretch).
    private func broadcastVoiceFrame(seq: UInt32, data: Data) {
        guard let session, let key = sessionKey,
              !session.connectedPeers.isEmpty else { return }
        sendPayload(
            .voiceFrame(speaker: localPeer.displayName, seq: seq, data: data),
            key: key,
            to: session.connectedPeers,
            on: session,
            reliable: false
        )
    }

    private func sendPayload(
        _ payload: RadioPayload,
        key: SymmetricKey,
        to peers: [MCPeerID],
        on session: MCSession,
        reliable: Bool = true
    ) {
        do {
            let json = try encoder.encode(payload)
            let sealed = try RadioCrypto.seal(json, key: key)
            try sendFrame(.sealed(sealed), to: peers, on: session, reliable: reliable)
        } catch {
            // Silent drop on unreliable voice frames — they're loss-
            // tolerant by design and a transient error here is just
            // a brief audio gap, not something to surface in the UI.
            if reliable { lastError = "Send failed: \(error.localizedDescription)" }
        }
    }

    /// Wraps the raw bytes in a `RadioFrame` (handshake vs sealed)
    /// before pushing through `MCSession.send`. Receivers decode
    /// with the same JSON wrapper. `reliable=false` is reserved for
    /// PTT voice frames where latency beats retransmit.
    private func sendFrame(
        _ frame: RadioFrame,
        to peers: [MCPeerID],
        on session: MCSession,
        reliable: Bool = true
    ) throws {
        let json = try encoder.encode(frame)
        try session.send(
            json,
            toPeers: peers,
            with: reliable ? .reliable : .unreliable
        )
    }

    /// Send our ephemeral 1:1 public key to a freshly-connected
    /// peer. The receive side derives `sessionKey` from this if
    /// it hasn't already (one half of the pair always derives
    /// before the other — whoever invited had a context-bound
    /// pub, the other side derives later from this handshake).
    private func sendHandshake(to peerID: MCPeerID, on session: MCSession) {
        guard let pub = oneToOneKeys?.pub else { return }
        do {
            try sendFrame(.handshake(pub), to: [peerID], on: session)
        } catch {
            lastError = "Handshake send failed"
        }
    }

    // MARK: - Browser / advertiser plumbing

    private func startSessionIfNeeded() {
        guard session == nil else { return }
        let s = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
    }

    private func startBrowser() {
        browser?.stopBrowsingForPeers()
        let b = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
        // Kick off the ghost-pruning sweep. MC's `lostPeer`
        // callback isn't fired reliably for unclean disconnects
        // (force-quit, crash, device sleep / out-of-range), so we
        // periodically restart the browser — live peers re-fire
        // `foundPeer` (lastSeenAt updates), ghosts don't (and get
        // pruned by the staleAfter cutoff). Interval is short
        // enough that a stale room disappears within ~30s of the
        // host going dark.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.refreshInterval, repeats: true,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneStalePeers()
                self?.restartBrowser()
            }
        }
    }

    /// Prune peers whose last `foundPeer` callback is older than
    /// `staleAfter`. Idempotent. Connected / inviting / connecting
    /// peers are kept regardless — if they're in an active session
    /// the connection itself is the liveness signal.
    private func pruneStalePeers() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        let connectedIDs = Set(session?.connectedPeers ?? [])
        discovered.removeAll { peer in
            if connectedIDs.contains(peer.peerID) { return false }
            switch peer.state {
            case .connecting, .inviting, .connected: return false
            default: break
            }
            let seen = lastSeenAt[peer.peerID] ?? .distantPast
            return seen < cutoff
        }
        // Drop dead entries from the seen map too.
        lastSeenAt = lastSeenAt.filter { discovered.contains(where: { $0.peerID == $0.peerID }) || connectedIDs.contains($0.key) }
    }

    /// Stop+start the browser without tearing down the session or
    /// the discovered cache. Live peers re-fire `foundPeer`
    /// (which refreshes their `lastSeenAt`); the next sweep prunes
    /// the rest.
    private func restartBrowser() {
        browser?.stopBrowsingForPeers()
        browser?.startBrowsingForPeers()
    }

    private func startAdvertiser(_ mode: AdvertiseMode) {
        advertiser?.stopAdvertisingPeer()
        let info: [String: String]?
        switch mode {
        case .off:
            info = nil
        case .oneToOne:
            info = RadioRoomMetadata.encodeOneToOne(displayName: localPeer.displayName)
        case .room(let meta, _):
            info = RadioRoomMetadata.encodeRoom(
                name: meta.name,
                roomID: meta.roomID,
                needsPassword: meta.needsPassword,
            )
        }
        let a = MCNearbyServiceAdvertiser(peer: localPeer, discoveryInfo: info, serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
        advertiseMode = mode
    }

    private func markPeer(_ peerID: MCPeerID, state: RadioPeer.ConnectionState) {
        if let idx = discovered.firstIndex(where: { $0.peerID == peerID }) {
            discovered[idx].state = state
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension RadioService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            self.lastSeenAt[peerID] = Date()
            // REPLACE existing entry rather than skipping. A host
            // who tears down a room and creates a new one keeps
            // the same MCPeerID but advertises a fresh roomID in
            // discovery info; with the old skip-on-duplicate
            // behaviour, joiners stayed bound to the stale
            // roomID, derived a key from it, and AES-GCM open
            // failed (key mismatch — same password, different
            // salt). Refreshing the row keeps the metadata
            // honest.
            let kind = RadioRoomMetadata.decodeKind(info)
            let displayName = RadioRoomMetadata.decodeName(info)
            let room = (kind == .room && info != nil) ? RadioRoomMetadata.decodeRoom(info!) : nil
            let peer = RadioPeer(
                peerID: peerID,
                displayName: displayName,
                kind: kind,
                room: room,
                state: .discovered,
            )
            // Dedupe by displayName + kind. Multipeer keeps both
            // the live and the previous-launch `MCPeerID` of a
            // sibling device alive in Bonjour for a window after
            // app relaunch / reinstall, so the same simulator or
            // iPhone can show up twice with identical labels but
            // different internal peerIDs. Tapping the stale row
            // invites a dead peer (timeout, never connects).
            // Killing same-label rows that aren't the current
            // peerID + connection-active fixes "I see them twice
            // and can't invite." Connected peers in the same
            // peerID stay (replace path below).
            let connectedIDs = Set(self.session?.connectedPeers ?? [])
            self.discovered.removeAll { existing in
                existing.peerID != peerID
                    && existing.displayName == displayName
                    && existing.kind == kind
                    && !connectedIDs.contains(existing.peerID)
                    && existing.state != .connected
                    && existing.state != .connecting
                    && existing.state != .inviting
            }
            if let idx = discovered.firstIndex(where: { $0.peerID == peerID }) {
                // Preserve any in-flight connection state so a
                // re-discovery while we're invited / connecting
                // doesn't reset the badge.
                let existingState = discovered[idx].state
                discovered[idx] = RadioPeer(
                    peerID: peerID,
                    displayName: displayName,
                    kind: kind,
                    room: room,
                    state: existingState,
                )
            } else {
                discovered.append(peer)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            discovered.removeAll { $0.peerID == peerID }
            lastSeenAt.removeValue(forKey: peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.lastError = "Discovery error: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension RadioService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void,
    ) {
        Task { @MainActor in
            // Surface the invite to the user — they decide accept
            // vs decline. Active room hosts auto-accept room
            // joiners (after a password gate where applicable).
            switch self.advertiseMode {
            case .off:
                invitationHandler(false, nil)
            case .oneToOne:
                self.pendingInvite = PendingInvite(
                    fromDisplayName: peerID.displayName,
                    peerID: peerID,
                    invitationContext: context,
                    invitationHandler: invitationHandler,
                )
            case .room(_, let pw):
                guard let session = self.session else {
                    invitationHandler(false, nil); return
                }
                if self.session?.connectedPeers.count ?? 0 >= Self.maxRoomPeers {
                    invitationHandler(false, nil)
                    self.lastError = "Room full"
                    return
                }
                _ = pw  // password gate happens after handshake
                invitationHandler(true, session)
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.lastError = "Advertising error: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCSessionDelegate

extension RadioService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.markPeer(peerID, state: .connected)
                self.roster[peerID.displayName] = peerID.displayName
                // 1:1 fallback only if neither an active room nor a
                // pending room-join is in flight. Otherwise we'd
                // mistake a wrong-password room attempt for a 1:1.
                if self.activeRoom == nil,
                   self.activeOneToOne == nil,
                   self.pendingRoomJoin == nil {
                    if let row = self.discovered.first(where: { $0.peerID == peerID }) {
                        self.activeOneToOne = row
                    }
                }
                // 1:1 mode: bounce our ephemeral pub at the peer
                // immediately. The inviter still has no session
                // key (they only sent their pub in the invite
                // context); receiving ours unblocks their ECDH.
                // The receiver already derived sessionKey at
                // accept-time but sends their pub anyway so the
                // protocol is symmetric. Room mode skips this —
                // sessionKey was derived from the room id /
                // password before advertising / joining. Pending
                // room joins also skip handshake — they've got a
                // PBKDF2-derived key already.
                if self.activeRoom == nil, self.pendingRoomJoin == nil {
                    self.sendHandshake(to: peerID, on: session)
                }
                // Roster only goes out once we have a key. For
                // the inviter that means after they receive the
                // peer's handshake frame (handled in the recv
                // path below).
                if let key = self.sessionKey {
                    self.sendPayload(
                        .roster(displayName: self.localPeer.displayName),
                        key: key,
                        to: [peerID],
                        on: session,
                    )
                }
            case .connecting:
                self.markPeer(peerID, state: .connecting)
            case .notConnected:
                self.markPeer(peerID, state: .disconnected)
                let droppedDisplayName = self.roster
                    .first(where: { $0.key == peerID.displayName })?.value
                    ?? peerID.displayName
                self.roster.removeValue(forKey: peerID.displayName)
                // If the disconnecting peer was mid-transmission,
                // its `voiceTalkStop` won't arrive — clean up the
                // speaker pill + player node here so we don't leak
                // a dead row in `activeSpeakers`.
                if self.activeSpeakers.contains(droppedDisplayName) {
                    self.activeSpeakers.remove(droppedDisplayName)
                    RadioVoiceEngine.shared.dropSpeaker(droppedDisplayName)
                }
                if session.connectedPeers.isEmpty {
                    self.activeOneToOne = nil
                    if self.activeRoom != nil {
                        // Host may still be running, but the session
                        // is empty. Leave the room open until the
                        // user explicitly leaves.
                    }
                    // NOTE: don't bail on `pendingRoomJoin` here.
                    // MC's connection negotiation routinely flips
                    // through `.connecting → .notConnected →
                    // .connecting → .connected` before a real link
                    // is established (we saw this in the field —
                    // the first attempt to a fresh host has 1-2
                    // bounces before sticking). Cancelling pending
                    // on the first transient `.notConnected` would
                    // kill perfectly-fine joins. Pending now only
                    // resolves via explicit outcomes: a successful
                    // decrypt (key matches → enter room) or an
                    // AES-GCM open failure (wrong password). If
                    // the host genuinely disappears, the user
                    // backs out via the X button.
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            // Wire frames are JSON-encoded `RadioFrame`s —
            // either a plaintext handshake (1:1 pub-key swap)
            // or a sealed payload. Try-decode first; anything
            // that doesn't parse is dropped.
            guard let frame = try? self.decoder.decode(RadioFrame.self, from: data) else {
                // Silent drop — a malformed frame is just a stray
                // packet on the mesh, surfacing it as an alert
                // would noise-spam users.
                return
            }
            switch frame {
            case .handshake(let theirPub):
                // 1:1: derive sessionKey if we don't already
                // have one. Then send our own roster (now that
                // we can encrypt). If we already had a key (we
                // were the receiver), this handshake was the
                // peer's confirmation — nothing more to do.
                if self.sessionKey == nil, let myKeys = self.oneToOneKeys {
                    do {
                        self.sessionKey = try RadioCrypto.deriveSessionKey(
                            myPriv: myKeys.priv, theirPub: theirPub,
                        )
                        // Now that we have a key, send our
                        // initial roster so the peer sees us.
                        if let key = self.sessionKey {
                            self.sendPayload(
                                .roster(displayName: self.localPeer.displayName),
                                key: key,
                                to: [peerID],
                                on: session,
                            )
                        }
                    } catch {
                        self.lastError = "Key derive failed"
                    }
                }
            case .sealed(let cipher):
                guard let key = self.sessionKey else { return }
                do {
                    let json = try RadioCrypto.open(cipher, key: key)
                    let payload = try self.decoder.decode(RadioPayload.self, from: json)
                    // First successful decryption while pending a
                    // room join = our PBKDF2 key matches the host's,
                    // i.e. password was correct. Promote pending
                    // → active so the chat view takes over.
                    if let pending = self.pendingRoomJoin {
                        self.activeRoom = pending
                        self.pendingRoomJoin = nil
                    }
                    self.handle(payload, fromPeer: peerID)
                } catch {
                    // Decrypt failure means our key doesn't match the
                    // sender's. Three cases:
                    //
                    //   - PENDING room join: never entered the room
                    //     to begin with — drop pending state, surface
                    //     wrong-password error, drop the MC link.
                    //
                    //   - JOINER already inside a password room:
                    //     shouldn't normally happen post-join, but
                    //     defensively self-eject.
                    //
                    //   - HOST or 1:1 / no-password peer: drop
                    //     silently; the OTHER side will surface it.
                    if self.pendingRoomJoin != nil {
                        self.pendingRoomJoin = nil
                        self.sessionKey = nil
                        self.activeRoomPassword = nil
                        self.isRoomHost = false
                        self.session?.disconnect()
                        self.roster.removeAll()
                        self.lastError = "radio.error.wrong_password".localized
                        self.startAdvertiser(.oneToOne)
                    } else if self.activeRoom != nil && !self.isRoomHost {
                        self.leaveActiveSession()
                        self.lastError = "radio.error.wrong_password".localized
                    }
                }
            }
        }
    }

    private func handle(_ payload: RadioPayload, fromPeer peerID: MCPeerID) {
        switch payload {
        case .message(var msg):
            msg = RadioMessage(
                id: msg.id,
                senderDisplayName: msg.senderDisplayName,
                isFromMe: false,
                text: msg.text,
                timestamp: msg.timestamp,
                replyToID: msg.replyToID,
                replyToSender: msg.replyToSender,
                replyToBody: msg.replyToBody,
                reactions: msg.reactions,
            )
            messages.append(msg)
            UISelectionFeedbackGenerator().selectionChanged()
            SoundService.shared.playIncoming(fromUIN: nil, thread: nil)
        case .reaction(let messageID, let reactor, let asset):
            guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
            var live = messages[idx]
            if let asset {
                live.reactions[reactor] = asset
            } else {
                live.reactions.removeValue(forKey: reactor)
            }
            messages[idx] = live
        case .roster(let displayName):
            roster[peerID.displayName] = displayName
        case .challenge, .challengeAck:
            // Reserved for password-room verification — wired in
            // when we add the late-joiner challenge flow.
            break
        case .voiceTalkStart(let speaker):
            // Suppress own-frame echo — defensive, the seal goes
            // out to peers only, but a future broadcast bug
            // shouldn't insert ourselves into the active list.
            guard speaker != localPeer.displayName else { return }
            activeSpeakers.insert(speaker)
        case .voiceTalkStop(let speaker):
            guard speaker != localPeer.displayName else { return }
            activeSpeakers.remove(speaker)
            RadioVoiceEngine.shared.dropSpeaker(speaker)
        case .voiceFrame(let speaker, _, let frameData):
            guard speaker != localPeer.displayName else { return }
            // Defensive: if the start payload was lost (unreliable
            // would never lose a reliable, but a peer could go
            // out of range and we missed it), surface the speaker
            // anyway on first frame.
            if !activeSpeakers.contains(speaker) {
                activeSpeakers.insert(speaker)
            }
            RadioVoiceEngine.shared.feedFrame(speaker: speaker, data: frameData)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
