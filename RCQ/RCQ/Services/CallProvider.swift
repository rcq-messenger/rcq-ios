import AVFoundation
import CallKit
import Foundation
import WebRTC

/// CallKit bridge. Single CXProvider with imperative entry points for CallService + VoIPPush.
final class CallProvider: NSObject, @unchecked Sendable {
    static let shared = CallProvider()

    private let provider: CXProvider
    private let controller = CXCallController()

    // Lock-protected: PushKit delivery thread registers mappings synchronously.
    private let mappingLock = NSLock()
    private var _callIDByUUID: [UUID: String] = [:]
    private var _uuidByCallID: [String: UUID] = [:]

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
        // WebRTC manual audio mode; toggled by didActivate/didDeactivate.
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = true
        rtcSession.isAudioEnabled = false
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
        Task { @MainActor in
            CallService.shared.acceptFromCallKit(uuid: action.callUUID)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("[CallProvider] perform CXEndCallAction uuid=\(action.callUUID)")
        action.fulfill()
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
