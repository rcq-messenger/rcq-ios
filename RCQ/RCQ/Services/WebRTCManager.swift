import AVFoundation
import Foundation
@preconcurrency import WebRTC

/// Wraps libwebrtc for 1:1 calls. Owns one RTCPeerConnection at a time;
/// signalling rides the existing WS pipe.
@MainActor
final class WebRTCManager: NSObject, ObservableObject {
    static let shared = WebRTCManager()

    @Published private(set) var localVideoTrack: RTCVideoTrack?
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?

    var onLocalIceCandidate: ((String) -> Void)?
    /// ICE connectivity transitions (MainActor-hopped from the delegate).
    /// CallService owns the recovery policy (grace on a transient drop, an ICE
    /// restart before giving up).
    var onIceConnected: (() -> Void)?
    var onIceDisconnected: (() -> Void)?
    var onIceFailed: (() -> Void)?

    @Published private(set) var micMuted: Bool = false
    @Published private(set) var cameraOff: Bool = false
    @Published private(set) var speakerOn: Bool = false

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var currentCameraPosition: AVCaptureDevice.Position = .front
    /// True once an outgoing call manually activated the audio session (no
    /// CallKit in that path). iOS 26's CallKit treats a still-active voice-call
    /// session as an in-progress call and AUTO-ENDS the next *incoming* call
    /// (~1s CXEndCallAction → the peer sees a spurious "declined"). Inbound
    /// calls are released by CallKit's didDeactivate; outbound calls have no
    /// such hook, so close() must deactivate the session itself or every
    /// subsequent incoming call on this device auto-declines until app restart.
    private var manuallyActivatedSession = false

    private let stunServers: RTCIceServer = RTCIceServer(urlStrings: [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
        "stun:stun2.l.google.com:19302",
    ])

    /// TURN bundle + expiry; refreshed within 5 minutes of expiry.
    private var cachedTurn: (server: RTCIceServer, expiresAt: Date)?

