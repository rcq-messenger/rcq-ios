import AVFoundation
import CallKit
import Foundation
import WebRTC

/// The one place that puts WebRTC's audio session into manual mode.
///
/// This lived in `CallProvider.init`, and `RCQApp.init` touched
/// `CallProvider.shared` at launch mostly so that these two lines would run
/// before anything could start audio. Building a `CXProvider` to set two
/// booleans is not worth doing before the first frame, so the flags moved here
/// and every entry point that can start WebRTC audio calls this instead: the
/// CallKit provider, the 1:1 peer-connection factory and the audio-room
/// factory, plus both audio-session configurators.
///
/// Idempotent, callable from any thread, and cheap enough to call on every
/// call setup: after the first time it is a lock and a boolean.
enum CallAudio {
    private static let lock = NSLock()
    private static var prepared = false

    static func prepareForWebRTC() {
        lock.lock()
        defer { lock.unlock() }
        guard !prepared else { return }
        prepared = true
        // WebRTC manual audio mode; toggled by CallKit didActivate/didDeactivate
        // and by WebRTCManager on the outgoing path, which owns the session
        // itself because outgoing calls bypass CallKit.
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = true
        rtcSession.isAudioEnabled = false
    }
}

/// CallKit bridge. Single CXProvider with imperative entry points for CallService + VoIPPush.
///
/// Built on first use. The VoIP push handler reaches it synchronously
/// (`CallProvider.shared.reportIncoming…` inside `didReceiveIncomingPushWith`),
/// which is what PushKit requires, and `static let` initialisation is
/// synchronous, so a push that launches the process still reports its call
/// before the delivery handler returns.
final class CallProvider: NSObject, @unchecked Sendable {
    static let shared = CallProvider()

    private let provider: CXProvider
    private let controller = CXCallController()

    // Lock-protected: PushKit delivery thread registers mappings synchronously.
    private let mappingLock = NSLock()
    private var _callIDByUUID: [UUID: String] = [:]
    private var _uuidByCallID: [String: UUID] = [:]

    // §5d wake: a CallKit entry reported before anyone knows who is calling.
    // The recipient's island cannot know the caller (that is the whole point of
    // the sealed deposit), and PushKit demands `reportNewIncomingCall` before
    // the delivery handler returns — so the ring starts on a neutral handle and
    // the real offer, once the envelope opens, ADOPTS this uuid instead of
    // reporting a second call.
    //
    // ⚠ One entry PER WAKE, not one slot. A second wake arriving while the
    // first was still looking for its offer overwrote the slot, the first
    // wake's discard then found somebody else's uuid in it, and the first
    // ring sounded until someone answered it into nothing (#1045 review).
    private var _placeholders: [UUID: Date] = [:]

    /// What the person did to a neutral ring before its offer was found.
    enum PlaceholderDecision { case answered, ended }

    /// ⚠ Placeholders the person answered or ended while they were still
    /// neutral. CallKit fulfils the action either way, and CallService had no
    /// call to apply it to, so it was dropped: the offer found a moment later
    /// adopted the same uuid, and an answer became a call that never
    /// connected (silence here, ringback there, "missed" after a minute),
    /// an End a call that rang on unseen (#1045 review). Kept here instead,
    /// out of `_placeholders`, for the offer to honour.
    private var _decided: [UUID: (decision: PlaceholderDecision, at: Date)] = [:]
    /// Past this a placeholder is dead — a same-island offer minutes later must not
    /// adopt a uuid CallKit has already torn down, which would ring nothing.
    private static let placeholderMaxAge: TimeInterval = 20
    // A decision waits for its offer as long as its wake is looking (the
    // drain, then the bounded queue pass); the wake discards it when it gives
    // up, so it needs no clock of its own.

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        CallAudio.prepareForWebRTC()
        // Do NOT pre-configure the playAndRecord/voiceChat category at app
        // startup. iOS 26's CallKit treats a held voice-call audio session as an
        // already-active call and AUTO-ENDS a freshly reported incoming call
        // (~2s CXEndCallAction before the user can answer — the "call declined"
        // regression). The category is set per-call instead: WebRTCManager does
        // it in createOffer (outgoing) / handleOffer (inbound), and `didActivate`
        // below sets it right before CallKit activates the session. The old
        // startup config was for an outgoing CXStartCallAction path that no
        // longer exists (outgoing bypasses CallKit), so it was pure downside.
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

