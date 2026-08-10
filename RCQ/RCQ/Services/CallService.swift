import CallKit
import Combine
import Foundation

/// Call state machine. Bridges WS signalling, WebRTC media, and CallKit.
/// Single-call invariant: a second inbound `call_offer` while busy is
/// auto-declined with reason "busy".
@MainActor
final class CallService: ObservableObject {
    static let shared = CallService()

    enum State: Equatable {
        case idle
        case outgoingRinging(Call)
        case incomingRinging(Call)
        case connected(Call)
        case ended(Call, reason: String)

        var isActive: Bool {
            if case .idle = self { return false }
            if case .ended = self { return false }
            return true
        }

        var isEnded: Bool {
            if case .ended = self { return true }
            return false
        }

        var call: Call? {
            switch self {
            case .idle: return nil
            case .outgoingRinging(let c), .incomingRinging(let c),
                 .connected(let c): return c
            case .ended(let c, _): return c
            }
        }
    }

    @Published private(set) var state: State = .idle {
        didSet { reactToStateTransition(from: oldValue, to: state) }
    }
    @Published var isMinimized: Bool = false
    @Published private(set) var incomingVideoUpgrade: Bool = false
    @Published private(set) var outgoingVideoUpgradePending: Bool = false
    @Published private(set) var lastCallDuration: TimeInterval?

    private var connectedAt: Date?

    private var pendingRemoteOffer: String?
    private var pendingRenegotiationOffer: String?
    private var pendingRemoteIce: [String] = []

    // True from the moment the user accepts an inbound call until the WebRTC
    // handshake completes (.connected) or fails. iOS 26's CallKit can auto-fire
    // a CXEndCallAction mid-handshake (the held-audio-session regression); that
    // stray end must NOT be relayed to the caller as a "declined", or it kills
    // a call the user is actively answering — exactly the end-then-answer race
    // seen on the wire. Cleared on connect / decline / teardown / new call.
    private var answering = false

