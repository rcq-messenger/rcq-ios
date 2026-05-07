import AVFoundation
import Foundation

/// Single-instance audio player that voice bubbles share. Tapping play
/// on a different bubble while one is already playing pauses the first
/// — Telegram / WhatsApp behaviour, the user expects only one voice at
/// a time.
///
/// The bubble views observe `playingMessageID` and `progress` to drive
/// their play/pause icon and the elapsed pill.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    /// id of the message whose audio is currently loaded into the
    /// player. Nil = no bubble is active. Bubbles use `playingMessageID
    /// == self.id && isPlaying` to render the pause glyph.
    @Published private(set) var playingMessageID: UUID?
    @Published private(set) var isPlaying: Bool = false
    /// Progress in [0, 1]. Updated by a 0.05s timer while playing.
    @Published private(set) var progress: Double = 0
    /// Elapsed seconds for the small pill on the bubble.
    @Published private(set) var elapsed: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// Map message id → decrypted local file URL so a second play
    /// doesn't re-fetch + re-decrypt. URLs live in the temp directory,
    /// iOS may evict them; the cache survives at most until the next
    /// app launch.
    private var fileCache: [UUID: URL] = [:]

    private override init() { super.init() }

    /// Toggle: same id playing → pause. Same id paused → resume. Other
    /// id → load + start that one (current playback stops).
    func toggle(messageID: UUID, mediaToken: String?) {
        if playingMessageID == messageID, let p = player {
            if p.isPlaying { pause() } else { resume() }
            return
        }
        Task { await load(messageID: messageID, mediaToken: mediaToken) }
    }

    func stop() {
        player?.stop()
        player = nil
        ticker?.invalidate()
        ticker = nil
        playingMessageID = nil
        isPlaying = false
        progress = 0
        elapsed = 0
    }

    // MARK: - internals

    private func load(messageID: UUID, mediaToken: String?) async {
        // Stop whatever's currently going so the next bubble starts clean.
        if player != nil { stop() }

        let url: URL
        if let cached = fileCache[messageID], FileManager.default.fileExists(atPath: cached.path) {
            url = cached
        } else {
            guard let token = mediaToken else { return }
            let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let mediaID = parts[0]
            let key = parts[1]
            guard let decrypted = await MediaService.shared.decryptToFile(mediaID: mediaID, keyBase64: key) else {
                return
            }
            // decryptToFile names the file with .mp4; rename to .m4a
            // so AVAudioPlayer is happy. Both are MPEG-4 containers
            // and AVAudioPlayer accepts either, but the explicit
            // extension simplifies any later sharing/export.
            let m4aURL = decrypted.deletingPathExtension().appendingPathExtension("m4a")
            try? FileManager.default.removeItem(at: m4aURL)
            try? FileManager.default.moveItem(at: decrypted, to: m4aURL)
            fileCache[messageID] = m4aURL
            url = m4aURL
        }

        // Audio session — `.playback` so the speaker stays loud even
        // when the silent switch is on (matches every messenger). If
        // the user had earphones plugged in or BT connected, iOS
        // routes there automatically.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            print("[VoicePlayer] session config failed: \(error)")
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else { return }
            player = p
            playingMessageID = messageID
            isPlaying = true
            startTicker()
        } catch {
            print("[VoicePlayer] AVAudioPlayer init failed: \(error)")
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    private func resume() {
        guard let p = player else { return }
        if p.play() {
            isPlaying = true
            startTicker()
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.elapsed = p.currentTime
                self.progress = p.duration > 0 ? min(1.0, p.currentTime / p.duration) : 0
            }
        }
        if let timer = ticker { RunLoop.main.add(timer, forMode: .common) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}
