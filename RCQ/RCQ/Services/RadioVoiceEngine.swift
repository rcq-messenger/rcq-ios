import AVFoundation
import Foundation

/// PTT audio engine for Radio Chat: AAC-LC capture + per-speaker decode mixed at mainMixerNode.
final class RadioVoiceEngine {
    static let shared = RadioVoiceEngine()

    private let queue = DispatchQueue(label: "rcq.radio.voice", qos: .userInteractive)
    private let engine = AVAudioEngine()

    // MARK: - Capture state
    private var capturing = false
    private var encoder: AVAudioConverter?
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

    // AAC-LC, 16 kHz mono, 1024 frames/packet.
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

    static func hasMicPermission() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

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

    func ensureStarted() throws {
        try queue.sync { try self._ensureStarted() }
    }

    private func _ensureStarted() throws {
        guard !engine.isRunning else { return }
        try configureAudioSession()
        // Touching mainMixerNode forces the engine to wire its output graph.
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

    /// `onFrame` fires per AAC packet on the engine's serial queue.
    /// installTap NSExceptions: pre-existing tap and zero hwFormat sample rate are both guarded.
    func startCapture(onFrame: @escaping (UInt32, Data) -> Void) throws {
        guard Self.hasMicPermission() else {
            print("[RadioVoice] startCapture: mic permission not granted")
            throw RadioVoiceError.micPermissionDenied
        }
        try queue.sync {
            // Re-installing a tap on top of an existing one NSExceptions; remove defensively.
            self.engine.inputNode.removeTap(onBus: 0)
            self.capturing = false
            self.encoder = nil
            self.onFrame = nil
            self.pendingPCM.removeAll()

            try self._ensureStarted()

            let inputNode = self.engine.inputNode
            // Some iPhones return sampleRate=0 from outputFormat even after engine.start;
            // fall back to the session's rate to avoid AURemoteIO -10851.
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
            enc.bitRate = 24_000
            self.encoder = enc
            self.onFrame = onFrame
            self.seq = 0
            self.pendingPCM.removeAll()
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

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard self.capturing, let encoder = self.encoder else { return }
        self.pendingPCM.append(buffer)
        while true {
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

    func dropSpeaker(_ speaker: String) {
        queue.async {
            guard let sink = self.perSpeaker.removeValue(forKey: speaker) else { return }
            sink.player.stop()
            self.engine.detach(sink.player)
        }
    }

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
