import AVFoundation
import Foundation
import WebRTC

/// Mesh WebRTC for an audio room. One `RTCPeerConnection` per OTHER
/// member (n − 1 connections, ≤7 at full capacity). All connections
/// share the same single audio source — we mint one local audio track
/// at start and add it to every fresh peer connection.
///
/// Tie-breaking the offer/answer race: by server convention the
/// EXISTING member is the offerer when a newcomer enters. The newcomer
/// just listens for offers from each existing member and answers each.
/// This avoids glare without an explicit ordering protocol.
///
/// Audio session is configured at start with `.playAndRecord` /
/// `.voiceChat`, same as 1:1 calls. The `audio` UIBackgroundMode in
/// the app's Info.plist is what keeps audio alive when the app is
/// backgrounded — CallKit isn't involved here (audio rooms are not
/// "calls" from iOS's perspective; the in-app pill provides return-to-room).
@MainActor
final class AudioRoomMeshManager: NSObject {
    static let shared = AudioRoomMeshManager()

    /// Peer connections keyed by remote UIN. Created in `dialNewPeer`
    /// (we are the offerer) or `handleOffer` (we are the answerer).
    /// Removed in `dropPeer` and `stop`.
    private var peers: [Int: RTCPeerConnection] = [:]
    /// One shared local audio track across every connection — the
    /// peer connection just references it via `add(track, streamIds:)`.
    /// Mute is implemented by toggling `isEnabled` on the track itself
    /// (libwebrtc gates the encoder on this flag).
    private var localAudioTrack: RTCAudioTrack?
    /// Optional local camera track. Nil until `setCameraEnabled(true)`;
    /// torn down on `setCameraEnabled(false)`. Attached to every peer
    /// connection alongside the audio track when present.
    private(set) var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    /// Front by default — selfie-style is the typical "speaking on
    /// camera in a voice room" expectation. `flipCamera()` toggles.
    private var cameraPosition: AVCaptureDevice.Position = .front
    /// Remote video tracks keyed by sender UIN. Mesh peers append here
    /// the moment libwebrtc surfaces their video receiver; cleared per-peer
    /// on `dropPeer` and globally on `stop`.
    private(set) var remoteVideoTracks: [Int: RTCVideoTrack] = [:]
    /// True after `setCameraEnabled(true)` until matching false. Surfaced
    /// via the service so the toolbar button can reflect state.
    private(set) var isCameraEnabled: Bool = false
    /// Service-layer hooks. Mesh fires these when local/remote video
    /// state changes so AudioRoomService can mirror into @Published
    /// properties for SwiftUI to observe.
    var onLocalVideoTrackChanged: ((RTCVideoTrack?) -> Void)?
    var onRemoteVideoTrackChanged: ((_ remoteUIN: Int, _ track: RTCVideoTrack?) -> Void)?

    /// The room we're currently servicing — used to tag every WS
    /// signal we ship out so the server can verify both endpoints.
    private var roomID: Int?

    /// ICE candidates that arrived for a peer connection we hadn't
    /// minted yet (race: their offer hasn't reached us, or our offer
    /// hadn't been answered). Drained when the peer connection
    /// materialises in `handleOffer` / `handleAnswer`.
    private var pendingIce: [Int: [String]] = [:]

    private let factory: RTCPeerConnectionFactory
    private let stunServers = RTCIceServer(urlStrings: [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
    ])
    private var cachedTurn: (server: RTCIceServer, expiresAt: Date)?

    private override init() {
        // SSL is initialised at first use of any WebRTC component.
        // Calling `RTCInitializeSSL` again is a safe no-op if WebRTCManager
        // already did it for a 1:1 call earlier in the session.
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

    /// Open the audio session, mint the local audio track. Called
    /// from `AudioRoomService.enter` BEFORE we ship `room_enter` to
    /// the server — by the time the roster comes back we already
    /// have a local source ready to feed every fresh peer connection.
    func start(roomID: Int) {
        self.roomID = roomID
        configureAudioSession()
        Task { await refreshTurnIfNeeded() }
        // Audio source + track. One per session, reused across every
        // peer connection we open in the mesh.
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "rcq_room_audio0")
    }

