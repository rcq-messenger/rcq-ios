import AVFoundation
import Foundation
import WebRTC

/// Mesh WebRTC for an audio room — one RTCPeerConnection per other member
/// (≤7 at full capacity). Server convention: existing member is the offerer
/// when a newcomer enters, avoiding glare without an ordering protocol.
@MainActor
final class AudioRoomMeshManager: NSObject {
    static let shared = AudioRoomMeshManager()

    private var peers: [Int: RTCPeerConnection] = [:]
    private var localAudioTrack: RTCAudioTrack?
    private(set) var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var cameraPosition: AVCaptureDevice.Position = .front
    private(set) var remoteVideoTracks: [Int: RTCVideoTrack] = [:]
    private(set) var isCameraEnabled: Bool = false
    var onLocalVideoTrackChanged: ((RTCVideoTrack?) -> Void)?
    var onRemoteVideoTrackChanged: ((_ remoteUIN: Int, _ track: RTCVideoTrack?) -> Void)?

    private var roomID: Int?

    /// ICE for peers we haven't minted yet (offer-arrival race); drained on
    /// handleOffer / handleAnswer.
    private var pendingIce: [Int: [String]] = [:]

    private let factory: RTCPeerConnectionFactory
    private let stunServers = RTCIceServer(urlStrings: [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
    ])
    private var cachedTurn: (server: RTCIceServer, expiresAt: Date)?
    /// STUN on the island's own TURN host — see WebRTCManager.stunFrom. Google's
    /// set above is unreachable for a large part of our users, and with no
    /// reachable STUN a room peer behind NAT gathers no reflexive candidate.
    private var ownStun: RTCIceServer?

    private override init() {
        // RTCInitializeSSL is a safe no-op if WebRTCManager already ran it.
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        super.init()
    }

    // MARK: - lifecycle

