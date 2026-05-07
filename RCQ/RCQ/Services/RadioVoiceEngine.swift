import AVFoundation
import Foundation

/// Push-to-talk audio engine for Radio Chat. One instance handles
/// both sides of a half-duplex(-ish) walkie-talkie:
///
///   - **Capture path**: mic input → AVAudioConverter → AAC-LC
///     packets (~24 kbps, 1024 samples / 64 ms each at 16 kHz mono).
///     Each packet is delivered to `onFrame`, which the caller
///     (`RadioService`) seals + ships over `MCSession` `.unreliable`.
///
///   - **Playback path**: incoming AAC packets fed via
///     `feedFrame(speaker:data:)`. One `AVAudioPlayerNode` per
///     remote speaker, all routed into `engine.mainMixerNode` —
///     when two peers talk at once, both are audible because the
///     mixer just sums them. Player nodes are torn down on
///     `dropSpeaker` (peer disconnect / talk-stop) or after the
///     speaker idle-timeout.
///
/// Audio session is `.playAndRecord` + `.voiceChat` mode +
/// `.allowBluetooth` + `.defaultToSpeaker` — same shape as
/// `AudioRoomMeshManager`, gives us hardware AEC so your own
/// outgoing voice doesn't loop back through your earpiece into
/// the next peer's stream.
///
/// Thread model: a private serial queue owns all engine state.
/// The capture tap callback also runs on this queue (we hop over
/// from the audio thread via `queue.async`). Public methods are
/// safe to call from any thread; they marshal in.
final class RadioVoiceEngine {
    static let shared = RadioVoiceEngine()

    private let queue = DispatchQueue(label: "rcq.radio.voice", qos: .userInteractive)
    private let engine = AVAudioEngine()

    // MARK: - Capture state
    private var capturing = false
    private var encoder: AVAudioConverter?
    /// PCM buffers fed into the encoder by `installTap`. Drained
    /// by the converter's input callback on every tap invocation.
    private var pendingPCM: [AVAudioPCMBuffer] = []
    private var seq: UInt32 = 0
    private var onFrame: ((UInt32, Data) -> Void)?

    // MARK: - Playback state
    private var perSpeaker: [String: SpeakerSink] = [:]

    private struct SpeakerSink {
        let player: AVAudioPlayerNode
        let decoder: AVAudioConverter
        var lastFrameAt: Date
    }

    // MARK: - Formats

