import AVFoundation
import Foundation
@preconcurrency import WebRTC

/// Wraps Google's libwebrtc (via the stasel/WebRTC SwiftPM xcframework).
/// Owns one `RTCPeerConnection` at a time — same single-call assumption
/// as `CallService`. The signalling layer (offer / answer / ICE) is the
/// existing WS pipe we built earlier; this class only does the WebRTC
/// halves of the dance.
///
/// Public ICE servers only for now — `stun:stun.l.google.com:19302` is
/// enough for two clients on the same LAN or with consistent NAT. TURN
/// (coturn on the prod droplet) lands in a follow-up so calls work
/// across asymmetric NATs too.
@MainActor
final class WebRTCManager: NSObject, ObservableObject {
    static let shared = WebRTCManager()

    /// Track exposed to the SwiftUI render layer for the local preview
    /// (small picture-in-picture view in CallScreen).
    @Published private(set) var localVideoTrack: RTCVideoTrack?
    /// Track for the remote video — fills the full background of CallScreen.
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?

    /// Hook the surrounding service uses to ship locally-generated ICE
    /// candidates to the peer over the existing call_ice WS event.
    var onLocalIceCandidate: ((String) -> Void)?

    /// Live in-call control state — surfaced to CallScreen via @Published.
    @Published private(set) var micMuted: Bool = false
    @Published private(set) var cameraOff: Bool = false
    @Published private(set) var speakerOn: Bool = false

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var currentCameraPosition: AVCaptureDevice.Position = .front

    /// STUN-only base set — supplemented at call-setup time with TURN
    /// credentials fetched from the backend. STUN alone works for clients
    /// on the same network or with cone NATs; TURN handles the rest.
    private let stunServers: RTCIceServer = RTCIceServer(urlStrings: [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
        "stun:stun2.l.google.com:19302",
    ])

    /// Last TURN bundle we received from `/users/me/turn-credentials` and
    /// the absolute timestamp it expires at. We refetch whenever we're
    /// within 5 minutes of expiry so a long-running app doesn't drop into
    /// STUN-only mode mid-call.
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

    /// Caller side. Build the peer connection, attach local tracks for the
    /// requested media kind, generate an offer SDP. Returns the SDP string
    /// ready to ship via `call_offer`.
    ///
    /// Outgoing calls bypass CallKit (see `CallService.start` for the why),
    /// which means **we** drive the audio session — set category, activate,
    /// and flip libwebrtc's `isAudioEnabled` ourselves. Inbound calls leave
    /// activation to CallKit's `didActivate` delegate.
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

    /// Callee side. Set up a fresh peer connection, ingest the remote
    /// offer SDP, add our own local tracks, generate an answer.
    /// Returns the answer SDP for shipping via `call_answer`.
    ///
    /// Inbound calls go through CallKit. CallKit's `didActivate` delegate
    /// is what flips `isAudioEnabled` on; we only set the category here,
    /// not the activation, otherwise we race CallKit and the call drops.
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

    /// Caller side. The callee just sent us their answer — wire it up so
    /// media streams in both directions.
    func handleAnswer(remoteSdp: String) async throws {
        guard let pc = peerConnection else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
    }

    // MARK: - mid-call renegotiation (audio → video upgrade)

    /// Caller side of the audio→video upgrade. Adds a video track + camera
    /// capturer to the existing peer connection (audio track keeps running
    /// — no media gap), then runs `createOffer` to mint a new SDP that
    /// advertises both audio and video. Returns the SDP for shipping via
    /// `call_renegotiate`. CallKit doesn't see this — same call, same
    /// transport, just an extra m-line.
    ///
    /// Audio session is bumped to speakerphone to match the video-call
    /// default (most users want speaker when video lights up). The peer
    /// can override with the route picker mid-call.
    func upgradeToVideo() async throws -> String {
        guard let pc = peerConnection else {
            throw NSError(domain: "WebRTCManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "no active peer connection"])
        }
        // Reconfigure for speakerphone — but don't reactivate (CallKit /
        // existing audio session already running).
        configureAudioSession(speaker: true, activateNow: false)
        // Idempotent — if the user races the button we don't want to add
        // a second video track / capturer.
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

    /// Callee side of the audio→video upgrade. Ingests the renegotiation
    /// offer, attaches our own video track + capturer, builds and returns
    /// the answer SDP for shipping via `call_renegotiate_answer`.
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

    /// Caller side. The callee accepted the upgrade and sent us their
    /// answer with their own video track included.
    func handleRenegotiationAnswer(remoteSdp: String) async throws {
        guard let pc = peerConnection else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: remoteSdp)
        try await pc.setRemoteDescription(remote)
    }

    /// Caller-side rollback if the callee declined the upgrade. Strip
    /// our local video track + capturer so we're back to audio-only,
    /// and clear the published preview track so the PIP disappears.
    /// We deliberately do NOT renegotiate again here — the peer
    /// connection is tolerant of a sender with a disabled track and
    /// the next renegotiation (e.g. another upgrade attempt) will
    /// reuse the transceiver cleanly.
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

    /// Both sides. ICE arrives as a JSON blob the peer's WebRTC layer
    /// generated; we deserialise and hand it to libwebrtc.
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

    /// Tear-down. Idempotent — safe to call from both `decline()` and
    /// `hangUp()` paths even when no call ever fully connected.
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
    }

    // MARK: - in-call controls

