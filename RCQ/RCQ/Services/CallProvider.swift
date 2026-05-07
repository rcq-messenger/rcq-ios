import AVFoundation
import CallKit
import Foundation
import WebRTC

/// CallKit bridge. Owns one `CXProvider` for the whole app and exposes
/// imperative entry points (`reportOutgoing`, `reportIncoming`,
/// `reportConnected`, `reportEnded`) for `CallService` + `VoIPPushService`
/// to drive. The CallKit delegate translates user-side actions (Accept /
/// Decline / End from the system UI) back into `CallService` calls.
///
/// Why CallKit at all:
///   1. Locked-phone incoming UI looks like the iOS Phone app, with the
///      ringtone iOS picks. Far better UX than a black SwiftUI sheet.
///   2. PushKit VoIP push requires us to call `reportNewIncomingCall`
///      synchronously after a push lands, otherwise iOS kills the app
///      and may suspend VoIP delivery for hours.
///   3. Audio session routing is coordinated with the system Phone app —
///      no fighting over the speaker when both want to ring.
///
/// We disable Recents (`includesCallsInRecents = false`) so RCQ calls
/// don't pollute the iOS Phone app's call history.
final class CallProvider: NSObject, @unchecked Sendable {
    static let shared = CallProvider()

    /// CXProvider is thread-safe per Apple's docs. Exposing it as a
    /// `let` (nonisolated by virtue of immutability) lets the PushKit
    /// delivery handler call `reportNewIncomingCall` synchronously
    /// without crossing an actor boundary — required by iOS 13+ or the
    /// app gets terminated and VoIP delivery is suspended.
    private let provider: CXProvider
    private let controller = CXCallController()

    /// CallKit identifies calls by `UUID`; our wire uses `String` call_id.
    /// Lock-protected because the VoIP-push path needs to register a
    /// fresh mapping synchronously from PushKit's delivery thread before
    /// returning.
    private let mappingLock = NSLock()
    private var _callIDByUUID: [UUID: String] = [:]
    private var _uuidByCallID: [String: UUID] = [:]

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        // Keep RCQ calls out of the iOS Phone app's Recents — they're our
        // chats, not the user's phone history.
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // Hand audio session ownership to libwebrtc but route activation
        // through CallKit. WebRTC sets `useManualAudio = true` here so its
        // audio device manager waits for our explicit `isAudioEnabled`
        // toggle (driven by didActivate / didDeactivate below).
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = true
        rtcSession.isAudioEnabled = false
        // **Pre-configure the audio session category at app start, before
        // any call activity.** CallKit relies on AVAudioSession already
        // having a voice-call category when it activates the session as
        // part of a CXStartCallAction. If the category is still
        // `.soloAmbient` (default) when CallKit fires its activation,
        // libwebrtc rejects the device and CallKit auto-ends the call —
        // which presents to the user as "outgoing call drops a moment
        // after dialing". Setting once here means every call inherits
        // the right setup; per-call tweaks (.defaultToSpeaker for video)
        // happen later in `WebRTCManager.configureAudioSession`.
        rtcSession.lockForConfiguration()
        try? rtcSession.setCategory(
            AVAudioSession.Category.playAndRecord,
            with: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try? rtcSession.setMode(AVAudioSession.Mode.voiceChat)
        rtcSession.unlockForConfiguration()
    }

    // MARK: - mapping helpers (lock-protected, callable from any thread)

    private func register(uuid: UUID, callID: String) {
        mappingLock.lock()
        _callIDByUUID[uuid] = callID
        _uuidByCallID[callID] = uuid
        mappingLock.unlock()
    }

    private func unregister(callID: String) {
        mappingLock.lock()
        if let uuid = _uuidByCallID.removeValue(forKey: callID) {
            _callIDByUUID.removeValue(forKey: uuid)
        }
        mappingLock.unlock()
    }

    /// Public so `CallService.hangUp` can ask "did this call originate
    /// inbound (registered with CallKit) or outbound (skip CallKit)?".
    func uuid(forCallID callID: String) -> UUID? {
        mappingLock.lock()
        defer { mappingLock.unlock() }
        return _uuidByCallID[callID]
    }

    private func callID(forUUID uuid: UUID) -> String? {
        mappingLock.lock()
        defer { mappingLock.unlock() }
        return _callIDByUUID[uuid]
    }

    // MARK: - imperative API
    //
    // None of these are @MainActor anymore — the lock-protected mapping
    // store + CXProvider's own thread-safety mean call sites can be
    // anywhere. PushKit delivery thread (main queue) calls
    // `reportIncoming` synchronously from its `nonisolated` handler
    // without crossing an actor boundary; the call doesn't drop.