    /// AAC-LC, 16 kHz mono, variable-bitrate, 1024 frames/packet.
    /// Same format used as both encoder output (capture) and
    /// decoder input (playback).
    private static let aacFormat: AVAudioFormat = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &asbd)!
    }()

    /// Internal PCM format the engine mixes in. Matches the AAC
    /// sample rate so the decoder doesn't need to do rate conversion
    /// on every packet — the engine handles 16 kHz → hardware-rate
    /// at the output node.
    private static let internalPCM: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    enum RadioVoiceError: Error {
        case encoderUnavailable
        case audioSessionFailed(String)
        case invalidInputFormat
        case micPermissionDenied
    }

    /// Mic permission gate. NSException-prone APIs (`installTap`,
    /// `engine.start`) tolerate denied permission, but checking
    /// up front lets us surface a clean error instead of silently
    /// recording garbage.
    static func hasMicPermission() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    /// Async permission request. Use from `RadioService.startTalking`
    /// before invoking `startCapture` so `.undetermined` triggers
    /// the system prompt rather than a confusing engine failure.
    static func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: completion(true)
            case .denied: completion(false)
            case .undetermined:
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            @unknown default: completion(false)
            }
        } else {
            let s = AVAudioSession.sharedInstance()
            switch s.recordPermission {
            case .granted: completion(true)
            case .denied: completion(false)
            case .undetermined:
                s.requestRecordPermission(completion)
            @unknown default: completion(false)
            }
        }
    }

    private init() {}

    // MARK: - Lifecycle

    /// Starts the audio session + engine if they're not already up.
    /// Idempotent. Called lazily from both `startCapture` and
    /// `feedFrame` so the engine spins up on the first interaction
    /// regardless of which side fires first.
    func ensureStarted() throws {
        try queue.sync { try self._ensureStarted() }
    }

    private func _ensureStarted() throws {
        guard !engine.isRunning else { return }
        try configureAudioSession()
        // Touching mainMixerNode forces engine to wire output graph.
        _ = engine.mainMixerNode
        engine.prepare()
        try engine.start()
    }

    func stop() {
        queue.sync {
            self._stopCapture()
            for (_, sink) in self.perSpeaker {
                sink.player.stop()
                self.engine.detach(sink.player)
            }
            self.perSpeaker.removeAll()
            if self.engine.isRunning {
                self.engine.stop()
            }
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func configureAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try s.setActive(true)
            print("[RadioVoice] audioSession active — category=\(s.category.rawValue) mode=\(s.mode.rawValue) sampleRate=\(s.sampleRate) inputAvailable=\(s.isInputAvailable)")
        } catch {
            print("[RadioVoice] audioSession setCategory/setActive failed: \(error)")
            throw RadioVoiceError.audioSessionFailed(error.localizedDescription)
        }
    }

    // MARK: - Capture (outbound)

    /// Begin tapping the mic. `onFrame` is invoked per AAC packet
    /// off the engine's serial queue — caller is responsible for
    /// hopping to whatever thread it needs (typically the main
    /// actor for sending over MCSession).
    ///
    /// The two main NSException-prone failure modes for `installTap`
    /// are guarded explicitly here:
    ///   - **Pre-existing tap** ("required condition is false:
    ///     nullptr == Tap()") — defensively `removeTap` first.
    ///   - **Invalid hardware format** (zero sample rate, e.g.
    ///     audio session never activated for record) — validate
    ///     `hwFormat.sampleRate > 0` before installing.
    /// Either of these would terminate the app since NSExceptions
    /// can't be caught in pure Swift.
    func startCapture(onFrame: @escaping (UInt32, Data) -> Void) throws {
        guard Self.hasMicPermission() else {
            print("[RadioVoice] startCapture: mic permission not granted")
            throw RadioVoiceError.micPermissionDenied
        }
        try queue.sync {
            // Tear down any lingering tap before we start. The tap
            // can outlive the `capturing` flag if a previous start
            // crashed mid-setup or if stopCapture didn't reach the
            // removeTap call — re-installing on top would NSException.
            self.engine.inputNode.removeTap(onBus: 0)
            self.capturing = false
            self.encoder = nil
            self.onFrame = nil
            self.pendingPCM.removeAll()

            try self._ensureStarted()

            let inputNode = self.engine.inputNode
            // Fetch the input format. On a non-trivial set of iPhones
            // `inputNode.outputFormat(forBus: 0)` lies — it returns
            // `sampleRate=0` even after `engine.start()` succeeded
            // and the audio session reports a valid rate. Falling
            // back to the audio session's sample rate + a standard
            // mono PCM format gets the engine to do its own internal
            // rate conversion downstream from the tap, and avoids
            // the AURemoteIO `-10851 (FormatNotSupported)` crash.
            var tapFormat = inputNode.outputFormat(forBus: 0)
            print("[RadioVoice] hwFormat: sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount) commonFormat=\(tapFormat.commonFormat.rawValue)")
            if tapFormat.sampleRate <= 0 || tapFormat.channelCount == 0 {
                let sessionRate = AVAudioSession.sharedInstance().sampleRate
                guard sessionRate > 0,
                      let fallback = AVAudioFormat(
                          standardFormatWithSampleRate: sessionRate,
                          channels: 1
                      )
                else {
                    if self.engine.isRunning { self.engine.stop() }
                    try? AVAudioSession.sharedInstance().setActive(
                        false, options: .notifyOthersOnDeactivation
                    )
                    throw RadioVoiceError.invalidInputFormat
                }
                tapFormat = fallback
                print("[RadioVoice] using fallback tapFormat from session: sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")
            }
            guard let enc = AVAudioConverter(from: tapFormat, to: Self.aacFormat) else {
                print("[RadioVoice] AVAudioConverter init returned nil — tapFormat=\(tapFormat) aacFormat=\(Self.aacFormat)")
                if self.engine.isRunning { self.engine.stop() }
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation
                )
                throw RadioVoiceError.encoderUnavailable
            }
            // 24 kbps target — intelligible voice, well within MC
            // throughput even on a crowded BT mesh.
            enc.bitRate = 24_000
            self.encoder = enc
            self.onFrame = onFrame
            self.seq = 0
            self.pendingPCM.removeAll()
            // 4096-frame tap @ 48 kHz hardware ≈ 85 ms — comfortable
            // bite for the encoder, which needs 1024 output frames
            // per AAC packet (≈ 3072 input frames at 48 kHz).
            inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: tapFormat
            ) { [weak self] buffer, _ in
                self?.queue.async {
                    self?.handleTap(buffer)
                }
            }
            self.capturing = true
        }
    }

    func stopCapture() {
        queue.sync { self._stopCapture() }
    }

    private func _stopCapture() {
        guard self.capturing else { return }
        self.engine.inputNode.removeTap(onBus: 0)
        self.capturing = false
        self.onFrame = nil
        self.encoder = nil
        self.pendingPCM.removeAll()
    }

    /// Drains pending PCM into AAC packets. The converter callback
    /// pulls one buffer at a time; we keep looping until it tells
    /// us it wants more input than we have queued.
    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard self.capturing, let encoder = self.encoder else { return }
        self.pendingPCM.append(buffer)
        while true {
            // 768 bytes is a safe ceiling for a single AAC-LC packet
            // at 24 kbps / 16 kHz mono (typical: 150-200 bytes).
            let outBuf = AVAudioCompressedBuffer(
                format: Self.aacFormat,
                packetCapacity: 1,
                maximumPacketSize: 768
            )
            var error: NSError?
            let status = encoder.convert(to: outBuf, error: &error) { _, outStatus in
                if let next = self.pendingPCM.first {
                    self.pendingPCM.removeFirst()
                    outStatus.pointee = .haveData
                    return next
                }
                outStatus.pointee = .noDataNow
                return nil
            }
            guard status == .haveData,
                  outBuf.packetCount > 0,
                  let pktDesc = outBuf.packetDescriptions
            else { break }
            let pd = pktDesc.pointee
            let off = Int(pd.mStartOffset)
            let len = Int(pd.mDataByteSize)
            let data = Data(bytes: outBuf.data.advanced(by: off), count: len)
            self.seq &+= 1
            self.onFrame?(self.seq, data)
        }
    }

    // MARK: - Playback (inbound)

    /// Decode + schedule one incoming AAC packet from a peer. Lazy-
    /// allocates a player node + decoder on first frame from this
    /// `speaker`; subsequent frames feed the same sink. Multiple
    /// speakers automatically mix at `mainMixerNode`.
    func feedFrame(speaker: String, data: Data) {
        queue.async {
            do { try self._ensureStarted() } catch { return }

            let sink: SpeakerSink
            if let existing = self.perSpeaker[speaker] {
                sink = existing
            } else {
                let player = AVAudioPlayerNode()
                self.engine.attach(player)
                self.engine.connect(
                    player,
                    to: self.engine.mainMixerNode,
                    format: Self.internalPCM
                )
                guard let dec = AVAudioConverter(
                    from: Self.aacFormat,
                    to: Self.internalPCM
                ) else {
                    self.engine.detach(player)
                    return
                }
                sink = SpeakerSink(player: player, decoder: dec, lastFrameAt: Date())
                self.perSpeaker[speaker] = sink
                player.play()
            }

            // Wrap incoming bytes as a one-packet AVAudioCompressedBuffer.
            let aac = AVAudioCompressedBuffer(
                format: Self.aacFormat,
                packetCapacity: 1,
                maximumPacketSize: max(data.count, 1)
            )
            data.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    _ = memcpy(aac.data, base, data.count)
                }
            }
            aac.byteLength = UInt32(data.count)
            aac.packetCount = 1
            if let pd = aac.packetDescriptions {
                pd.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(data.count)
                )
            }

            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: Self.internalPCM,
                frameCapacity: 1024
            ) else { return }
            var error: NSError?
            var consumed = false
            let status = sink.decoder.convert(to: pcm, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return aac
            }
            guard status == .haveData else { return }
            sink.player.scheduleBuffer(pcm, completionHandler: nil)

            var updated = sink
            updated.lastFrameAt = Date()
            self.perSpeaker[speaker] = updated
        }
    }

    /// Tear down a speaker's player node. Called on explicit
    /// `voiceTalkStop` from the peer, on peer disconnect, or when
    /// the active session ends.
    func dropSpeaker(_ speaker: String) {
        queue.async {
            guard let sink = self.perSpeaker.removeValue(forKey: speaker) else { return }
            sink.player.stop()
            self.engine.detach(sink.player)
        }
    }

    /// Drop all per-speaker state. Used on session leave so a
    /// stale player node doesn't carry over into the next radio
    /// session.
    func dropAllSpeakers() {
        queue.async {
            for (_, sink) in self.perSpeaker {
                sink.player.stop()
                self.engine.detach(sink.player)
            }
            self.perSpeaker.removeAll()
        }
    }
}
