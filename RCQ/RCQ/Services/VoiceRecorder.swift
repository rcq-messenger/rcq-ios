import AVFoundation
import Foundation

/// Hold-to-record voice messages into a temp .m4a (AAC 32 kbps mono / 22050 Hz).
@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = VoiceRecorder()

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Mic level in [0, 1] from `averagePower(forChannel:)`.
    @Published private(set) var level: Float = 0

    static let maxDuration: TimeInterval = 120

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var tickTimer: Timer?
    private var startedAt: Date?
    /// Tracks the in-flight `start()` Task so a synchronously-fired
    /// `finish()` / `cancel()` can wait for setup to complete before
    /// inspecting recorder state. Without this, a too-fast tap (touch
    /// down → touch up before the async `start` chain resolves) would
    /// orphan the recorder: `finish()` saw `recorder == nil` and bailed,
    /// then `start` finally landed and left `isRecording = true` with no
    /// gesture able to stop it — every subsequent mic tap was a no-op.
    private var startTask: Task<Bool, Never>?

    private override init() { super.init() }

    /// Idempotent: concurrent calls share the same in-flight Task and
    /// resolve to the same Bool. Safe to call from a gesture's onChanged
    /// that may fire multiple times during a single touch.
    func start() async -> Bool {
        if let existing = startTask {
            return await existing.value
        }
        let task = Task<Bool, Never> { @MainActor in
            await self.startImpl()
        }
        startTask = task
        let ok = await task.value
        // Leave startTask set until teardown clears it. `awaitStart()`
        // and finish/cancel rely on this to detect "start already done".
        return ok
    }

    private func startImpl() async -> Bool {
        let granted = await requestPermission()
        guard granted else { return false }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord so sender-side preview works without re-config.
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

    /// Returns nil if too short to be a valid bubble. Caller cleans up
    /// the file. Awaits any in-flight `start()` first — a fast tap that
    /// fires onEnded before `startImpl()` finished must still tear down
    /// the recorder that's about to come up, otherwise it lingers and
    /// breaks every subsequent mic press.
    func finish() async -> (url: URL, duration: TimeInterval)? {
        if let task = startTask { _ = await task.value }
        defer { teardown() }
        guard let r = recorder, let outURL = url else { return nil }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? r.currentTime
        r.stop()
        // < 0.3s usually means zero audio frames — treat as cancelled.
        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        return (outURL, duration)
    }

    /// Async so a swipe-up cancel after a fast tap waits for the
    /// in-flight start to land before tearing it down.
    func cancel() async {
        if let task = startTask { _ = await task.value }
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
        startTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                r.updateMeters()
                // averagePower returns dB in [-160, 0]; map to [0, 1] with a soft floor.
                let dB = r.averagePower(forChannel: 0)
                let normalised = max(0, (dB + 50) / 50)
                self.level = Float(min(1.0, max(0, normalised)))
            }
        }
        if let timer = tickTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            // iOS 17 deprecated this in favor of AVAudioApplication, but it still works on iOS 16+.
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Fires when duration cap hits; chat input bar decides whether to ship.
        Task { @MainActor [weak self] in
            self?.isRecording = false
        }
    }
}