    /// Outbound call started. Tells CallKit to spin up the system UI
    /// (in-app banner if foreground, lock-screen entry if locked). Caller
    /// should follow up with `reportConnected` once SDP negotiation lands.
    ///
    /// We deliberately do NOT call `provider.reportOutgoingCall(_:startedConnectingAt:)`
    /// from here. Apple's docs are explicit: that method can only be
    /// invoked AFTER CallKit fires `provider(_:perform:CXStartCallAction)`.
    /// Calling it before — when the UUID hasn't been registered with
    /// CallKit yet — silently fails and may make CallKit end the call.
    /// We do the `startedConnectingAt` report from the StartCallAction
    /// delegate handler below, which is the canonical place for it.
    func reportOutgoing(callID: String, peerName: String, hasVideo: Bool) {
        let uuid = UUID()
        register(uuid: uuid, callID: callID)
        print("[CallProvider] reportOutgoing callID=\(callID) uuid=\(uuid) peer=\(peerName) video=\(hasVideo)")

        let handle = CXHandle(type: .generic, value: peerName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = hasVideo
        let tx = CXTransaction(action: action)
        controller.request(tx) { error in
            if let error {
                print("[CallProvider] start-call request failed: \(error)")
            }
        }
    }

    /// SDP answer landed — flip the system UI from "calling…" to "connected".
    /// Idempotent (CallKit ignores duplicates).
    func reportConnected(callID: String) {
        guard let uuid = uuid(forCallID: callID) else {
            print("[CallProvider] reportConnected: no uuid for callID=\(callID)")
            return
        }
        print("[CallProvider] reportConnected callID=\(callID)")
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// Inbound call. Used from BOTH the foreground-WS path and the
    /// VoIP-push path — CallKit shows the same system incoming UI either
    /// way. **Synchronous** because PushKit requires `reportNewIncomingCall`
    /// before its delivery handler returns.
    @discardableResult
    func reportIncoming(callID: String, peerName: String, hasVideo: Bool) -> UUID {
        let uuid = UUID()
        register(uuid: uuid, callID: callID)
        print("[CallProvider] reportIncoming callID=\(callID) uuid=\(uuid) peer=\(peerName) video=\(hasVideo)")

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = peerName
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                print("[CallProvider] reportNewIncomingCall failed: \(error)")
            } else {
                print("[CallProvider] reportNewIncomingCall OK uuid=\(uuid)")
            }
        }
        return uuid
    }

    /// Tear down the CallKit entry for this call. Reason maps to the
    /// system UI's red banner ("Declined", "Failed", "Remote Ended",
    /// "Unanswered" → "Missed").
    func reportEnded(callID: String, reason: CXCallEndedReason) {
        guard let uuid = uuid(forCallID: callID) else {
            print("[CallProvider] reportEnded: no uuid for callID=\(callID) (already cleaned up?)")
            return
        }
        print("[CallProvider] reportEnded callID=\(callID) reason=\(reason.rawValue)")
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        unregister(callID: callID)
    }

    /// User tapped Accept inside our SwiftUI CallScreen. Route through
    /// CallKit so its state machine flips from "ringing" to "connected"
    /// in lockstep with our own — without this round-trip the system
    /// status bar at the top of the screen keeps pulsing as if the
    /// call were still ringing, even after our app finishes the WebRTC
    /// handshake.
    func requestAnswerCall(callID: String) {
        guard let uuid = uuid(forCallID: callID) else {
            print("[CallProvider] requestAnswerCall: no uuid for callID=\(callID)")
            return
        }
        let action = CXAnswerCallAction(call: uuid)
        let tx = CXTransaction(action: action)
        controller.request(tx) { error in
            if let error {
                print("[CallProvider] answer-call request failed: \(error)")
            }
        }
    }

    /// User-driven hang up (we tapped the in-app End-call button). Sends
    /// the action through CallKit so the system UI clears in lockstep.
    func requestEndCall(callID: String) {
        guard let uuid = uuid(forCallID: callID) else {
            print("[CallProvider] requestEndCall: no uuid for callID=\(callID)")
            return
        }
        let action = CXEndCallAction(call: uuid)
        let tx = CXTransaction(action: action)
        controller.request(tx) { error in
            if let error {
                print("[CallProvider] end-call request failed: \(error)")
            }
        }
    }

    /// Escape hatch for malformed VoIP pushes. iOS still requires us to
    /// `reportNewIncomingCall` after a VoIP push lands — even on garbage
    /// payloads — or the app gets terminated and VoIP delivery is
    /// suspended. Apple's documented work-around: synthesise a UUID,
    /// report then immediately end with `failed` reason. The user briefly
    /// sees an entry in CallKit which fades to "missed" and clears.
    func reportIncomingMalformed(uuid: UUID, update: CXCallUpdate) {
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
    }

}

// MARK: - CXProviderDelegate

extension CallProvider: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        // System reset (e.g. user toggled airplane mode mid-call). The
        // CallService methods below are @MainActor; hop accordingly.
        Task { @MainActor in
            CallService.shared.hangUp()
        }
    }

    /// Outbound: the system accepted our start-call request. THIS is
    /// where we tell CallKit the call is "connecting" — the canonical
    /// place per Apple's docs. Calling it earlier (right after
    /// `controller.request`) made CallKit silently fail and end the call,
    /// which manifested as "call drops a second after dialing".
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("[CallProvider] perform CXStartCallAction uuid=\(action.callUUID)")
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    /// User tapped Accept on the system incoming UI. Hand off to
    /// CallService which will run the WebRTC handshake against the
    /// stashed offer SDP. Fulfill the action immediately so CallKit
    /// transitions out of the "connecting" state — the actual SDP work
    /// is async and shouldn't block the system UI.
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("[CallProvider] perform CXAnswerCallAction uuid=\(action.callUUID)")
        action.fulfill()
        Task { @MainActor in
            CallService.shared.acceptFromCallKit(uuid: action.callUUID)
        }
    }

    /// User tapped Decline (incoming) or End (outgoing/connected).
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("[CallProvider] perform CXEndCallAction uuid=\(action.callUUID)")
        action.fulfill()
        Task { @MainActor in
            CallService.shared.endFromCallKit(uuid: action.callUUID)
        }
    }

    /// CallKit is ready for audio. WebRTC's audio device manager has been
    /// in "manual mode" since init — flip it on now so SRTP audio actually
    /// flows. Without this, the call connects but you can't hear anyone.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("[CallProvider] didActivate audio session")
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.audioSessionDidActivate(audioSession)
        rtcSession.isAudioEnabled = true
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("[CallProvider] didDeactivate audio session")
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.audioSessionDidDeactivate(audioSession)
        rtcSession.isAudioEnabled = false
    }
}