    /// Tear down everything — peers, audio track, audio session
    /// deactivation. Idempotent so the service can call it from any
    /// exit path (user leaves, owner deletes, account burned).
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
        // Best-effort deactivation. If a regular 1:1 call starts up
        // right after, WebRTCManager will reconfigure from scratch.
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setActive(false)
        session.unlockForConfiguration()
    }

    /// Mute / unmute the shared local audio track. Flipping
    /// `isEnabled = false` makes libwebrtc push silent samples to
    /// every peer in the mesh — same trick as 1:1 calls.
    func setMicMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
    }

    // MARK: - camera

    /// Toggle the local camera. On: mint capturer + video track, attach
    /// to every existing peer, re-offer SDP so the m-section reaches
    /// the wire. Off: stop capturer, remove the sender from each peer,
    /// re-offer to drop the m-section. Idempotent.
    func setCameraEnabled(_ on: Bool) {
        guard isCameraEnabled != on else { return }
        if on {
            mintLocalVideoTrack()
        } else {
            tearDownLocalVideoTrack()
        }
        isCameraEnabled = on
        // Re-issue offers so peers see the new (or removed) video
        // m-section. Without this libwebrtc holds the local change
        // and never propagates it to remotes.
        renegotiateAll()
    }

    /// Flip front ↔ back camera. No-op when camera is off.
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
        // Attach to every existing peer connection so the new offer
        // generated by `renegotiateAll()` carries a video m-section.
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
        // 480p / 24fps target — meaningfully lighter than the 720p/30
        // preset 1:1 calls use, because a mesh can have up to 7 video
        // peers ingressing simultaneously. Halving width × height
        // brings the worst-case bandwidth from ~5 Mbps down to ~1.5
        // Mbps which fits comfortably on a typical mobile data plan.
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

    /// Re-issue offers to every existing peer after a track add/remove.
    /// Without this the new track never reaches the wire — libwebrtc
    /// holds it locally but the remote SDP doesn't include the new
    /// m-section.
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

    /// Called from `MeshPeerDelegate.didAdd rtpReceiver` for video
    /// tracks. Keeps the per-UIN mapping in sync with what libwebrtc
    /// is actually surfacing on the wire.
    func recordRemoteVideoTrack(remoteUIN: Int, track: RTCVideoTrack) {
        remoteVideoTracks[remoteUIN] = track
        onRemoteVideoTrackChanged?(remoteUIN, track)
    }

    // MARK: - mesh signalling driven by AudioRoomService

    /// We are an EXISTING member; a NEWCOMER just entered. Mint a
    /// peer connection to them, attach our audio, generate an offer,
    /// and ship it. Per server convention this side is the offerer.
    func dialNewPeer(uin: Int) {
        guard let roomID, peers[uin] == nil else { return }
        let pc = makePeerConnection(remoteUIN: uin)
        peers[uin] = pc
        attachLocalMedia(to: pc)

        // Always advertise willingness to receive video — the peer
        // may turn their camera on at any time; without this flag the
        // recvonly m-section never gets allocated and their later
        // re-offer would have to bump the bundle, which is fragile.
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

    /// We received an offer from `from` — they are the offerer
    /// (existing member; we just entered, OR they minted a new
    /// connection for some reason). Build our peer connection if we
    /// don't already have one, ingest the remote SDP, answer.
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

    /// We are the offerer; remote just answered our offer. Ingest the
    /// answer to flip the connection into stable state.
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

    /// ICE candidate from a specific peer. If the connection isn't
    /// ready yet (offer/answer race), stash it and drain later.
    func handleIce(fromUIN: Int, candidateJSON: String) {
        if let pc = peers[fromUIN] {
            applyIce(json: candidateJSON, to: pc)
        } else {
            pendingIce[fromUIN, default: []].append(candidateJSON)
        }
    }

    /// Peer left the room — close their connection and forget them.
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
        var servers = [stunServers]
        if let turn = cachedTurn?.server { servers.append(turn) }
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let delegate = MeshPeerDelegate(remoteUIN: remoteUIN, owner: self)
        // Hold the delegate for the lifetime of the connection.
        // RTCPeerConnection holds its delegate weakly, so without
        // this stash it'd be deallocated on the next loop tick.
        peerDelegates[remoteUIN] = delegate
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            // Realistically unreachable — the factory failing to mint
            // a peer connection means OOM or libwebrtc-internal state
            // corruption. Caller already checked we have a roomID.
            fatalError("[AudioRoomMesh] failed to create peer connection")
        }
        return pc
    }

    /// Attach whatever local media we currently have to a fresh peer
    /// connection. Always attaches audio; attaches video too if camera
    /// is on at the moment the peer is dialled (so newcomers see our
    /// stream from the first offer/answer cycle).
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

    /// Fire a locally-generated ICE candidate to the right peer over
    /// WS. Called from the per-peer delegate.
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

    /// Reuses the WebRTCManager pattern. `.allowBluetoothHFP` covers BT
    /// HFP routing; the user can still bring up the system route picker
    /// from the room screen for AirPods/CarPlay/etc.
    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            // Audio rooms default to speakerphone — multi-party voice
            // through the earpiece is rough.
            let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
            try session.setCategory(AVAudioSession.Category.playAndRecord, with: options)
            try session.setMode(AVAudioSession.Mode.voiceChat)
            try session.setActive(true)
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
