import CallKit
import Combine
import Foundation

/// Call coordinator. Owns the call state machine and bridges WebSocket
/// signalling, WebRTC media, and CallKit's system UI.
///
/// **What's wired up:**
/// - WS-driven `call_offer` / `call_answer` / `call_ice` / `call_end` events
///   move both peers' state machines through ringing → connected → ended.
/// - VoIP-push-driven inbound: `VoIPPushService` parses the push and calls
///   `handleVoIPIncoming`, which mirrors the WS path but skips the SwiftUI
///   ringing screen (CallKit shows the system UI instead).
/// - `start()` initiates an outgoing call; `accept()` / `decline()` /
///   `hangUp()` advance us out of ringing or connected.
/// - All user-side actions (Accept / Decline / End) come from CallKit via
///   `CXProviderDelegate` → `CallProvider` → us, so the in-app End-call
///   button and the system lock-screen End button do exactly the same
///   thing.
///
/// Single-call assumption: at most one active call per user. A second
/// inbound `call_offer` while we're busy is auto-declined with reason
/// "busy" so the caller sees a quick rejection instead of a hung UI.
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
    /// True when the user has tapped the minimize button on `CallScreen`.
    /// Root-level `.fullScreenCover` watches this so the in-call surface
    /// dismisses while the call itself stays alive — user can browse
    /// other chats while audio/video keeps running.
    @Published var isMinimized: Bool = false
    /// Set when the peer requests an audio→video upgrade. CallScreen
    /// watches this and renders an Accept/Decline overlay; the user's
    /// answer drives `acceptVideoUpgrade()` / `declineVideoUpgrade()`.
    /// Cleared on response or when the call ends.
    @Published private(set) var incomingVideoUpgrade: Bool = false
    /// True between the moment the local user taps "Turn on camera" and
    /// the moment the peer's renegotiate answer (or decline) lands. Used
    /// to disable the button + show a "waiting" hint so a second tap
    /// can't fire a second offer.
    @Published private(set) var outgoingVideoUpgradePending: Bool = false
    /// Duration of the most recent connected call. Set when the call
    /// transitions out of `.connected` into `.ended` and consumed by
    /// `CallScreen.endedOverlay` to render "Call ended · 2:34". Nil for
    /// calls that never reached connected (declined / cancelled / busy).
    @Published private(set) var lastCallDuration: TimeInterval?

    /// Wall-clock when the current call entered `.connected`. Used to
    /// compute duration on `.ended`. Nil before connect or after we've
    /// rolled the duration into `lastCallDuration`.
    private var connectedAt: Date?

    /// SDP from the most recent inbound offer, kept around until the user
    /// taps Accept (at which point WebRTCManager consumes it). Cleared
    /// when the call ends in any direction.
    private var pendingRemoteOffer: String?
    /// SDP for an inbound mid-call renegotiation (audio→video upgrade).
    /// Stashed until the user taps Accept on the upgrade prompt; consumed
    /// by `acceptVideoUpgrade`. Cleared on decline or call end.
    private var pendingRenegotiationOffer: String?
    /// ICE candidates that arrived before we had a peer connection
    /// ready (e.g. between `random_match` and the user tapping Accept).
    /// Drained into WebRTCManager once `accept()` runs.
    private var pendingRemoteIce: [String] = []

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        // Hook locally-generated ICE candidates from libwebrtc into the
        // existing WS signalling pipe. Whichever call we're currently in
        // is the only valid recipient, so we capture it on each emission.
        WebRTCManager.shared.onLocalIceCandidate = { [weak self] candidateJSON in
            self?.shipLocalIce(candidateJSON: candidateJSON)
        }
    }

    // MARK: - public API

    /// Place a call to `contact`. Spins up a local WebRTC peer connection,
    /// builds the offer SDP, and ships it via `call_offer`. The receiving
    /// side decides accept/decline. No-op if another call is already in
    /// flight.
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
        // **Outgoing calls deliberately bypass CallKit.** On iOS 17/18 + libwebrtc
        // the CXStartCallAction transaction triggers an immediate
        // CXEndCallAction the moment the audio session is touched, with
        // no recoverable error path. Apps that hit this (Discord and
        // others) use CallKit for INBOUND only — system ringtone, lock-
        // screen UI, VoIP-push wake-from-killed — and run outgoing
        // through the app's own SwiftUI surface. Inbound still gets the
        // full system-grade experience; outgoing trades the lock-screen
        // UI for "the call actually starts."
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

    /// Accept the currently-ringing inbound call. Builds the WebRTC answer
    /// SDP from the offer we already stashed and ships it back.
    /// Public Accept entry point. Whether the user tapped Accept on
    /// CallKit's system UI or on our SwiftUI CallScreen, both routes
    /// land here. We forward through CallKit's CXAnswerCallAction
    /// transaction so its state stays in sync with ours (and the iOS
    /// status bar stops showing "ringing" the moment we accept).
    /// The actual WebRTC handshake runs when the action delegate
    /// (`provider(_:perform:CXAnswerCallAction)`) calls back into us
    /// via `acceptFromCallKit`.
    func accept() {
        guard case .incomingRinging(let c) = state else {
            print("[CallService] accept() ignored — state not incomingRinging")
            return
        }
        print("[CallService] accept requested → CallKit (callID=\(c.id))")
        CallProvider.shared.requestAnswerCall(callID: c.id)
    }

    /// Public Decline entry point — same routing logic as `accept()` but
    /// for the rejection path. CallKit's CXEndCallAction transaction
    /// fires our delegate, which runs `endFromCallKit` → declines
    /// internally + clears the system UI.
    func decline() {
        guard case .incomingRinging(let c) = state else { return }
        print("[CallService] decline requested → CallKit (callID=\(c.id))")
        CallProvider.shared.requestEndCall(callID: c.id)
    }

    /// End an outgoing or active call. Outgoing calls bypass CallKit
    /// entirely (see `start`), so the in-app End button reaches us
    /// directly here — we tear down WebRTC + signal the peer ourselves.
    /// For connected calls that originated as inbound (CallKit-mediated),
    /// we route through CallKit's CXEndCallAction so its UI clears. For
    /// outgoing-now-connected calls there's no CallKit UI to clear, just
    /// run the local teardown.
    func hangUp() {
        switch state {
        case .outgoingRinging(let c):
            // Outbound calls don't have a CallKit entry — just unwind locally.
            sendEnd(call: c, reason: "cancelled")
            state = .ended(c, reason: "cancelled")
            teardownAfterEnd()
            scheduleEndedClear()
        case .connected(let c):
            // Was the connected call inbound (registered with CallKit) or
            // outbound (no CallKit)? `uuid(forCallID:)` returns nil for
            // outbound — drive the right path either way.
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

    /// CallKit invoked our CXAnswerCallAction delegate — this is THE place
    /// the WebRTC handshake actually runs. Whether the user tapped on the
    /// system UI or our SwiftUI Accept button, both paths converged on a
    /// CXAnswerCallAction request and ended up here.
    func acceptFromCallKit(uuid: UUID) {
        guard case .incomingRinging(let c) = state,
              let offerSdp = pendingRemoteOffer
        else {
            print("[CallService] acceptFromCallKit ignored — state=\(state)")
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

    /// CallKit invoked our CXEndCallAction delegate — user declined an
    /// inbound or hung up a connected call. We end the wire-side call,
    /// flip our state to .ended, and let CallKit clear its UI on its own
    /// (we don't need to call `reportEnded` here because the action
    /// fulfilment already does that for us).
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

    /// Called from `VoIPPushService` when a VoIP push wakes the app with
    /// an inbound call. The push payload carries the offer SDP, so we
    /// stash it the same way the WS path does — when the user accepts via
    /// CallKit, `accept()` runs and finds the SDP ready.
    func handleVoIPIncoming(callKitUUID: UUID, callID: String, fromUIN: Int, nickname: String, media: CallMedia, sdp: String) {
        // Only accept if we're idle. A second inbound during an active
        // call is auto-rejected (we already reported it to CallKit so the
        // user briefly saw "missed" — that's fine).
        guard !state.isActive else {
            CallProvider.shared.reportEnded(callID: callID, reason: .declinedElsewhere)
            sendEnd(call: Call(id: callID, peerUIN: fromUIN, peerNickname: nickname, media: media, direction: .incoming),
                    reason: "busy")
            return
        }
        // Prefer the local Contact nickname over whatever the push carried.
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
    }

    /// Dismiss the .ended overlay manually (without waiting for auto-clear).
    /// The UI's "Close" button calls this.
    func clearEnded() {
        if case .ended = state { state = .idle }
    }

    /// Tuck the in-call full-screen surface away so the user can browse
    /// chats / send messages while the call keeps running. WebRTC keeps
    /// streaming audio + video; only the SwiftUI presentation collapses.
    /// Restored by `expand()` when the user taps the floating bar.
    func minimize() {
        guard case .connected = state else { return }
        isMinimized = true
    }

    /// Bring the full-screen call surface back. Called from the floating
    /// `CallMinimizedBar` tap.
    func expand() {
        isMinimized = false
    }

    // MARK: - audio → video upgrade

    /// Caller side of mid-call upgrade. Local camera lights up immediately
    /// (PIP appears in CallScreen) so the user gets instant feedback;
    /// the renegotiation offer ships to the peer who shows an Accept /
    /// Decline prompt. If the peer declines, we roll the local video
    /// track back off via `handleRenegotiateDecline`.
    ///
    /// No-op if we're not in a connected audio call, or if an upgrade
    /// is already in flight (the SwiftUI button disables itself on
    /// `outgoingVideoUpgradePending` but a stale tap could still arrive).
    func requestVideoUpgrade() {
        guard case .connected(var c) = state, c.media == .audio else { return }
        guard !outgoingVideoUpgradePending else { return }
        outgoingVideoUpgradePending = true
        let call = c
        Task {
            do {
                let sdp = try await WebRTCManager.shared.upgradeToVideo()
                // Flip the local Call to .video so the SwiftUI control bar
                // and renderer switch immediately. The peer will follow
                // when they accept (or stay on audio if they decline,
                // and we roll back from `handleRenegotiateDecline`).
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

    /// Callee side. User accepted the inbound upgrade prompt — bring up
    /// our own camera, build the answer SDP, and ship it back. Flips our
    /// local `Call.media` to `.video` so the UI switches to video chrome.
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
                // Tell the caller we couldn't complete the upgrade. They
                // roll back to audio-only on their side too.
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

    /// Callee side. User tapped Decline on the inbound upgrade prompt —
    /// notify the caller so they roll back their local video, and
    /// dismiss the prompt locally.
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
        // Only valid for the call we're currently in. Stray events for
        // other call IDs are dropped.
        guard case .connected(let c) = state, c.id == callID else { return }
        // We only support the audio→video upgrade flow today. If we're
        // already on video, auto-accept silently (idempotent reapply).
        guard c.media == .audio else {
            // Auto-accept: build an answer with our existing video track.
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
        // Flip back to audio so the UI re-renders the audio chrome.
        if c.media == .video {
            c.media = .audio
            state = .connected(c)
        }
    }

    // MARK: - WS plumbing

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .callOffer(let from, let nickname, let callID, let media, let sdp):
            handleIncomingOffer(from: from, nickname: nickname, callID: callID, media: media, sdp: sdp)
        case .callAnswer(_, let callID, let sdp):
            print("[CallService] WS callAnswer callID=\(callID) sdp=\(sdp.count)ch")
            // Match against our outgoing call (stale/late ones are ignored).
            if case .outgoingRinging(let c) = state, c.id == callID {
                Task {
                    do {
                        try await WebRTCManager.shared.handleAnswer(remoteSdp: sdp)
                        print("[CallService] handleAnswer OK, going connected")
                        state = .connected(c)
                        // Callee picked up — kill the ringback before
                        // their voice arrives so the two don't overlap.
                        RingbackPlayer.shared.stop()
                        CallProvider.shared.reportConnected(callID: c.id)
                        // Drain any ICE candidates the callee sent before
                        // their answer reached us (rare but possible).
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
            // ICE for the active call goes straight to libwebrtc. ICE that
            // arrived before we had a peer connection ready (callee still
            // in `incomingRinging` state, hasn't tapped Accept) gets stashed.
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

    /// Caller-side hangup landed for the call we're currently in
    /// (or the recipient's UI is still ringing on a now-cancelled
    /// call). Tears the call down on this side and clears CallKit.
    /// Reachable both from the regular WS `callEnd` event and from
    /// the VoIP-push fallback `kind=end` payload that the server
    /// fires when the recipient's WS isn't connected.
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
            // No matching active call — could be a stray end push
            // for a call we already cleaned up locally, or the
            // CallKit UUID mapping wasn't registered yet (race
            // between the original VoIP offer push and this end
            // push). Ask CallProvider to dismiss anyway in case
            // the UUID mapping landed via a different code path.
            CallProvider.shared.reportEnded(
                callID: callID,
                reason: callKitReason(forWireReason: reason)
            )
        }
    }

    private func handleIncomingOffer(from: Int, nickname: String, callID: String, media: CallMedia, sdp: String) {
        print("[CallService] WS callOffer callID=\(callID) from=\(from) nick=\(nickname) media=\(media) sdp=\(sdp.count)ch")
        // Single-call assumption — auto-decline a second inbound while busy.
        if state.isActive {
            print("[CallService] busy — auto-declining incoming")
            WebSocketService.shared.sendCallSignal(
                type: "call_end",
                toUIN: from,
                callID: callID,
                extras: ["reason": "busy"]
            )
            return
        }
        // Prefer the caller's name from our local Contact list (it's the
        // nickname *we* gave them). Fall back to whatever the wire carries.
        let displayName = ContactService.shared.contacts
            .first(where: { $0.uin == from })?.nickname ?? nickname
        let call = Call(
            id: callID,
            peerUIN: from,
            peerNickname: displayName,
            media: media,
            direction: .incoming
        )
        // Stash the offer SDP — actual peer-connection setup happens on
        // accept() so we don't spin up the camera/mic until the user agrees.
        pendingRemoteOffer = sdp
        pendingRemoteIce.removeAll()
        state = .incomingRinging(call)
        // Show CallKit's system incoming UI. Foreground or background, locked
        // or unlocked — same surface, same ringtone.
        CallProvider.shared.reportIncoming(
            callID: callID,
            peerName: displayName,
            hasVideo: media == .video
        )
    }

    /// Map our wire-level `reason` strings ("declined", "hangup", "busy",
    /// "expired", "setup_failed") to CallKit's enum so the system call UI
    /// shows the right "Missed" / "Failed" / "Ended" copy.
    private func callKitReason(forWireReason reason: String) -> CXCallEndedReason {
        switch reason {
        case "declined":     return .declinedElsewhere
        case "busy":         return .unanswered
        case "expired":      return .unanswered
        case "setup_failed": return .failed
        default:             return .remoteEnded
        }
    }

    /// Forward locally-generated ICE candidates from libwebrtc to the
    /// active peer over the existing WS signal pipe. Called by the
    /// `WebRTCManager.onLocalIceCandidate` hook configured in init.
    private func shipLocalIce(candidateJSON: String) {
        guard let c = state.call else { return }
        WebSocketService.shared.sendCallSignal(
            type: "call_ice",
            toUIN: c.peerUIN,
            callID: c.id,
            extras: ["candidate": candidateJSON]
        )
    }

    /// Tear down the WebRTC peer connection + capture pipeline. Called
    /// from every path that exits the call (decline, hangup, peer end).
    /// Idempotent — safe even if no peer connection ever materialised.
    private func teardownAfterEnd() {
        WebRTCManager.shared.close()
        // Ringback only plays during outgoingRinging; stop here as a
        // belt-and-suspenders so it can never bleed into the post-call
        // .ended overlay or survive into the next call.
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

    /// Auto-dismiss the `.ended` overlay after a short beat. Long enough for
    /// the user to see WHY the call ended ("declined", "busy", "cancelled"),
    /// short enough not to block them from going back to the chat.
    private func scheduleEndedClear() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.clearEnded()
        }
    }

    /// Burn-account hook — drop any in-flight call without bothering to
    /// signal the peer (their socket will close when our identity flips
    /// anyway, and the call will naturally fall out via 410 on send).
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

    /// Watches `state` for `.connected` (start the duration clock),
    /// `.ended` (compute duration + log to chat history), and `.idle`
    /// (clear minimized). Wraps logic that used to be sprinkled across
    /// every entry point so we never forget to log a call summary.
    private func reactToStateTransition(from old: State, to new: State) {
        switch new {
        case .connected:
            // Only start the clock once per connection — re-entry to
            // .connected (shouldn't happen but defensively) leaves the
            // first timestamp.
            if connectedAt == nil { connectedAt = Date() }
        case .ended(let call, let reason):
            // Skip if we'd already booked this transition (idempotent).
            if old.isEnded { return }
            let duration = connectedAt.map { Date().timeIntervalSince($0) }
            lastCallDuration = duration
            connectedAt = nil
            // Minimize flag follows the call lifecycle — a fresh call
            // shouldn't inherit the previous one's state.
            isMinimized = false
            logCallEnded(call: call, reason: reason, duration: duration)
        case .idle:
            connectedAt = nil
            isMinimized = false
        default:
            break
        }
    }

    /// Append a `.systemNotice` row to the regular 1:1 thread describing
    /// the call's outcome and duration. Random-chat sessions don't get
    /// logged — they're ephemeral by design.
    private func logCallEnded(call: Call, reason: String, duration: TimeInterval?) {
        // Random-chat is in-memory only; nothing to write to. The
        // user's regular chat history isn't the right place for "talked
        // to a stranger for 2 minutes" entries either.
        if RandomChatService.shared.activePeer != nil { return }

        let directionLabel = (call.direction == .outgoing
            ? "chat.call.outgoing" : "chat.call.incoming").localized
        let mediaLabel = (call.media == .video
            ? "chat.call.media.video" : "chat.call.media.voice").localized

        let summary: String
        if let d = duration, d >= 1 {
            // Reached connected — log the duration.
            summary = "\(directionLabel) \(mediaLabel) · \(Self.formatDuration(d))"
        } else {
            // Never connected — describe why instead. Direction-aware
            // outcomes (e.g. "cancelled" reads as "Missed" on the
            // recipient side) flip via the inbound vs outbound check.
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
            // System notices are display-only; the senderUIN field has
            // to be something but the row is rendered centred without
            // any sender chrome.
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
