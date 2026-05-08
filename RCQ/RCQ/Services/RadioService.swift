import Combine
import CryptoKit
import Foundation
import MultipeerConnectivity

@MainActor
final class RadioService: NSObject, ObservableObject {
    static let shared = RadioService()

    private static let serviceType = "rcq-radio"
    static let maxRoomPeers = 8

    // MARK: - Published surface

    @Published private(set) var isOnline = false
    @Published private(set) var discovered: [RadioPeer] = []
    @Published private(set) var activeOneToOne: RadioPeer?
    @Published private(set) var activeRoom: RadioRoomMetadata?
    /// Set on join, cleared once the host's first sealed frame either decrypts (key match → enter room) or fails (wrong password → eject).
    @Published private(set) var pendingRoomJoin: RadioRoomMetadata?
    @Published private(set) var messages: [RadioMessage] = []
    @Published private(set) var roster: [String: String] = [:]
    @Published var pendingInvite: PendingInvite?
    @Published var lastError: String?
    @Published private(set) var isTalking: Bool = false
    @Published private(set) var activeSpeakers: Set<String> = []

    struct PendingInvite: Identifiable {
        let id = UUID()
        let fromDisplayName: String
        let peerID: MCPeerID
        let invitationContext: Data?
        let invitationHandler: (Bool, MCSession?) -> Void
    }

    // MARK: - Internals

    private lazy var localPeer: MCPeerID = {
        let name = NearbyService.shared.displayName
        return MCPeerID(displayName: name.isEmpty ? "Stranger \(Int.random(in: 1000...9999))" : name)
    }()
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?

    private var advertiseMode: AdvertiseMode = .off
    private enum AdvertiseMode {
        case off
        case oneToOne
        case room(RadioRoomMetadata, password: String?)
    }

    private var oneToOneKeys: RadioCrypto.EphemeralKeys?
    private var sessionKey: SymmetricKey?
    private var activeRoomPassword: String?
    private var lastSeenAt: [MCPeerID: Date] = [:]
    private var refreshTimer: Timer?
    private static let staleAfter: TimeInterval = 25
    private static let refreshInterval: TimeInterval = 12
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

    func refreshDiscovery() {
        pruneStalePeers()
        restartBrowser()
    }

    // MARK: - 1:1 invite / accept

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

    func createRoom(name: String, password: String?) {
        let roomID = UUID().uuidString.lowercased()
        // Trim whitespace before PBKDF2 so host and joiner agree on the key.
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

    func joinRoom(_ peer: RadioPeer, password: String?) {
        guard peer.kind == .room, let meta = peer.room, let session else { return }
        let cleanPwd = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionKey = RadioCrypto.roomKey(roomID: meta.roomID, password: cleanPwd)
        // Wait for first sealed frame to decrypt before promoting to activeRoom.
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
        startAdvertiser(.oneToOne)
    }

    // MARK: - Send

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

    func startTalking() {
        guard let session, !session.connectedPeers.isEmpty,
              sessionKey != nil else { return }
        guard !isTalking else { return }
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
            // Unreliable voice frames are loss-tolerant; only surface reliable failures.
            if reliable { lastError = "Send failed: \(error.localizedDescription)" }
        }
    }

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
        // MC's lostPeer doesn't fire on unclean disconnects; restart browser to re-fire foundPeer for live peers and prune ghosts.
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
        lastSeenAt = lastSeenAt.filter { discovered.contains(where: { $0.peerID == $0.peerID }) || connectedIDs.contains($0.key) }
    }

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
            // Replace, don't skip: a host re-creating a room keeps the same MCPeerID but advertises a fresh roomID.
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
            // Dedupe by displayName+kind: Bonjour keeps stale MCPeerIDs alive across relaunches, so a single device can appear twice.
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
                // Preserve in-flight connection state across re-discovery.
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
                // Skip 1:1 fallback if a room is active or pending — a wrong-password attempt would otherwise look like 1:1.
                if self.activeRoom == nil,
                   self.activeOneToOne == nil,
                   self.pendingRoomJoin == nil {
                    // Browser restarts every 12s; if .connected fires
                    // during that window the peer can be missing from
                    // `discovered`. Synthesize from peerID so the
                    // chat view still opens.
                    let row = self.discovered.first(where: { $0.peerID == peerID })
                        ?? RadioPeer(
                            peerID: peerID,
                            displayName: peerID.displayName,
                            kind: .oneToOne,
                            room: nil,
                            state: .connected,
                        )
                    self.activeOneToOne = row
                }
                // Room mode skips handshake — sessionKey was derived from id/password.
                if self.activeRoom == nil, self.pendingRoomJoin == nil {
                    self.sendHandshake(to: peerID, on: session)
                }
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
                // Mid-transmission disconnect won't send voiceTalkStop, so clean up speaker state here.
                if self.activeSpeakers.contains(droppedDisplayName) {
                    self.activeSpeakers.remove(droppedDisplayName)
                    RadioVoiceEngine.shared.dropSpeaker(droppedDisplayName)
                }
                if session.connectedPeers.isEmpty {
                    self.activeOneToOne = nil
                    // NOTE: don't bail on `pendingRoomJoin` here. MC routinely flips through .connecting → .notConnected → .connecting before sticking, and pending resolves only on explicit decrypt success/failure.
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let frame = try? self.decoder.decode(RadioFrame.self, from: data) else {
                return
            }
            switch frame {
            case .handshake(let theirPub):
                if self.sessionKey == nil, let myKeys = self.oneToOneKeys {
                    do {
                        self.sessionKey = try RadioCrypto.deriveSessionKey(
                            myPriv: myKeys.priv, theirPub: theirPub,
                        )
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
                    // First successful decrypt while pending = correct password; promote to active.
                    if let pending = self.pendingRoomJoin {
                        self.activeRoom = pending
                        self.pendingRoomJoin = nil
                    }
                    self.handle(payload, fromPeer: peerID)
                } catch {
                    // Decrypt failure on pending join = wrong password; eject. Host or 1:1 peer drops silently.
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
            // TODO: late-joiner challenge flow.
            break
        case .voiceTalkStart(let speaker):
            guard speaker != localPeer.displayName else { return }
            activeSpeakers.insert(speaker)
        case .voiceTalkStop(let speaker):
            guard speaker != localPeer.displayName else { return }
            activeSpeakers.remove(speaker)
            RadioVoiceEngine.shared.dropSpeaker(speaker)
        case .voiceFrame(let speaker, _, let frameData):
            guard speaker != localPeer.displayName else { return }
            // Fallback if the start payload was missed.
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
