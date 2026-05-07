import AVFoundation
import Foundation

/// Captures a hold-to-record voice message into a temp .m4a file using
/// `AVAudioRecorder`. AAC at 32 kbps mono / 22050 Hz keeps a 10-second
/// clip ≈ 40 KB, so even a long one fits comfortably under the 25 MB
/// media-blob cap.
///
/// Recording stays on the main actor — the underlying recorder is
/// thread-safe enough for our usage and centralising on @MainActor
/// avoids the SwiftUI binding hops the chat input bar would otherwise
/// need.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = VoiceRecorder()

    /// True while the mic is open. Bound by ChatView to render the
    /// recording bar / pulsing red dot.
    @Published private(set) var isRecording: Bool = false
    /// Duration ticker used by the in-input recording indicator. Driven
    /// by a 0.1s timer that we cancel on stop.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Live mic level in [0, 1], from `averagePower(forChannel:)`. Drives
    /// the small bouncing waveform next to the timer.
    @Published private(set) var level: Float = 0

    /// Hard cap so a forgotten "hold" can't fill the disk. Two minutes
    /// is the same upper bound Telegram uses for voice messages.
    static let maxDuration: TimeInterval = 120

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var tickTimer: Timer?
    private var startedAt: Date?

    private override init() { super.init() }

    /// Request mic permission + spin up the recorder. Returns nil if
    /// the user has denied access or the audio session can't be set
    /// up. The chat UI surfaces a one-line "Enable mic in Settings"
    /// hint on nil so the user knows why the bubble didn't send.
    func start() async -> Bool {
        let granted = await requestPermission()
        guard granted else { return false }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` so we can also bring up the player
            // immediately after for sender-side preview without a
            // session re-config. `.allowBluetooth` matches the
            // call/room policy.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("[VoiceRecorder] audio session failed: \(error)")
            return false
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rcq-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent("\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let r = try AVAudioRecorder(url: outURL, settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record(forDuration: Self.maxDuration) else {
                print("[VoiceRecorder] record() returned false")
                return false
            }
            recorder = r
            url = outURL
            startedAt = Date()
            isRecording = true
            elapsed = 0
            level = 0
            startTicker()
            return true
        } catch {
            print("[VoiceRecorder] init failed: \(error)")
            return false
        }
    }

    /// Stop and return the produced .m4a URL + duration. Caller is
    /// responsible for cleanup (deleting the temp file once it's
    /// uploaded or discarded).
    func finish() -> (url: URL, duration: TimeInterval)? {
        defer { teardown() }
        guard let r = recorder, let outURL = url else { return nil }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? r.currentTime
        r.stop()
        // AVAudioRecorder only writes the m4a header on stop. If the
        // file is shorter than ~0.3s it usually contains zero audio
        // frames and would render as a 0-duration bubble — treat as
        // cancelled.
        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        return (outURL, duration)
    }

    /// User slid up to cancel — drop the file, no upload, no bubble.
    func cancel() {
        if let outURL = url {
            try? FileManager.default.removeItem(at: outURL)
        }
        recorder?.stop()
        teardown()
    }

    // MARK: - internals

    private func teardown() {
        tickTimer?.invalidate()
        tickTimer = nil
        recorder = nil
        url = nil
        startedAt = nil
        isRecording = false
        elapsed = 0
        level = 0
        // Best-effort session deactivation; Player will reactivate
        // for playback. Failing to deactivate is harmless — the next
        // category-set covers it.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                r.updateMeters()
                // averagePower returns dB in [-160, 0]; map to 0…1 with
                // a soft floor so silence reads ~0 and normal speech
                // peaks near 0.6-0.8.
                let dB = r.averagePower(forChannel: 0)
                let normalised = max(0, (dB + 50) / 50)
                self.level = Float(min(1.0, max(0, normalised)))
            }
        }
        if let timer = tickTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            // iOS 17 deprecated `AVAudioSession.sharedInstance().requestRecordPermission`
            // in favour of `AVAudioApplication.requestRecordPermission`,
            // but the old call still works on every supported target
            // (iOS 16+). Sticking with it keeps a single code path.
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Hit when the duration cap kicks in (`record(forDuration:)`).
        // We don't auto-finish here — the chat input bar polls
        // `isRecording` and decides whether to ship the bubble. If
        // the user is still holding when the cap hits, AVAudioRecorder
        // stops on its own and our `isRecording` stays true until
        // the user releases the button (which calls `finish()`).
        Task { @MainActor [weak self] in
            self?.isRecording = false
        }
    }
}
