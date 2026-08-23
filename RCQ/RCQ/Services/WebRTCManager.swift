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

    /// Built on first use, never at launch.
    ///
    /// `RTCInitializeSSL` plus an `RTCPeerConnectionFactory` with the default
    /// video codec factories is the most expensive thing the app used to do
    /// before its first frame: `RootView` holds `CallService` as a
    /// `@StateObject`, `CallService.init` registers its ICE callbacks here, and
    /// that alone built BoringSSL's tables and enumerated the VideoToolbox
    /// encoders and decoders while the splash was still being laid out. Nobody
    /// needs any of it until a call exists, and every path below is either a
    /// user tapping "call" or an inbound offer, both of which await the network
    /// on the very next line.
    ///
    /// `lazy` is sound here because the class is `@MainActor`: there is no
    /// second thread that could race the initialiser.
    private lazy var factory: RTCPeerConnectionFactory = {
        CallAudio.prepareForWebRTC()
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let built = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        // ⚠ WebRTC ignores the loopback adapter when it enumerates networks,
        // which means it cannot reach a TURN server on 127.0.0.1 — and that is
        // exactly where [CallTunnel] puts one so that call media can ride the
        // obfuscated connection. Left alone, the tunnel is built, listens, and
        // is never dialled.
        //
        // The native default for network_ignore_mask is the loopback bit; the
        // options object below starts from nothing and sets only what is asked
        // for, so handing it over is what clears it. Every other ignore flag
        // stays false, which is what it already was.
        //
        // Clearing it only makes loopback usable, it does not put loopback
        // candidates anywhere they matter: the tunnelled path is relay-only, so
        // the sole candidate gathered is the relay address the island allocated.
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        built.setOptions(options)
        return built
    }()
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

    /// STUN on the island's OWN TURN host, derived from the credentials it
    /// hands out. Google's set above is unreachable for a large part of our
    /// users, and with no reachable STUN there are no server-reflexive
    /// candidates at all, so a call between two NATs has nothing to try until
    /// TURN allocates. Reported as "звонки не соединяются ни с обходом, ни без,
    /// при любых настройках". Ours goes first, Google stays as the fallback for
    /// everyone whose network is fine.
    private var ownStun: RTCIceServer?

    /// TURN bundle + expiry; refreshed within 5 minutes of expiry.
    private var cachedTurn: (server: RTCIceServer, expiresAt: Date)?

    /// Whether a throwaway allocation produced a relay candidate on this
    /// network. nil until measured. Static so the answer survives per-call
    /// managers — it is a property of the network, not of one call.
    static var relayReachable: Bool?

    /// Measure it. Cheap (no media, one data channel), bounded, and the result
    /// is what decides relay-only below.
    static func probeRelay(turn: RTCIceServer, factory: RTCPeerConnectionFactory) {
        let config = RTCConfiguration()
        config.iceServers = [turn]
        config.iceTransportPolicy = .relay
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let probe = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            relayReachable = false
            return
        }
        let collector = RelayProbeDelegate { ok in
            relayReachable = ok
            probe.close()
        }
        probeDelegate = collector
        probe.delegate = collector
        probe.dataChannel(forLabel: "relay-probe", configuration: RTCDataChannelConfiguration())
        probe.offer(for: constraints) { sdp, _ in
            guard let sdp else { collector.finish(false); return }
            probe.setLocalDescription(sdp) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { collector.finish(false) }
    }

    private static var probeDelegate: RelayProbeDelegate?

    /// The bare host out of `turn:host:port?transport=...`, which is what
    /// [CallTunnel] forwards to. Nil when the island handed out nothing
    /// parseable, in which case there is nothing to tunnel to and the tunnel
    /// stays down.
    static func hostFrom(turnUrls: [String]) -> String? {
        for url in turnUrls {
            guard let range = url.range(of: "^turns?:", options: .regularExpression) else { continue }
            let rest = String(url[range.upperBound...])
            let hostPort = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
            let host = hostPort.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPort
            if !host.isEmpty { return host }
        }
        return nil
    }

    /// `turn:host:port?transport=...` -> `stun:host:port`. Nil when the island
    /// handed out nothing parseable, in which case we simply keep Google's.
    static func stunFrom(turnUrls: [String]) -> RTCIceServer? {
        for url in turnUrls {
            guard let range = url.range(of: "^turns?:", options: .regularExpression) else { continue }
            let rest = String(url[range.upperBound...])
            let hostPort = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
            let parts = hostPort.split(separator: ":", maxSplits: 1).map(String.init)
            guard let host = parts.first, !host.isEmpty else { continue }
            let port = parts.count > 1 ? parts[1] : "3478"
            return RTCIceServer(urlStrings: ["stun:\(host):\(port)"])
        }
        return nil
    }

    private override init() {
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

    /// Can this connection accept a remote candidate yet?
    ///
    /// ★★ The question is about the CONNECTION, not about the screen. WebRTC
    /// discards candidates until a remote description exists, so anything that
    /// arrives before it is gone. The caller's remote description only lands
    /// when the answer does, and the callee's host candidates need no round trip
    /// at all, so they routinely win that race. Android port: `WebRtcClient
    /// .canTakeRemoteIce()`.
    func canTakeRemoteIce() -> Bool {
        peerConnection?.remoteDescription != nil
    }

    func addRemoteIce(candidateJSON: String) {
        guard let pc = peerConnection,
              let data = candidateJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = dict["sdp"] as? String
        else {
            // ⚠ Say so. This used to return in silence, which is a large part of
            // why candidates going missing stayed invisible for so long.
            print("[WebRTCManager] remote ICE dropped: no peer connection or unparseable candidate")
            return
        }
        let mLineIndex = (dict["sdpMLineIndex"] as? Int32) ?? 0
        let mid = dict["sdpMid"] as? String
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: mid)
        Task {
            do {
                try await pc.add(candidate)
            } catch {
                print("[WebRTCManager] remote ICE rejected: \(error)")
            }
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
        var servers: [RTCIceServer] = []
        if let own = ownStun { servers.append(own) }
        servers.append(stunServers)
        if let turn = cachedTurn?.server {
            servers.append(turn)
        }
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        // ⚠ Calls used to run with the default ICE policy, which puts host and
        // srflx candidates in the SDP — i.e. it hands the peer your LAN
        // addresses and your real public IP before anyone says hello, and it
        // does so even when the messenger itself is riding a relay, because
        // WebRTC opens its own UDP sockets outside the transport. For an app
        // that sells not knowing where you are, that was the biggest hole we
        // had, and no privacy setting could close it.
        //
        // `.relay` forces everything through our TURN server: the peer sees the
        // TURN address only. Media now transits our box, which costs bandwidth
        // and a little latency, and that is the trade we are making.
        //
        // Only when TURN creds actually arrived: under `.relay` with no TURN
        // there are no candidates at all and the call silently never connects.
        // ⚠⚠ Only when a relay candidate is actually obtainable on this network.
        // Android shipped this keyed on "credentials exist" and three people
        // reported calls ringing and then dying on the connect timeout, on
        // networks that cannot reach TURN: under `.relay` with no reachable
        // server there are no candidates at all. `relayReachable` is measured
        // once per credential fetch on a throwaway connection; until it has an
        // answer we do NOT force relay, because a call that cannot connect is a
        // worse failure than one that leaks an address.
        // ⚠⚠ ...and only while the user still wants it. This used to be
        // unconditional, which is the right default and was the wrong rule.
        if cachedTurn?.server != nil, Self.relayReachable == true, CallPrivacy.alwaysRelay {
            config.iceTransportPolicy = .relay
        }

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

    /// Fetch the credentials, learn the relay host, raise the call tunnel and
    /// measure whether a relay candidate is obtainable here — all off the call
    /// path, so the first call does not pay for any of it and the diagnostics
    /// have something to report before anybody has called. Android parity:
    /// `CallController.prewarmRelayPath`.
    func prewarmRelayPath() async {
        await refreshTurnIfNeeded()
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
                // With the obfuscated connection up, reach the relay THROUGH it.
                // The credentials are unchanged: TURN authenticates the
                // username, not the address the connection arrived from, so the
                // island still recognises this as the same user arriving by a
                // different road.
                let turnHost = Self.hostFrom(turnUrls: resp.urls)
                CallDiagnostics.turnHost = turnHost
                await CallTunnel.shared.ensureRunning(turnHost: turnHost)
                // ⚠ ADDED to the island's URLs, never substituted for them. ICE
                // tries every server it is given and uses whichever answers, so
                // offering both roads can only help: on a censored network the
                // direct one is dead and the tunnel carries the call, on an open
                // network the direct one wins on latency and the tunnel costs
                // nothing. Replacing them would mean that any fault in the
                // tunnel took calls away from people whose direct path was fine.
                let effective = [CallTunnel.shared.activeURL()].compactMap { $0 } + resp.urls
                let server = RTCIceServer(
                    urlStrings: effective,
                    username: resp.username,
                    credential: resp.credential
                )
                cachedTurn = (server, Date().addingTimeInterval(TimeInterval(resp.ttl)))
                // Measure reachability alongside the refresh, so the first call
                // after launch already knows whether relay-only is viable here.
                Self.probeRelay(turn: server, factory: factory)
                // ⚠ STUN is derived from the ISLAND's url, never the tunnel's:
                // the forwarder speaks TCP, STUN is UDP, and
                // `stun:127.0.0.1:<tcp port>` is an address nothing answers on.
                ownStun = Self.stunFrom(turnUrls: resp.urls)
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
        // Manual audio used to be armed at launch by `CallProvider.init`; it is
        // armed here instead, before anything touches the session. `isAudioEnabled`
        // below only means anything with it on.
        CallAudio.prepareForWebRTC()
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

/// Collects the one fact the relay probe needs: did a relay candidate appear
/// before the deadline. Everything else in `RTCPeerConnectionDelegate` is
/// required by the protocol and deliberately does nothing.
///
/// `@unchecked Sendable` over a lock rather than an actor: `finish` is called
/// from three threads that are not ours to pick — WebRTC's signalling thread
/// (the delegate callbacks), the offer completion, and the main-queue deadline
/// — and the entire contract is "first caller wins, exactly once". A lock around
/// the two fields says that; an actor would make every one of those call sites
/// async and buy nothing.
final class RelayProbeDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let done: (Bool) -> Void
    private var settled = false

    init(_ done: @escaping (Bool) -> Void) { self.done = done }

    func finish(_ ok: Bool) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        lock.unlock()
        // Outside the lock on purpose: the callback closes the peer connection
        // and can re-enter through a delegate callback.
        done(ok)
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        if candidate.sdp.contains(" typ relay") { finish(true) }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceGatheringState) {
        // Gathering finished and nothing relayed: there is none to be had here.
        if state == .complete { finish(false) }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