    // ICE-recovery state. On a hard ICE drop the caller re-offers (glare-avoided
    // — only the original caller restarts); the callee waits for that re-offer
    // and ends the call if it never recovers.
    private var disconnectGraceTask: Task<Void, Never>?
    private var calleeFailsafeTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var iceRestarting = false
    private var iceRestartAttempts = 0
    // iOS marks .connected on the SDP answer (before ICE connects), so gate
    // recovery on whether ICE actually came up — a setup-time failure should
    // fail fast, not run the full restart budget. Mirrors Android connectedSince.
    private var iceEverConnected = false
    private static let iceDisconnectGraceNs: UInt64 = 4_000_000_000
    private static let iceRestartTimeoutNs: UInt64 = 12_000_000_000
    private static let calleeFailsafeNs: UInt64 = 32_000_000_000
    private static let connectTimeoutNs: UInt64 = 35_000_000_000
    private static let maxIceRestarts = 2

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        WebRTCManager.shared.onLocalIceCandidate = { [weak self] candidateJSON in
            self?.shipLocalIce(candidateJSON: candidateJSON)
        }
        WebRTCManager.shared.onIceConnected = { [weak self] in self?.onIceConnected() }
        WebRTCManager.shared.onIceDisconnected = { [weak self] in self?.onIceDisconnected() }
        WebRTCManager.shared.onIceFailed = { [weak self] in self?.onIceFailed() }
    }

    // MARK: - public API

    func start(toContact contact: Contact, media: CallMedia = .video) {
        guard !state.isActive else { return }
        let call = Call(
            peerUIN: contact.uin,
            peerNickname: contact.nickname,
            media: media,
            direction: .outgoing
        )
        print("[CallService] start outgoing call=\(call.id) to uin=\(contact.uin) media=\(media)")
        answering = false
        state = .outgoingRinging(call)
        armRingTimeout(callID: call.id)
        // outgoing bypasses CallKit: CXStartCallAction + libwebrtc on iOS 17/18 fires an
        // immediate CXEndCallAction once the audio session is touched. Inbound only.
        Task {
            do {
                let sdp = try await WebRTCManager.shared.createOffer(media: media)
                print("[CallService] outgoing: SDP offer ready (\(sdp.count) chars), sending call_offer")
                WebSocketService.shared.sendCallSignal(
                    type: "call_offer",
                    toUIN: contact.uin,
                    callID: call.id,
                    extras: ["media": call.media.rawValue, "sdp": sdp]
                )
                RingbackPlayer.shared.start()
            } catch {
                print("[CallService] createOffer failed: \(error)")
                state = .ended(call, reason: "setup_failed")
                WebRTCManager.shared.close()
                scheduleEndedClear()
            }
        }
    }

    func accept() {
        guard case .incomingRinging(let c) = state else {
            print("[CallService] accept() ignored, state not incomingRinging")
            return
        }
        // Set BEFORE routing through CallKit so a CallKit auto-end that races
        // the answer (iOS 26) is recognised as spurious in endFromCallKit.
        answering = true
        #if targetEnvironment(simulator)
        // No CallKit on the simulator — answer the handshake straight away.
        print("[CallService] accept (simulator) -> direct handshake, no CallKit (callID=\(c.id))")
        performAnswerHandshake()
        #else
        print("[CallService] accept requested -> CallKit (callID=\(c.id))")
        CallProvider.shared.requestAnswerCall(callID: c.id)
        #endif
    }

    func decline() {
        guard case .incomingRinging(let c) = state else { return }
        answering = false
        #if targetEnvironment(simulator)
        print("[CallService] decline (simulator) -> direct end (callID=\(c.id))")
        sendEnd(call: c, reason: "declined")
        state = .ended(c, reason: "declined")
        teardownAfterEnd()
        scheduleEndedClear()
        #else
        print("[CallService] decline requested -> CallKit (callID=\(c.id))")
        CallProvider.shared.requestEndCall(callID: c.id)
        #endif
    }

    func hangUp() {
        answering = false
        switch state {
        case .outgoingRinging(let c):
            sendEnd(call: c, reason: "cancelled")
            state = .ended(c, reason: "cancelled")
            teardownAfterEnd()
            scheduleEndedClear()
        case .connected(let c):
            // outbound calls have no CallKit entry; uuid() returns nil there
            if CallProvider.shared.uuid(forCallID: c.id) != nil {
                CallProvider.shared.requestEndCall(callID: c.id)
            } else {
                sendEnd(call: c, reason: "hangup")
                state = .ended(c, reason: "hangup")
                teardownAfterEnd()
                scheduleEndedClear()
            }
        default:
            break
        }
    }

    // MARK: - CallKit + VoIP entry points

    /// CXAnswerCallAction handler; runs the WebRTC handshake.
    func acceptFromCallKit(uuid: UUID) {
        performAnswerHandshake()
    }

    /// Runs the WebRTC answer + ships `call_answer`. Shared by the CallKit
    /// CXAnswerCallAction path and the simulator's direct-accept path — CallKit
    /// can't present an incoming call on the simulator (reportNewIncomingCall
    /// "succeeds" then iOS instantly auto-ends), so the sim answers without it.
    private func performAnswerHandshake() {
        guard case .incomingRinging(let c) = state,
              let offerSdp = pendingRemoteOffer
        else {
            print("[CallService] performAnswerHandshake ignored, state=\(state)")
            answering = false
            return
        }
        answering = true
        let call = c
        print("[CallService] performAnswerHandshake running handleOffer (callID=\(call.id))")
        Task {
            do {
                let answerSdp = try await WebRTCManager.shared.handleOffer(
                    remoteSdp: offerSdp,
                    media: call.media
                )
                print("[CallService] handleOffer OK, going connected, sending answer (\(answerSdp.count)ch)")
                answering = false
                state = .connected(call)
                WebSocketService.shared.sendCallSignal(
                    type: "call_answer",
                    toUIN: call.peerUIN,
                    callID: call.id,
                    extras: ["sdp": answerSdp]
                )
                for json in pendingRemoteIce {
                    WebRTCManager.shared.addRemoteIce(candidateJSON: json)
                }
                pendingRemoteIce.removeAll()
                pendingRemoteOffer = nil
                armConnectTimeout(call: call)
            } catch {
                print("[CallService] handleOffer failed: \(error)")
                answering = false
                sendEnd(call: call, reason: "setup_failed")
                state = .ended(call, reason: "setup_failed")
                CallProvider.shared.reportEnded(callID: call.id, reason: .failed)
                WebRTCManager.shared.close()
                scheduleEndedClear()
            }
        }
    }

    /// CXEndCallAction handler; reportEnded is implicit in the action fulfilment.
    func endFromCallKit(uuid: UUID) {
        guard let c = state.call else { return }
        // iOS 26 CallKit can fire CXEndCallAction on its own while the user is
        // mid-answer (the held-audio-session regression). The user is accepting,
        // not declining — swallow this stray end so we don't ship a bogus
        // "declined" to the caller and kill the call the handshake is completing.
        if answering {
            print("[CallService] endFromCallKit IGNORED — answer in flight (callID=\(c.id))")
            return
        }
        print("[CallService] endFromCallKit (state=\(stateLabel)) callID=\(c.id)")
        let reason: String
        switch state {
        case .incomingRinging: reason = "declined"
        case .connected:       reason = "hangup"
        default:               reason = "cancelled"
        }
        sendEnd(call: c, reason: reason)
        state = .ended(c, reason: reason)
        teardownAfterEnd()
        scheduleEndedClear()
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "idle"
        case .outgoingRinging: return "outgoingRinging"
        case .incomingRinging: return "incomingRinging"
        case .connected: return "connected"
        case .ended: return "ended"
        }
    }

    /// Inbound call delivered via VoIP push; same accept/decline pipeline as the WS path, just without the SwiftUI ringer.
    func handleVoIPIncoming(callKitUUID: UUID, callID: String, fromUIN: Int, nickname: String, media: CallMedia, sdp: String) {
        guard !state.isActive else {
            CallProvider.shared.reportEnded(callID: callID, reason: .declinedElsewhere)
            sendEnd(call: Call(id: callID, peerUIN: fromUIN, peerNickname: nickname, media: media, direction: .incoming),
                    reason: "busy")
            return
        }
        let displayName = ContactService.shared.contacts
            .first(where: { $0.uin == fromUIN })?.nickname ?? nickname
        let call = Call(
            id: callID,
            peerUIN: fromUIN,
            peerNickname: displayName,
            media: media,
            direction: .incoming
        )
        pendingRemoteOffer = sdp
        pendingRemoteIce.removeAll()
        answering = false
        state = .incomingRinging(call)
        armRingTimeout(callID: call.id)
    }

    func clearEnded() {
        if case .ended = state { state = .idle }
    }

    func minimize() {
        guard case .connected = state else { return }
        isMinimized = true
    }

    func expand() {
        isMinimized = false
    }

    // MARK: - audio -> video upgrade

    func requestVideoUpgrade() {
        guard case .connected(var c) = state, c.media == .audio else { return }
        guard !outgoingVideoUpgradePending else { return }
        outgoingVideoUpgradePending = true
        let call = c
        Task {
            do {
                let sdp = try await WebRTCManager.shared.upgradeToVideo()
                c.media = .video
                state = .connected(c)
                WebSocketService.shared.sendCallSignal(
                    type: "call_renegotiate",
                    toUIN: call.peerUIN,
                    callID: call.id,
                    extras: ["sdp": sdp]
                )
            } catch {
                print("[CallService] upgradeToVideo failed: \(error)")
                outgoingVideoUpgradePending = false
                WebRTCManager.shared.rollbackVideoUpgrade()
            }
        }
    }

    func acceptVideoUpgrade() {
        guard case .connected(var c) = state, let offerSdp = pendingRenegotiationOffer else {
            incomingVideoUpgrade = false
            pendingRenegotiationOffer = nil
            return
        }
        incomingVideoUpgrade = false
        let call = c
        Task {
            do {
                let answerSdp = try await WebRTCManager.shared.handleRenegotiationOffer(remoteSdp: offerSdp)
                c.media = .video
                state = .connected(c)
                WebSocketService.shared.sendCallSignal(
                    type: "call_renegotiate_answer",
                    toUIN: call.peerUIN,
                    callID: call.id,
                    extras: ["sdp": answerSdp]
                )
                pendingRenegotiationOffer = nil
            } catch {
                print("[CallService] handleRenegotiationOffer failed: \(error)")
                WebSocketService.shared.sendCallSignal(
                    type: "call_renegotiate_decline",
                    toUIN: call.peerUIN,
                    callID: call.id
                )
                WebRTCManager.shared.rollbackVideoUpgrade()
                pendingRenegotiationOffer = nil
            }
        }
    }

    func declineVideoUpgrade() {
        guard case .connected(let c) = state else {
            incomingVideoUpgrade = false
            pendingRenegotiationOffer = nil
            return
        }
        incomingVideoUpgrade = false
        pendingRenegotiationOffer = nil
        WebSocketService.shared.sendCallSignal(
            type: "call_renegotiate_decline",
            toUIN: c.peerUIN,
            callID: c.id
        )
    }

    private func handleIncomingRenegotiate(callID: String, sdp: String) {
        guard case .connected(let c) = state, c.id == callID else { return }
        // already on video: idempotent auto-accept with existing track
        guard c.media == .audio else {
            let call = c
            Task {
                do {
                    let answerSdp = try await WebRTCManager.shared.handleRenegotiationOffer(remoteSdp: sdp)
                    WebSocketService.shared.sendCallSignal(
                        type: "call_renegotiate_answer",
                        toUIN: call.peerUIN,
                        callID: call.id,
                        extras: ["sdp": answerSdp]
                    )
                } catch {
                    print("[CallService] auto-accept renegotiate failed: \(error)")
                }
            }
            return
        }
        pendingRenegotiationOffer = sdp
        incomingVideoUpgrade = true
    }

    private func handleRenegotiateAnswer(callID: String, sdp: String) {
        guard case .connected(let c) = state, c.id == callID else { return }
        outgoingVideoUpgradePending = false
        Task {
            do {
                try await WebRTCManager.shared.handleRenegotiationAnswer(remoteSdp: sdp)
            } catch {
                print("[CallService] handleRenegotiationAnswer failed: \(error)")
            }
        }
    }

    private func handleRenegotiateDecline(callID: String) {
        guard case .connected(var c) = state, c.id == callID else { return }
        outgoingVideoUpgradePending = false
        WebRTCManager.shared.rollbackVideoUpgrade()
        if c.media == .video {
            c.media = .audio
            state = .connected(c)
        }
    }

    // MARK: - ICE recovery

    /// Media reconnected (or first connected): clear any in-flight recovery and
    /// restore the per-incident restart budget (it's per-drop, not per-call).
    private func onIceConnected() {
        // Cancels the connect timeout too: media is flowing, so the handshake
        // that timeout was watching finished.
        cancelRecoveryTimers()
        iceRestarting = false
        iceRestartAttempts = 0
        iceEverConnected = true
    }

    /// Transient DISCONNECTED on a live call: give ICE a grace window to
    /// self-heal before forcing a restart, so a brief network hiccup doesn't
    /// tear down a working call.
    private func onIceDisconnected() {
        guard case .connected(let c) = state, iceEverConnected, disconnectGraceTask == nil else { return }
        disconnectGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.iceDisconnectGraceNs)
            guard let self else { return }
            self.disconnectGraceTask = nil
            if case .connected(let cur) = self.state, cur.id == c.id {
                self.attemptIceRestartOrEnd(call: cur)
            }
        }
    }

    /// Hard ICE FAILED — connectivity checks are exhausted; try to recover.
    /// (Previously iOS ignored ICE failure entirely, leaving a dead-media call
    /// stuck on "connected" until the user hung up.)
    private func onIceFailed() {
        guard case .connected(let c) = state else { return }
        // A failure before ICE ever connected is a setup failure (cross-NAT /
        // dead TURN) — end fast rather than burn the full restart budget on a
        // call that never carried media. Mirrors Android's connectedSince gate.
        guard iceEverConnected else { endWithPeerDisconnected(call: c); return }
        cancelDisconnectGrace()
        attemptIceRestartOrEnd(call: c)
    }

    /// Only the original caller re-offers (glare avoidance); the callee waits
    /// for that re-offer and ends if it never recovers. The caller retries up
    /// to `maxIceRestarts` times, then gives up with "peer_disconnected".
    private func attemptIceRestartOrEnd(call: Call) {
        // An ICE restart reuses the offer/answer machinery — don't collide with
        // a video-upgrade renegotiation mid-handshake; just end if one's live.
        if outgoingVideoUpgradePending || pendingRenegotiationOffer != nil || incomingVideoUpgrade {
            endWithPeerDisconnected(call: call); return
        }
        guard call.direction == .outgoing else {
            scheduleCalleeFailsafe(call: call); return
        }
        if iceRestarting { return } // a restart is already in flight; let it run
        if iceRestartAttempts >= Self.maxIceRestarts { endWithPeerDisconnected(call: call); return }
        iceRestarting = true
        iceRestartAttempts += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sdp = try await WebRTCManager.shared.restartIce()
                WebSocketService.shared.sendCallSignal(
                    type: "call_ice_restart",
                    toUIN: call.peerUIN,
                    callID: call.id,
                    extras: ["sdp": sdp]
                )
                self.armIceRestartTimeout(call: call)
            } catch {
                print("[CallService] ICE restart offer failed: \(error)")
                self.iceRestarting = false
                self.endWithPeerDisconnected(call: call)
            }
        }
    }

    /// If a caller's restart hasn't reconnected in time, retry (within budget)
    /// or give up. No-op once media reconnects (onIceConnected clears the flag).
    private func armIceRestartTimeout(call: Call) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.iceRestartTimeoutNs)
            guard let self, self.iceRestarting else { return }
            guard case .connected(let cur) = self.state, cur.id == call.id else { return }
            self.iceRestarting = false
            self.attemptIceRestartOrEnd(call: cur)
        }
    }

    /// Callee side: the caller owns the restart, so just wait. If the call
    /// hasn't recovered after a generous window (spanning the caller's whole
    /// restart budget), end it rather than sit on dead media forever.
    private func scheduleCalleeFailsafe(call: Call) {
        guard calleeFailsafeTask == nil else { return }
        calleeFailsafeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.calleeFailsafeNs)
            guard let self else { return }
            self.calleeFailsafeTask = nil
            if case .connected(let cur) = self.state, cur.id == call.id {
                self.endWithPeerDisconnected(call: cur)
            }
        }
    }

    /// Peer's ICE-restart offer (its connection dropped and it re-gathered);
    /// answer it in place so media resumes without re-ringing.
    private func handleIncomingIceRestart(callID: String, sdp: String) {
        guard case .connected(let c) = state, c.id == callID, !sdp.isEmpty else { return }
        // Don't answer a restart while our own renegotiation (video upgrade) is
        // mid-handshake — the pc isn't stable, so setRemote(offer) would throw.
        if outgoingVideoUpgradePending || pendingRenegotiationOffer != nil || incomingVideoUpgrade { return }
        let call = c
        Task { @MainActor in
            do {
                let answerSdp = try await WebRTCManager.shared.handleIceRestartOffer(remoteSdp: sdp)
                WebSocketService.shared.sendCallSignal(
                    type: "call_ice_restart_answer",
                    toUIN: call.peerUIN,
                    callID: call.id,
                    extras: ["sdp": answerSdp]
                )
            } catch {
                print("[CallService] handleIceRestartOffer failed: \(error)")
            }
        }
    }

    private func handleIceRestartAnswer(callID: String, sdp: String) {
        guard case .connected(let c) = state, c.id == callID, !sdp.isEmpty else { return }
        Task { @MainActor in
            do {
                try await WebRTCManager.shared.handleIceRestartAnswer(remoteSdp: sdp)
            } catch {
                print("[CallService] handleIceRestartAnswer failed: \(error)")
            }
        }
    }

    /// Local decision to end an unrecoverable call: signal the peer, then end.
    private func endWithPeerDisconnected(call: Call) {
        guard case .connected = state else { return }
        sendEnd(call: call, reason: "peer_disconnected")
        state = .ended(call, reason: "peer_disconnected")
        CallProvider.shared.reportEnded(
            callID: call.id,
            reason: callKitReason(forWireReason: "peer_disconnected")
        )
        teardownAfterEnd()
        scheduleEndedClear()
    }

    private func cancelDisconnectGrace() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
    }

    private func cancelRecoveryTimers() {
        disconnectGraceTask?.cancel(); disconnectGraceTask = nil
        calleeFailsafeTask?.cancel(); calleeFailsafeTask = nil
        connectTimeoutTask?.cancel(); connectTimeoutTask = nil
    }

    /// The SDP handshake is done but ICE may never complete (dead TURN path,
    /// symmetric NAT on both ends). Without this the call sits on a silent
    /// "Connecting…" forever, and on iOS it also sits in the system call UI,
    /// because `.connected` here means "the answer landed", not "media flows".
    /// Android has ended such calls at 35s since the same bug was found there;
    /// iOS had no equivalent. No-op once ICE actually connects.
    private func armConnectTimeout(call: Call) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeoutNs)
            guard let self, !Task.isCancelled else { return }
            self.connectTimeoutTask = nil
            guard case .connected(let cur) = self.state,
                  cur.id == call.id, !self.iceEverConnected else { return }
            print("[CallService] connect timeout call=\(call.id.prefix(8)) — ICE never came up")
            self.sendEnd(call: cur, reason: "setup_failed")
            self.state = .ended(cur, reason: "setup_failed")
            CallProvider.shared.reportEnded(callID: cur.id, reason: .failed)
            self.teardownAfterEnd()
            self.scheduleEndedClear()
        }
    }

    private func resetRecoveryState() {
        cancelRecoveryTimers()
        iceRestarting = false
        iceRestartAttempts = 0
        iceEverConnected = false
    }

    // MARK: - cross-island signaling (§5d)

    /// A decrypted cross-island call envelope (inner kind "call") re-enters
    /// the SAME state machine as a live WS signal. Replies route back
    /// cross-island automatically: `WebSocketService.sendCallSignal` branches
    /// on the peer being a CrossIslandStore contact.
    func handleCrossIslandSignal(sig: String, fromUIN: Int, callID: String, data: [String: String]) {
        let sdp = data["sdp"] ?? ""
        switch sig {
        case "call_offer":
            let media = CallMedia(rawValue: data["media"] ?? "video") ?? .video
            handle(.callOffer(fromUIN: fromUIN, nickname: String(fromUIN), callID: callID, media: media, sdp: sdp))
        case "call_answer":
            handle(.callAnswer(fromUIN: fromUIN, callID: callID, sdp: sdp))
        case "call_ice":
            // Cross-island calls may batch a burst of trickle candidates into
            // one envelope (`candidates` = JSON array string); fall back to a
            // single `candidate` for older senders / same-island.
            if let batch = data["candidates"],
               let arr = (try? JSONSerialization.jsonObject(with: Data(batch.utf8))) as? [String] {
                for cand in arr {
                    handle(.callIce(fromUIN: fromUIN, callID: callID, candidateJSON: cand))
                }
            } else {
                handle(.callIce(fromUIN: fromUIN, callID: callID, candidateJSON: data["candidate"] ?? ""))
            }
        case "call_end":
            handle(.callEnd(fromUIN: fromUIN, callID: callID, reason: data["reason"] ?? "ended"))
        case "call_unreachable":
            handle(.callUnreachable(fromUIN: fromUIN, callID: callID))
        case "call_renegotiate":
            handle(.callRenegotiate(fromUIN: fromUIN, callID: callID, sdp: sdp))
        case "call_renegotiate_answer":
            handle(.callRenegotiateAnswer(fromUIN: fromUIN, callID: callID, sdp: sdp))
        case "call_renegotiate_decline":
            handle(.callRenegotiateDecline(fromUIN: fromUIN, callID: callID))
        case "call_ice_restart":
            handle(.callIceRestart(fromUIN: fromUIN, callID: callID, sdp: sdp))
        case "call_ice_restart_answer":
            handle(.callIceRestartAnswer(fromUIN: fromUIN, callID: callID, sdp: sdp))
        default:
            break
        }
    }

    /// §5d: a STALE cross-island offer (offline-queue drains deliver
    /// hours-old rows) never rings — file the missed-call row directly.
    func fileMissedCall(fromUIN: Int, media: CallMedia) {
        let nickname = ContactService.shared.contacts
            .first(where: { $0.uin == fromUIN })?.nickname ?? String(fromUIN)
        let call = Call(peerUIN: fromUIN, peerNickname: nickname, media: media, direction: .incoming)
        logCallEnded(call: call, reason: "expired", duration: nil)
    }

    /// Ringing watchdog, both directions. Outgoing: the offer can be silently
    /// lost (peer offline, an old client ignoring a §5d cross-island call
    /// envelope) — stop ringback after 60s as "no answer". Incoming: a dead
    /// caller never sends call_end — stop ringing after 60s as missed.
    private func armRingTimeout(callID: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, let c = self.state.call, c.id == callID else { return }
            switch self.state {
            case .outgoingRinging:
                self.sendEnd(call: c, reason: "unanswered")
                self.state = .ended(c, reason: "unanswered")
                self.teardownAfterEnd()
                self.scheduleEndedClear()
            case .incomingRinging:
                self.state = .ended(c, reason: "expired")
                CallProvider.shared.reportEnded(callID: c.id, reason: .unanswered)
                self.teardownAfterEnd()
                self.scheduleEndedClear()
            default:
                break
            }
        }
    }

    // MARK: - WS plumbing

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .callOffer(let from, let nickname, let callID, let media, let sdp):
            handleIncomingOffer(from: from, nickname: nickname, callID: callID, media: media, sdp: sdp)
        case .callAnswer(_, let callID, let sdp):
            print("[CallService] WS callAnswer callID=\(callID) sdp=\(sdp.count)ch")
            if case .outgoingRinging(let c) = state, c.id == callID {
                Task {
                    do {
                        try await WebRTCManager.shared.handleAnswer(remoteSdp: sdp)
                        print("[CallService] handleAnswer OK, going connected")
                        state = .connected(c)
                        RingbackPlayer.shared.stop()
                        CallProvider.shared.reportConnected(callID: c.id)
                        for json in pendingRemoteIce {
                            WebRTCManager.shared.addRemoteIce(candidateJSON: json)
                        }
                        pendingRemoteIce.removeAll()
                        armConnectTimeout(call: c)
                    } catch {
                        print("[CallService] handleAnswer failed: \(error)")
                        sendEnd(call: c, reason: "setup_failed")
                        state = .ended(c, reason: "setup_failed")
                        CallProvider.shared.reportEnded(callID: c.id, reason: .failed)
                        teardownAfterEnd()
                        scheduleEndedClear()
                    }
                }
            }
        case .callIce(_, let callID, let candidateJSON):
            // stash ICE while still ringing (no peer connection yet)
            guard let c = state.call, c.id == callID else { break }
            switch state {
            case .incomingRinging:
                pendingRemoteIce.append(candidateJSON)
            default:
                WebRTCManager.shared.addRemoteIce(candidateJSON: candidateJSON)
            }
        case .callEnd(_, let callID, let reason):
            print("[CallService] WS callEnd callID=\(callID) reason=\(reason)")
            handleRemoteEnd(callID: callID, reason: reason)
        case .callUnreachable(_, let callID):
            // Nothing is going to ring on the other side: the island has neither
            // a socket nor a push endpoint for them. End now rather than play a
            // ringback for a minute and call it "no answer" — the caller was
            // being told they are ignored when they were not being reached.
            // Android has done this since 0.96; iOS ignored the signal entirely.
            print("[CallService] WS callUnreachable callID=\(callID)")
            handleRemoteEnd(callID: callID, reason: "unreachable")
        case .callRenegotiate(_, let callID, let sdp):
            handleIncomingRenegotiate(callID: callID, sdp: sdp)
        case .callRenegotiateAnswer(_, let callID, let sdp):
            handleRenegotiateAnswer(callID: callID, sdp: sdp)
        case .callRenegotiateDecline(_, let callID):
            handleRenegotiateDecline(callID: callID)
        case .callIceRestart(_, let callID, let sdp):
            handleIncomingIceRestart(callID: callID, sdp: sdp)
        case .callIceRestartAnswer(_, let callID, let sdp):
            handleIceRestartAnswer(callID: callID, sdp: sdp)
        default:
            break
        }
    }

    /// Reachable from WS `callEnd` and the VoIP-push `kind=end` fallback.
    func handleRemoteEnd(callID: String, reason: String) {
        if let c = state.call, c.id == callID {
            state = .ended(c, reason: reason)
            CallProvider.shared.reportEnded(
                callID: c.id,
                reason: callKitReason(forWireReason: reason)
            )
            teardownAfterEnd()
            scheduleEndedClear()
        } else {
            CallProvider.shared.reportEnded(
                callID: callID,
                reason: callKitReason(forWireReason: reason)
            )
        }
    }

    private func handleIncomingOffer(from: Int, nickname: String, callID: String, media: CallMedia, sdp: String) {
        print("[CallService] WS callOffer callID=\(callID) from=\(from) nick=\(nickname) media=\(media) sdp=\(sdp.count)ch")
        if state.isActive {
            print("[CallService] busy, auto-declining incoming")
            WebSocketService.shared.sendCallSignal(
                type: "call_end",
                toUIN: from,
                callID: callID,
                extras: ["reason": "busy"]
            )
            return
        }
        let displayName = ContactService.shared.contacts
            .first(where: { $0.uin == from })?.nickname ?? nickname
        let call = Call(
            id: callID,
            peerUIN: from,
            peerNickname: displayName,
            media: media,
            direction: .incoming
        )
        pendingRemoteOffer = sdp
        pendingRemoteIce.removeAll()
        answering = false
        state = .incomingRinging(call)
        armRingTimeout(callID: call.id)
        #if targetEnvironment(simulator)
        // CallKit can't present an incoming call on the simulator (it
        // reportNewIncomingCall-OKs then instantly fires CXEndCallAction). The
        // in-app CallScreen (fullScreenCover on .incomingRinging) shows
        // Answer/Decline instead, so the sim can actually receive calls.
        print("[CallService] simulator: in-app incoming UI, skipping CallKit (callID=\(callID))")
        #else
        CallProvider.shared.reportIncoming(
            callID: callID,
            peerName: displayName,
            hasVideo: media == .video
        )
        #endif
    }

    private func callKitReason(forWireReason reason: String) -> CXCallEndedReason {
        switch reason {
        case "declined":     return .declinedElsewhere
        case "busy":         return .unanswered
        case "expired":      return .unanswered
        // Nobody was reached, so the system call log should not read as an
        // unanswered call the peer chose to sit through.
        case "unreachable":  return .failed
        case "setup_failed": return .failed
        default:             return .remoteEnded
        }
    }

    private func shipLocalIce(candidateJSON: String) {
        guard let c = state.call else { return }
        WebSocketService.shared.sendCallSignal(
            type: "call_ice",
            toUIN: c.peerUIN,
            callID: c.id,
            extras: ["candidate": candidateJSON]
        )
    }

    private func teardownAfterEnd() {
        answering = false
        WebRTCManager.shared.close()
        RingbackPlayer.shared.stop()
        pendingRemoteOffer = nil
        pendingRemoteIce.removeAll()
        pendingRenegotiationOffer = nil
        incomingVideoUpgrade = false
        outgoingVideoUpgradePending = false
        resetRecoveryState()
    }

    private func sendEnd(call: Call, reason: String) {
        WebSocketService.shared.sendCallSignal(
            type: "call_end",
            toUIN: call.peerUIN,
            callID: call.id,
            extras: ["reason": reason]
        )
    }

    private func scheduleEndedClear() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.clearEnded()
        }
    }

    /// Burn-account hook; drops any in-flight call without signalling the peer.
    func wipe() {
        WebRTCManager.shared.close()
        pendingRemoteOffer = nil
        pendingRemoteIce.removeAll()
        pendingRenegotiationOffer = nil
        incomingVideoUpgrade = false
        outgoingVideoUpgradePending = false
        resetRecoveryState()
        connectedAt = nil
        lastCallDuration = nil
        isMinimized = false
        state = .idle
    }

    // MARK: - state-transition reactions

    private func reactToStateTransition(from old: State, to new: State) {
        switch new {
        case .connected:
            if connectedAt == nil { connectedAt = Date() }
        case .ended(let call, let reason):
            if old.isEnded { return }
            let duration = connectedAt.map { Date().timeIntervalSince($0) }
            lastCallDuration = duration
            connectedAt = nil
            isMinimized = false
            logCallEnded(call: call, reason: reason, duration: duration)
        case .idle:
            connectedAt = nil
            isMinimized = false
        default:
            break
        }
    }

    private func logCallEnded(call: Call, reason: String, duration: TimeInterval?) {
        if RandomChatService.shared.activePeer != nil { return }

        let directionLabel = (call.direction == .outgoing
            ? "chat.call.outgoing" : "chat.call.incoming").localized
        let mediaLabel = (call.media == .video
            ? "chat.call.media.video" : "chat.call.media.voice").localized

        let summary: String
        if let d = duration, d >= 1 {
            summary = "\(directionLabel) \(mediaLabel) · \(Self.formatDuration(d))"
        } else {
            let outcomeKey: String
            switch reason {
            case "declined", "declinedElsewhere":
                outcomeKey = "chat.call.outcome.declined"
            case "cancelled":
                outcomeKey = call.direction == .outgoing
                    ? "chat.call.outcome.cancelled"
                    : "chat.call.outcome.missed"
            case "busy":
                outcomeKey = "chat.call.outcome.busy"
            case "expired", "unanswered":
                outcomeKey = call.direction == .outgoing
                    ? "chat.call.outcome.no_answer"
                    : "chat.call.outcome.missed"
            case "unreachable":
                outcomeKey = "chat.call.outcome.unreachable"
            case "setup_failed":
                outcomeKey = "chat.call.outcome.failed"
            case "peer_disconnected":
                outcomeKey = "chat.call.outcome.disconnected"
            default:
                outcomeKey = "chat.call.outcome.ended"
            }
            summary = "\(directionLabel) \(mediaLabel) · \(outcomeKey.localized)"
        }

        let entry = Message(
            id: UUID(),
            thread: .peer(uin: call.peerUIN),
            senderUIN: call.peerUIN,
            isFromMe: false,
            kind: .systemNotice,
            text: summary,
            sentAt: Date(),
            deliveryState: .delivered
        )
        MessageStore.shared.append(entry)
    }

    /// "M:SS" — same format as the live duration label rendered inside
    /// the call screen, so the in-call timer and the history entry agree.
    private static func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