    /// Called from AudioRoomService.enter before `room_enter` ships so the
    /// local audio source is ready when the roster comes back.
    func start(roomID: Int) {
        self.roomID = roomID
        configureAudioSession()
        Task { await refreshTurnIfNeeded() }
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "rcq_room_audio0")
    }

    /// Idempotent.
    func stop() {
        for (_, pc) in peers { pc.close() }
        peers.removeAll()
        pendingIce.removeAll()
        videoCapturer?.stopCapture()
        videoCapturer = nil
        localAudioTrack = nil
        localVideoTrack = nil
        remoteVideoTracks.removeAll()
        isCameraEnabled = false
        onLocalVideoTrackChanged?(nil)
        roomID = nil
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setActive(false)
        session.unlockForConfiguration()
    }

    func setMicMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    // MARK: - camera

    func setCameraEnabled(_ on: Bool) {
        guard isCameraEnabled != on else { return }
        if on {
            mintLocalVideoTrack()
        } else {
            tearDownLocalVideoTrack()
        }
        isCameraEnabled = on
        // libwebrtc holds the local track-change without a re-offer.
        renegotiateAll()
    }

    func flipCamera() {
        guard isCameraEnabled, let capturer = videoCapturer else { return }
        cameraPosition = (cameraPosition == .front) ? .back : .front
        capturer.stopCapture()
        startCameraCapture(into: capturer)
    }

    private func mintLocalVideoTrack() {
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoCapturer = capturer
        let track = factory.videoTrack(with: videoSource, trackId: "rcq_room_video0")
        localVideoTrack = track
        for pc in peers.values {
            pc.add(track, streamIds: ["rcq_room_stream0"])
        }
        startCameraCapture(into: capturer)
        onLocalVideoTrackChanged?(track)
    }

    private func tearDownLocalVideoTrack() {
        videoCapturer?.stopCapture()
        videoCapturer = nil
        if let track = localVideoTrack {
            for pc in peers.values {
                for sender in pc.senders {
                    if (sender.track as? RTCVideoTrack)?.trackId == track.trackId {
                        pc.removeTrack(sender)
                    }
                }
            }
        }
        localVideoTrack = nil
        onLocalVideoTrackChanged?(nil)
    }

    private func startCameraCapture(into capturer: RTCCameraVideoCapturer) {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let device = devices.first(where: { $0.position == cameraPosition })
            ?? devices.first(where: { $0.position == .front })
            ?? devices.first
        guard let device else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // 480p/24fps — lighter than 1:1's 720p/30; mesh ingresses up to 7 peers.
        let targetWidth: Int32 = 640
        let format = formats.min(by: { lhs, rhs in
            let l = abs(CMVideoFormatDescriptionGetDimensions(lhs.formatDescription).width - targetWidth)
            let r = abs(CMVideoFormatDescriptionGetDimensions(rhs.formatDescription).width - targetWidth)
            return l < r
        }) ?? formats.first
        guard let chosenFormat = format else { return }
        let fps = chosenFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate).max()
            .map { Int(min(24.0, $0)) } ?? 24
        capturer.startCapture(with: device, format: chosenFormat, fps: fps)
    }

    private func renegotiateAll() {
        guard let roomID else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        for (uin, pc) in peers {
            Task {
                do {
                    let offer = try await pc.offer(for: constraints)
                    try await pc.setLocalDescription(offer)
                    WebSocketService.shared.sendRoomSignal(
                        type: "room_offer",
                        roomID: roomID,
                        toUIN: uin,
                        extras: ["sdp": offer.sdp]
                    )
                } catch {
                    print("[AudioRoomMesh] renegotiate offer failed for uin=\(uin): \(error)")
                }
            }
        }
    }

    func recordRemoteVideoTrack(remoteUIN: Int, track: RTCVideoTrack) {
        remoteVideoTracks[remoteUIN] = track
        onRemoteVideoTrackChanged?(remoteUIN, track)
    }

    // MARK: - mesh signalling driven by AudioRoomService

    /// Existing-member side: a newcomer entered, dial them.
    func dialNewPeer(uin: Int) {
        guard let roomID, peers[uin] == nil else { return }
        let pc = makePeerConnection(remoteUIN: uin)
        peers[uin] = pc
        attachLocalMedia(to: pc)

        // Always offer recvonly video so the peer can turn camera on later
        // without a bundle bump.
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        Task {
            do {
                let offer = try await pc.offer(for: constraints)
                try await pc.setLocalDescription(offer)
                WebSocketService.shared.sendRoomSignal(
                    type: "room_offer",
                    roomID: roomID,
                    toUIN: uin,
                    extras: ["sdp": offer.sdp]
                )
            } catch {
                print("[AudioRoomMesh] dialNewPeer offer failed for uin=\(uin): \(error)")
            }
        }
    }

    func handleOffer(fromUIN: Int, sdp: String) {
        guard let roomID else { return }
        let pc = peers[fromUIN] ?? makePeerConnection(remoteUIN: fromUIN)
        if peers[fromUIN] == nil {
            peers[fromUIN] = pc
            attachLocalMedia(to: pc)
        }
        let remote = RTCSessionDescription(type: .offer, sdp: sdp)
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pc.setRemoteDescription(remote)
                let answer = try await pc.answer(for: constraints)
                try await pc.setLocalDescription(answer)
                WebSocketService.shared.sendRoomSignal(
                    type: "room_answer",
                    roomID: roomID,
                    toUIN: fromUIN,
                    extras: ["sdp": answer.sdp]
                )
                self.drainPendingIce(uin: fromUIN, into: pc)
            } catch {
                print("[AudioRoomMesh] handleOffer failed for uin=\(fromUIN): \(error)")
            }
        }
    }

    func handleAnswer(fromUIN: Int, sdp: String) {
        guard let pc = peers[fromUIN] else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: sdp)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pc.setRemoteDescription(remote)
                self.drainPendingIce(uin: fromUIN, into: pc)
            } catch {
                print("[AudioRoomMesh] handleAnswer failed for uin=\(fromUIN): \(error)")
            }
        }
    }

    /// Stashes ICE for unready peers; drained later by handleOffer/Answer.
    func handleIce(fromUIN: Int, candidateJSON: String) {
        if let pc = peers[fromUIN] {
            applyIce(json: candidateJSON, to: pc)
        } else {
            pendingIce[fromUIN, default: []].append(candidateJSON)
        }
    }

    func dropPeer(uin: Int) {
        peers.removeValue(forKey: uin)?.close()
        pendingIce.removeValue(forKey: uin)
        if remoteVideoTracks.removeValue(forKey: uin) != nil {
            onRemoteVideoTrackChanged?(uin, nil)
        }
    }

    // MARK: - internals

    private func makePeerConnection(remoteUIN: Int) -> RTCPeerConnection {
        let config = RTCConfiguration()
        var servers: [RTCIceServer] = []
        if let own = ownStun { servers.append(own) }
        servers.append(stunServers)
        if let turn = cachedTurn?.server { servers.append(turn) }
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        // Same reasoning as WebRTCManager: without `.relay` every participant
        // learns every other participant's real IP, and in a room that is worse
        // than in a 1:1 call because the people in it need not be each other's
        // contacts. Guarded on TURN creds for the same reason: `.relay` with no
        // TURN yields no candidates and the room silently never connects.
        if cachedTurn?.server != nil {
            config.iceTransportPolicy = .relay
        }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let delegate = MeshPeerDelegate(remoteUIN: remoteUIN, owner: self)
        // RTCPeerConnection holds delegate weakly; stash strongly here.
        peerDelegates[remoteUIN] = delegate
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            fatalError("[AudioRoomMesh] failed to create peer connection")
        }
        return pc
    }

    private func attachLocalMedia(to pc: RTCPeerConnection) {
        if let audio = localAudioTrack {
            pc.add(audio, streamIds: ["rcq_room_stream0"])
        }
        if let video = localVideoTrack {
            pc.add(video, streamIds: ["rcq_room_stream0"])
        }
    }

    private func applyIce(json: String, to pc: RTCPeerConnection) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = dict["sdp"] as? String else { return }
        let mLineIndex = (dict["sdpMLineIndex"] as? Int32) ?? 0
        let mid = dict["sdpMid"] as? String
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: mid)
        Task { try? await pc.add(candidate) }
    }

    private func drainPendingIce(uin: Int, into pc: RTCPeerConnection) {
        guard let queued = pendingIce.removeValue(forKey: uin) else { return }
        for json in queued { applyIce(json: json, to: pc) }
    }

    func shipLocalIce(remoteUIN: Int, candidate: RTCIceCandidate) {
        guard let roomID else { return }
        let payload: [String: Any] = [
            "sdp": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        WebSocketService.shared.sendRoomSignal(
            type: "room_ice",
            roomID: roomID,
            toUIN: remoteUIN,
            extras: ["candidate": json]
        )
    }

    private var peerDelegates: [Int: MeshPeerDelegate] = [:]

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
            try session.setCategory(AVAudioSession.Category.playAndRecord, with: options)
            try session.setMode(AVAudioSession.Mode.videoChat)
            try session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
        } catch {
            print("[AudioRoomMesh] audio session config failed: \(error)")
        }
        session.unlockForConfiguration()
        session.isAudioEnabled = true
    }

    /// TURN refresh on a 5-min lead, mirroring WebRTCManager. Same
    /// endpoint, same caching pattern.
    private func refreshTurnIfNeeded() async {
        if let cached = cachedTurn, cached.expiresAt > Date().addingTimeInterval(300) { return }
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
            ownStun = WebRTCManager.stunFrom(turnUrls: resp.urls)
        } catch {
            cachedTurn = nil
        }
    }
}

/// One delegate per peer connection — keeps our `didGenerate` callback
/// tagged with the remote UIN so we know which signal pipe to ship the
/// candidate over.
private final class MeshPeerDelegate: NSObject, RTCPeerConnectionDelegate {
    let remoteUIN: Int
    weak var owner: AudioRoomMeshManager?

    init(remoteUIN: Int, owner: AudioRoomMeshManager) {
        self.remoteUIN = remoteUIN
        self.owner = owner
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        // Mesh peers send video on the same stream they send audio. We
        // only care about the video track here; the audio track flows
        // straight into libwebrtc's playback pipeline without any
        // SwiftUI plumbing.
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        let uin = remoteUIN
        Task { @MainActor [weak owner] in
            owner?.recordRemoteVideoTrack(remoteUIN: uin, track: track)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let captured = candidate
        let uin = remoteUIN
        Task { @MainActor [weak self] in
            self?.owner?.shipLocalIce(remoteUIN: uin, candidate: captured)
        }
    }
}
