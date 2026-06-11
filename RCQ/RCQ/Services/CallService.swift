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

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        WebRTCManager.shared.onLocalIceCandidate = { [weak self] candidateJSON in
            self?.shipLocalIce(candidateJSON: candidateJSON)
        }
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
        print("[CallService] accept requested -> CallKit (callID=\(c.id))")
        CallProvider.shared.requestAnswerCall(callID: c.id)
    }

    func decline() {
        guard case .incomingRinging(let c) = state else { return }
        print("[CallService] decline requested -> CallKit (callID=\(c.id))")
        CallProvider.shared.requestEndCall(callID: c.id)
    }

    func hangUp() {
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
        guard case .incomingRinging(let c) = state,
              let offerSdp = pendingRemoteOffer
        else {
            print("[CallService] acceptFromCallKit ignored, state=\(state)")
            return
        }
        let call = c
        print("[CallService] acceptFromCallKit running handleOffer (callID=\(call.id))")
        Task {
            do {
                let answerSdp = try await WebRTCManager.shared.handleOffer(
                    remoteSdp: offerSdp,
                    media: call.media
                )
                print("[CallService] handleOffer OK, going connected, sending answer (\(answerSdp.count)ch)")
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
            } catch {
                print("[CallService] handleOffer failed: \(error)")
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
            handle(.callIce(fromUIN: fromUIN, callID: callID, candidateJSON: data["candidate"] ?? ""))
        case "call_end":
            handle(.callEnd(fromUIN: fromUIN, callID: callID, reason: data["reason"] ?? "ended"))
        case "call_renegotiate":
            handle(.callRenegotiate(fromUIN: fromUIN, callID: callID, sdp: sdp))
        case "call_renegotiate_answer":
            handle(.callRenegotiateAnswer(fromUIN: fromUIN, callID: callID, sdp: sdp))
        case "call_renegotiate_decline":
            handle(.callRenegotiateDecline(fromUIN: fromUIN, callID: callID))
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
        case .callRenegotiate(_, let callID, let sdp):
            handleIncomingRenegotiate(callID: callID, sdp: sdp)
        case .callRenegotiateAnswer(_, let callID, let sdp):
            handleRenegotiateAnswer(callID: callID, sdp: sdp)
        case .callRenegotiateDecline(_, let callID):
            handleRenegotiateDecline(callID: callID)
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
        state = .incomingRinging(call)
        armRingTimeout(callID: call.id)
        CallProvider.shared.reportIncoming(
            callID: callID,
            peerName: displayName,
            hasVideo: media == .video
        )
    }

    private func callKitReason(forWireReason reason: String) -> CXCallEndedReason {
        switch reason {
        case "declined":     return .declinedElsewhere
        case "busy":         return .unanswered
        case "expired":      return .unanswered
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
        WebRTCManager.shared.close()
        RingbackPlayer.shared.stop()
        pendingRemoteOffer = nil
        pendingRemoteIce.removeAll()
        pendingRenegotiationOffer = nil
        incomingVideoUpgrade = false
        outgoingVideoUpgradePending = false
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