    // `reportOutgoingCall(_:startedConnectingAt:)` MUST be called from the
    // CXStartCallAction delegate, not here — calling earlier silently fails.
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

    func reportConnected(callID: String) {
        guard let uuid = uuid(forCallID: callID) else {
            print("[CallProvider] reportConnected: no uuid for callID=\(callID)")
            return
        }
        print("[CallProvider] reportConnected callID=\(callID)")
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    // Synchronous: PushKit requires `reportNewIncomingCall` before delivery handler returns.
    @discardableResult
    func reportIncoming(
        callID: String, peerName: String, hasVideo: Bool, preferringPlaceholder wake: UUID? = nil
    ) -> UUID {
        // Adopt a §5d placeholder if one is still waiting. Reporting a second
        // incoming call would leave TWO entries on the lock screen for one
        // call, and only one of them wired to anything. The wake that found
        // this offer names its own; otherwise the newest fresh one.
        let adopted = claimPlaceholder(preferring: wake)
        let uuid = adopted ?? UUID()
        register(uuid: uuid, callID: callID)
        print("[CallProvider] reportIncoming callID=\(callID) uuid=\(uuid) peer=\(peerName) video=\(hasVideo) adopted=\(adopted != nil)")

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = peerName
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        if adopted != nil {
            // Already ringing on the neutral handle — rename it in place and
            // switch it to video if that is what the offer turned out to be.
            provider.reportCall(with: uuid, updated: update)
            return uuid
        }
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                print("[CallProvider] reportNewIncomingCall failed: \(error)")
            } else {
                print("[CallProvider] reportNewIncomingCall OK uuid=\(uuid)")
            }
        }
        return uuid
    }

    // MARK: - §5d wake placeholder

    /// Ring on a neutral handle for a cross-island wake whose caller is still
    /// sealed. MUST be called synchronously from the PushKit delivery handler
    /// (iOS terminates the app for not reporting); the name arrives later, via
    /// `reportIncoming` adopting this uuid.
    @discardableResult
    func reportIncomingPlaceholder(hasVideo: Bool = false) -> UUID {
        let uuid = UUID()
        mappingLock.lock()
        _placeholders[uuid] = Date()
        mappingLock.unlock()

        let name = "call.incoming.unknown_caller".localized
        print("[CallProvider] reportIncomingPlaceholder uuid=\(uuid)")
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                print("[CallProvider] placeholder reportNewIncomingCall failed: \(error)")
            }
        }
        return uuid
    }

    /// End a placeholder no offer ever claimed — the envelope failed to open,
    /// the sender is not an accepted contact, or the signal was not an offer.
    /// Without this the phone rings until the user answers a call that is not
    /// there.
    func discardPlaceholderIfUnadopted(_ uuid: UUID, reason: CXCallEndedReason = .failed) {
        mappingLock.lock()
        let pending = _placeholders.removeValue(forKey: uuid) != nil
        let decided = _decided.removeValue(forKey: uuid)
        mappingLock.unlock()
        // Answered, and no offer ever came: CallKit shows a call in progress
        // with nobody on it. Ended: CallKit has already let it go.
        guard pending || decided?.decision == .answered else { return }
        print("[CallProvider] discarding unadopted placeholder uuid=\(uuid)")
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    /// Whether `uuid` is still looking for its offer: neutral, or answered or
    /// ended by the person before it was found.
    func placeholderAwaitsOffer(_ uuid: UUID) -> Bool {
        mappingLock.lock()
        defer { mappingLock.unlock() }
        return _placeholders[uuid] != nil || _decided[uuid] != nil
    }

    /// The person's answer or End on the neutral ring of the wake `uuid`,
    /// for the offer that wake has just found. Only that wake's own: the
    /// newest decision of any wake went to whatever offer came next, a
    /// same-island call on the live socket included (#1045 review).
    func takePlaceholderDecision(for uuid: UUID) -> PlaceholderDecision? {
        mappingLock.lock()
        defer { mappingLock.unlock() }
        return _decided.removeValue(forKey: uuid)?.decision
    }

    /// An answered placeholder becomes the call: its uuid now stands for
    /// `callID`, and it takes the caller's name.
    func adoptAnsweredPlaceholder(_ uuid: UUID, callID: String, peerName: String, hasVideo: Bool) {
        register(uuid: uuid, callID: callID)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = peerName
        update.hasVideo = hasVideo
        provider.reportCall(with: uuid, updated: update)
    }

    /// Moves a neutral ring the person acted on out of the pending set; an
    /// End after an answer (still before the offer) replaces the answer.
    /// Returns false when `uuid` is not a neutral ring (an ordinary call).
    fileprivate func decidePlaceholder(_ uuid: UUID, _ decision: PlaceholderDecision) -> Bool {
        mappingLock.lock()
        defer { mappingLock.unlock() }
        guard _placeholders.removeValue(forKey: uuid) != nil || _decided[uuid] != nil else { return false }
        _decided[uuid] = (decision, Date())
        return true
    }

    /// Takes the newest fresh placeholder. A stale one is never adopted (a
    /// same-island offer minutes later must not rename a ring CallKit tore
    /// down); it stays listed for its own wake to discard.
    private func claimPlaceholder(preferring wake: UUID? = nil) -> UUID? {
        mappingLock.lock()
        defer { mappingLock.unlock() }
        if let wake, _placeholders.removeValue(forKey: wake) != nil { return wake }
        let now = Date()
        guard let newest = _placeholders
            .filter({ now.timeIntervalSince($0.value) < Self.placeholderMaxAge })
            .max(by: { $0.value < $1.value })?.key
        else { return nil }
        _placeholders.removeValue(forKey: newest)
        return newest
    }

    func reportEnded(callID: String, reason: CXCallEndedReason) {
        guard let uuid = uuid(forCallID: callID) else {
            print("[CallProvider] reportEnded: no uuid for callID=\(callID) (already cleaned up?)")
            return
        }
        print("[CallProvider] reportEnded callID=\(callID) reason=\(reason.rawValue)")
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        unregister(callID: callID)
    }

    // Routing the Accept through CallKit keeps the system status bar from pulsing post-handshake.
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

    /// Apple-required escape hatch for malformed VoIP pushes: must `reportNewIncomingCall`
    /// or iOS suspends VoIP delivery; report then immediately end with `failed`.
    func reportIncomingMalformed(uuid: UUID, update: CXCallUpdate) {
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
    }

}