    /// Flip the local audio track on/off. Remote peer instantly stops
    /// receiving audio frames — libwebrtc keeps the SRTP session up but
    /// pushes silent samples through the encoder.
    ///
    /// We disable BOTH the cached `localAudioTrack` reference AND the
    /// audio-kind tracks on every peer-connection sender. In practice
    /// they're the same RTCAudioTrack instance, but flipping both is
    /// cheap insurance against any SDK-side quirk where the cached
    /// track and the sender's track aren't pointer-equal.
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

    /// Flip local video on/off. The capturer keeps running so reactivation
    /// is instant; only the track gating changes.
    func toggleCameraOff() {
        guard let track = localVideoTrack else { return }
        track.isEnabled = !track.isEnabled
        cameraOff = !track.isEnabled
    }

    /// Front ↔ back camera. Uses the same capturer instance — we just stop
    /// it on the current device and restart on the other.
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

    /// Speakerphone vs ear-piece. Default is `.defaultToSpeaker` for video
    /// calls and ear-piece for audio (set in `configureAudioSession`); this
    /// toggle lets the user override mid-call.
    func toggleSpeaker() {
        let session = AVAudioSession.sharedInstance()
        let next: AVAudioSession.PortOverride = speakerOn ? .none : .speaker
        try? session.overrideOutputAudioPort(next)
        speakerOn = !speakerOn
    }

    // MARK: - internals

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        // STUN always, TURN if we managed to fetch credentials. Without
        // TURN, calls behind asymmetric NATs fail to connect — but they
        // don't crash, libwebrtc just times out gathering candidates.
        var servers = [stunServers]
        if let turn = cachedTurn?.server {
            servers.append(turn)
        }
        config.iceServers = servers
        // unified-plan is the modern SDP semantic — required for newer
        // libwebrtc. The legacy plan-b is dead.
        config.sdpSemantics = .unifiedPlan
        // Bundle audio + video on a single transport for fewer ICE
        // candidates and faster setup.
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw NSError(domain: "WebRTCManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not create peer connection"])
        }
        return pc
    }

    private func addLocalTracks(media: CallMedia, to pc: RTCPeerConnection) throws {
        // --- audio ---
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "rcq_audio0")
        localAudioTrack = audioTrack
        pc.add(audioTrack, streamIds: ["rcq_stream0"])

        // --- video (only when requested) ---
        if media == .video {
            try addLocalVideoTrack(to: pc)
        }
    }

    /// Mint a local video track + capturer and attach to the peer
    /// connection. Used both at initial call setup (for video calls)
    /// and mid-call (audio→video upgrade). Idempotency is the caller's
    /// job — `localVideoTrack` should be nil before invoking.
    private func addLocalVideoTrack(to pc: RTCPeerConnection) throws {
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoCapturer = capturer

        let videoTrack = factory.videoTrack(with: videoSource, trackId: "rcq_video0")
        localVideoTrack = videoTrack
        pc.add(videoTrack, streamIds: ["rcq_stream0"])

        startCameraCapture(into: capturer)
    }

    /// Open the camera (current `currentCameraPosition`) at a sensible
    /// 720p / 30fps target. libwebrtc will downscale automatically if the
    /// negotiated remote can't keep up.
    private func startCameraCapture(into capturer: RTCCameraVideoCapturer) {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let device = devices.first(where: { $0.position == currentCameraPosition })
            ?? devices.first(where: { $0.position == .front })
            ?? devices.first
        guard let device else { return }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // Pick the closest format to 720p with a 30fps-capable range.
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

    /// Pull fresh TURN credentials from the backend if we don't have a
    /// cached set or the cached set is within 5 minutes of expiry. Silent
    /// no-op on transport failure — caller fallbacks to STUN-only.
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
        do {
            let resp: Resp = try await APIClient.shared.request("GET", "/users/me/turn-credentials")
            guard !resp.urls.isEmpty, !resp.username.isEmpty else {
                cachedTurn = nil
                return
            }
            let server = RTCIceServer(
                urlStrings: resp.urls,
                username: resp.username,
                credential: resp.credential
            )
            cachedTurn = (server, Date().addingTimeInterval(TimeInterval(resp.ttl)))
        } catch {
            // Backend unreachable / 5xx / TURN not configured — drop cache,
            // proceed with STUN-only. Calls between two same-NAT clients
            // will still work; cross-NAT calls will fail to connect.
            cachedTurn = nil
        }
    }

    /// Configure the audio session category/mode through `RTCAudioSession`
    /// (libwebrtc's wrapper that handles internal locking). `.playAndRecord`
    /// + `.voiceChat` mode gets us echo-cancellation, voice-call routing,
    /// and ducking. `.defaultToSpeaker` is on for video (most users want
    /// speakerphone when watching a stream) and off for audio (earpiece).
    ///
    /// `activateNow` controls who owns the activation half of the dance:
    /// - `true` for outgoing calls (no CallKit) — we set the category AND
    ///   activate the session AND flip `isAudioEnabled = true` ourselves.
    /// - `false` for inbound calls (CallKit-mediated) — we only set the
    ///   category. CallKit's `provider(_:didActivate:)` fires later and
    ///   our `CallProvider` delegate flips `isAudioEnabled` there.
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
            // Without CallKit's didActivate to do this for us, libwebrtc's
            // audio engine stays dormant unless we explicitly enable it.
            session.isAudioEnabled = true
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    /// Local ICE candidate gathered. Serialise to JSON and ship over WS so
    /// the peer can call `addRemoteIce`. Throughput here is bursty during
    /// the first second of a call, then quiet.
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

    /// Inbound remote track — the peer's video reaches us. Hold it in
    /// `remoteVideoTrack` so the SwiftUI layer can render it.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            self?.remoteVideoTrack = track
        }
    }
}