    private override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        super.init()
    }

    // MARK: - call lifecycle

    /// Caller side. Outgoing calls bypass CallKit so we drive the audio
    /// session ourselves; inbound activation is left to CallKit's didActivate.
    func createOffer(media: CallMedia) async throws -> String {
        configureAudioSession(speaker: media == .video, activateNow: true)
        await refreshTurnIfNeeded()
        let pc = try makePeerConnection()
        peerConnection = pc
        try addLocalTracks(media: media, to: pc)

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": media == .video ? "true" : "false",
            ],
            optionalConstraints: nil
        )
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    /// Callee side. Don't activate the session here — CallKit's didActivate
    /// owns that, racing it drops the call.
    func handleOffer(remoteSdp: String, media: CallMedia) async throws -> String {
        configureAudioSession(speaker: media == .video, activateNow: false)
        await refreshTurnIfNeeded()
        let pc = try makePeerConnection()
        peerConnection = pc

        let remote = RTCSessionDescription(type: .offer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
        try addLocalTracks(media: media, to: pc)

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": media == .video ? "true" : "false",
            ],
            optionalConstraints: nil
        )
        let answer = try await pc.answer(for: constraints)
        try await pc.setLocalDescription(answer)
        return answer.sdp
    }

    func handleAnswer(remoteSdp: String) async throws {
        guard let pc = peerConnection else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
    }

    // MARK: - ICE restart (recover a dropped connection without losing tracks)

    /// Caller side: re-offer with fresh ICE credentials (new ufrag/pwd) so a
    /// stalled/failed connection re-gathers candidates. Tracks are untouched —
    /// this is transport recovery, not a media renegotiation.
    func restartIce() async throws -> String {
        guard let pc = peerConnection else {
            throw NSError(domain: "WebRTCManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "no active peer connection"])
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": localVideoTrack != nil ? "true" : "false",
                "IceRestart": "true",
            ],
            optionalConstraints: nil
        )
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    /// Callee side: answer the caller's ICE-restart offer (no track changes;
    /// the new remote ufrag triggers our ICE restart automatically).
    func handleIceRestartOffer(remoteSdp: String) async throws -> String {
        guard let pc = peerConnection else {
            throw NSError(domain: "WebRTCManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "no active peer connection"])
        }
        let remote = RTCSessionDescription(type: .offer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": localVideoTrack != nil ? "true" : "false",
            ],
            optionalConstraints: nil
        )
        let answer = try await pc.answer(for: constraints)
        try await pc.setLocalDescription(answer)
        return answer.sdp
    }

    func handleIceRestartAnswer(remoteSdp: String) async throws {
        guard let pc = peerConnection else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
    }

    // MARK: - mid-call renegotiation (audio → video upgrade)

    /// Caller side of the audio→video upgrade. Adds a video track to the
    /// existing peer connection without dropping audio.
    func upgradeToVideo() async throws -> String {
        guard let pc = peerConnection else {
            throw NSError(domain: "WebRTCManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "no active peer connection"])
        }
        configureAudioSession(speaker: true, activateNow: false)
        if localVideoTrack == nil {
            try addLocalVideoTrack(to: pc)
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    /// Callee side of the audio→video upgrade.
    func handleRenegotiationOffer(remoteSdp: String) async throws -> String {
        guard let pc = peerConnection else {
            throw NSError(domain: "WebRTCManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "no active peer connection"])
        }
        configureAudioSession(speaker: true, activateNow: false)
        let remote = RTCSessionDescription(type: .offer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
        if localVideoTrack == nil {
            try addLocalVideoTrack(to: pc)
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        let answer = try await pc.answer(for: constraints)
        try await pc.setLocalDescription(answer)
        return answer.sdp
    }

    func handleRenegotiationAnswer(remoteSdp: String) async throws {
        guard let pc = peerConnection else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
    }

    /// Strip local video on declined upgrade. No re-renegotiation —
    /// the next upgrade attempt reuses the transceiver cleanly.
    func rollbackVideoUpgrade() {
        videoCapturer?.stopCapture()
        videoCapturer = nil
        if let pc = peerConnection, let track = localVideoTrack {
            for sender in pc.senders where sender.track === track {
                pc.removeTrack(sender)
            }
        }
        localVideoTrack = nil
        cameraOff = false
    }

    func addRemoteIce(candidateJSON: String) {
        guard let pc = peerConnection,
              let data = candidateJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = dict["sdp"] as? String
        else { return }
        let mLineIndex = (dict["sdpMLineIndex"] as? Int32) ?? 0
        let mid = dict["sdpMid"] as? String
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: mid)
        Task {
            try? await pc.add(candidate)
        }
    }

    /// Idempotent.
    func close() {
        videoCapturer?.stopCapture()
        videoCapturer = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        micMuted = false
        cameraOff = false
        speakerOn = false
        currentCameraPosition = .front
        deactivateManualAudioSessionIfNeeded()
    }

    // MARK: - in-call controls

    func toggleMicMute() {
        let willMute = !micMuted
        let nextEnabled = !willMute

        localAudioTrack?.isEnabled = nextEnabled
        if let pc = peerConnection {
            for sender in pc.senders {
                if let track = sender.track, track.kind == "audio" {
                    track.isEnabled = nextEnabled
                }
            }
        }
        micMuted = willMute
    }

    func toggleCameraOff() {
        guard let track = localVideoTrack else { return }
        track.isEnabled = !track.isEnabled
        cameraOff = !track.isEnabled
    }

    func flipCamera() {
        guard let capturer = videoCapturer else { return }
        let next: AVCaptureDevice.Position = (currentCameraPosition == .front) ? .back : .front
        capturer.stopCapture { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.currentCameraPosition = next
                self.startCameraCapture(into: capturer)
            }
        }
    }

    func toggleSpeaker() {
        let session = AVAudioSession.sharedInstance()
        let next: AVAudioSession.PortOverride = speakerOn ? .none : .speaker
        try? session.overrideOutputAudioPort(next)
        speakerOn = !speakerOn
    }

    // MARK: - internals

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        var servers = [stunServers]
        if let turn = cachedTurn?.server {
            servers.append(turn)
        }
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw NSError(domain: "WebRTCManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not create peer connection"])
        }
        return pc
    }

    private func addLocalTracks(media: CallMedia, to pc: RTCPeerConnection) throws {
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "rcq_audio0")
        localAudioTrack = audioTrack
        pc.add(audioTrack, streamIds: ["rcq_stream0"])

        if media == .video {
            try addLocalVideoTrack(to: pc)
        }
    }

    private func addLocalVideoTrack(to pc: RTCPeerConnection) throws {
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoCapturer = capturer

        let videoTrack = factory.videoTrack(with: videoSource, trackId: "rcq_video0")
        localVideoTrack = videoTrack
        pc.add(videoTrack, streamIds: ["rcq_stream0"])

        startCameraCapture(into: capturer)
    }

    private func startCameraCapture(into capturer: RTCCameraVideoCapturer) {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let device = devices.first(where: { $0.position == currentCameraPosition })
            ?? devices.first(where: { $0.position == .front })
            ?? devices.first
        guard let device else { return }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let targetWidth: Int32 = 1280
        let format = formats.min(by: { lhs, rhs in
            let l = abs(CMVideoFormatDescriptionGetDimensions(lhs.formatDescription).width - targetWidth)
            let r = abs(CMVideoFormatDescriptionGetDimensions(rhs.formatDescription).width - targetWidth)
            return l < r
        }) ?? formats.first

        guard let chosenFormat = format else { return }
        let fps = chosenFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max()
            .map { Int(min(30.0, $0)) } ?? 30

        capturer.startCapture(with: device, format: chosenFormat, fps: fps)
    }

    private func refreshTurnIfNeeded() async {
        if let cached = cachedTurn, cached.expiresAt > Date().addingTimeInterval(300) {
            return
        }
        struct Resp: Decodable {
            let urls: [String]
            let username: String
            let credential: String
            let ttl: Int
        }
        // Retry a transient fetch failure a few times before giving up — a
        // single blip used to silently leave the call STUN-only, which dooms a
        // cross-NAT (symmetric) call to the connect timeout.
        for attempt in 0..<3 {
            do {
                let resp: Resp = try await APIClient.shared.request("GET", "/users/me/turn-credentials")
                guard !resp.urls.isEmpty, !resp.username.isEmpty else {
                    print("[WebRTCManager] TURN endpoint returned no servers — STUN-only call")
                    cachedTurn = nil
                    return
                }
                let server = RTCIceServer(
                    urlStrings: resp.urls,
                    username: resp.username,
                    credential: resp.credential
                )
                cachedTurn = (server, Date().addingTimeInterval(TimeInterval(resp.ttl)))
                return
            } catch {
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                } else {
                    // STUN-only fallback; cross-NAT calls won't connect.
                    print("[WebRTCManager] TURN fetch failed after 3 attempts — STUN-only (cross-NAT may fail): \(error)")
                    cachedTurn = nil
                }
            }
        }
    }

    /// activateNow=true for outgoing calls (no CallKit); false for inbound
    /// where CallKit's didActivate flips isAudioEnabled itself.
    private func configureAudioSession(speaker: Bool, activateNow: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
            if speaker { options.insert(.defaultToSpeaker) }
            try session.setCategory(AVAudioSession.Category.playAndRecord, with: options)
            try session.setMode(AVAudioSession.Mode.voiceChat)
            if activateNow {
                try session.setActive(true)
            }
        } catch {
            print("[WebRTCManager] audio session config failed: \(error)")
        }
        session.unlockForConfiguration()
        if activateNow {
            // No CallKit didActivate path here; explicit enable. Remember we
            // own this session so close() can release it — CallKit won't.
            session.isAudioEnabled = true
            manuallyActivatedSession = true
        }
    }

    /// Release a session WE activated (outgoing-call path). MUST run on
    /// teardown: a still-held playAndRecord/voiceChat session makes iOS 26
    /// CallKit auto-end the next incoming call before the user can answer.
    /// Inbound (CallKit) sessions are released by iOS via didDeactivate, so we
    /// only touch the ones we manually activated — never fighting CallKit.
    private func deactivateManualAudioSessionIfNeeded() {
        guard manuallyActivatedSession else { return }
        manuallyActivatedSession = false
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        session.lockForConfiguration()
        do {
            try session.setActive(false)
        } catch {
            print("[WebRTCManager] audio session deactivate failed: \(error)")
        }
        session.unlockForConfiguration()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            // Drop a late callback from a closed/superseded pc — only the
            // current connection's ICE state drives recovery.
            guard let self, peerConnection === self.peerConnection else { return }
            switch newState {
            case .connected, .completed: self.onIceConnected?()
            case .disconnected:          self.onIceDisconnected?()
            case .failed:                self.onIceFailed?()
            // .closed arrives only when we tear the pc down ourselves; the call
            // is already ending, so there is nothing to recover.
            default:                     break
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload: [String: Any] = [
            "sdp": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor [weak self] in
            self?.onLocalIceCandidate?(json)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            self?.remoteVideoTrack = track
        }
    }
}