// MARK: - CXProviderDelegate

extension CallProvider: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            CallService.shared.hangUp()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("[CallProvider] perform CXStartCallAction uuid=\(action.callUUID)")
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("[CallProvider] perform CXAnswerCallAction uuid=\(action.callUUID)")
        action.fulfill()
        // A neutral ring: nothing to answer yet. The offer, once found,
        // answers straight away (`CallService.handleIncomingOffer`).
        if decidePlaceholder(action.callUUID, .answered) { return }
        Task { @MainActor in
            CallService.shared.acceptFromCallKit(uuid: action.callUUID)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("[CallProvider] perform CXEndCallAction uuid=\(action.callUUID)")
        action.fulfill()
        // A neutral ring: the offer, once found, is declined without ringing.
        if decidePlaceholder(action.callUUID, .ended) { return }
        Task { @MainActor in
            CallService.shared.endFromCallKit(uuid: action.callUUID)
        }
    }

    // CallKit ready for audio; flip libwebrtc out of manual mode or no audio flows.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("[CallProvider] didActivate audio session")
        let rtcSession = RTCAudioSession.sharedInstance()
        // Ensure the voice-call category is in place before activation. On answer
        // this and WebRTCManager.handleOffer's per-call config can run in either
        // order, so set it here too (now that it's no longer pinned at startup).
        rtcSession.lockForConfiguration()
        try? rtcSession.setCategory(
            AVAudioSession.Category.playAndRecord,
            with: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try? rtcSession.setMode(AVAudioSession.Mode.voiceChat)
        rtcSession.unlockForConfiguration()
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
