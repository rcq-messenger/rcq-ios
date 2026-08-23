import AVFoundation
import Combine
import Foundation

/// THE audio playback owner for the process. Voice messages, audio files
/// attached as documents and the composer's not-yet-sent recording all go
/// through this one object, which owns exactly one `AVAudioPlayer` at a
/// time. Starting anything stops whatever was going - Telegram / WhatsApp
/// behaviour, and the only way to guarantee two clips never overlap.
///
/// It is also the source of truth for the app-wide now-playing strip
/// (`AudioPlayerBar`): `nowPlaying` is non-nil exactly while the strip
/// should be on screen, so playback outliving the chat screen is a
/// property of this object rather than of any view.
///
/// ## Why the exclusion is enforced from here
/// The other things that can make sound (`WebRTCManager` for a call,
/// `RingbackPlayer` for the outgoing tone, `AudioRoomMeshManager` +
/// `RadioVoiceEngine` for a room) each configure `AVAudioSession`
/// themselves and are driven by their own services. Rather than teach all
/// of them about clip playback, playback yields to them: it refuses to
/// start while a call or a room is live, and it stops itself the moment
/// one becomes live. One direction, one place, no cross-service
/// handshake.
///
/// The bubble views observe `playingMessageID` / `isPlaying` / `progress`
/// to drive their play-pause icon and the elapsed pill.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    /// Everything the now-playing strip needs. Nil for the composer's
    /// preview clip, which is auditioned inside a pill that already has
    /// its own controls and dies with the draft - a strip for it would be
    /// a second set of controls for one sound, which is the exact thing
    /// item 9a is about.
    struct NowPlaying: Equatable {
        enum Kind: Equatable { case voiceMessage, audioFile }
        let messageID: UUID
        let kind: Kind
        let title: String
    }

    /// id of the message whose audio is currently loaded into the
    /// player. Nil = nothing is active. Bubbles use `playingMessageID
    /// == self.id && isPlaying` to render the pause glyph.
    @Published private(set) var playingMessageID: UUID?
    @Published private(set) var isPlaying: Bool = false
    /// Progress in [0, 1]. Updated by a 0.05s timer while playing.
    @Published private(set) var progress: Double = 0
    /// Elapsed seconds for the small pill on the bubble.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Total seconds of the loaded clip, 0 when nothing is loaded.
    @Published private(set) var duration: TimeInterval = 0
    /// Non-nil exactly while the app-wide strip should be visible.
    @Published private(set) var nowPlaying: NowPlaying?

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// Map message id → decrypted local file URL so a second play
    /// doesn't re-fetch + re-decrypt. URLs live in the temp directory,
    /// iOS may evict them; the cache survives at most until the next
    /// app launch.
    private var fileCache: [UUID: URL] = [:]
    /// True while WE are the ones holding the audio session active, so
    /// `stop()` knows whether it has anything to hand back.
    private var sessionActive = false
    private var watchers: Set<AnyCancellable> = []
    /// Last seen session identity, so the watchers below can tell a real
    /// transition from the value a `@Published` replays on subscribe.
    private var sessionMode: PanicPINService.SessionMode = .none
    private var accountID: UUID?

    private override init() {
        super.init()
        yieldToCallsAndRooms()
        yieldToSessionChanges()
        observeInterruptions()
    }

    // MARK: - public API

    /// Toggle a voice message: same id playing → pause. Same id paused →
    /// resume. Other id → load + start that one (current playback stops).
    func toggle(messageID: UUID, mediaToken: String?) {
        start(
            messageID: messageID,
            mediaToken: mediaToken,
            fileExtension: "m4a",
            entry: NowPlaying(
                messageID: messageID,
                kind: .voiceMessage,
                title: "audio.strip.voice_message".localized
            )
        )
    }

    /// Audition a clip that already exists on disk (the composer's
    /// recorded-but-unsent preview). Deliberately raises no strip.
    func playLocal(id: UUID, url: URL) {
        fileCache[id] = url
        start(messageID: id, mediaToken: nil, fileExtension: url.pathExtension, entry: nil)
    }

    /// Why an audio document did not start. The caller has to tell the two
    /// failures apart: `unplayable` deserves the QuickLook fallback,
    /// `busy` must NOT get it - routing a song into QuickLook while a call
    /// is up is exactly the overlap this class exists to prevent.
    enum AudioFileOutcome { case started, unplayable, busy }

    /// Play an audio document (`.file` message whose mime is `audio/*`).
    @discardableResult
    func playAudioFile(
        messageID: UUID,
        mediaToken: String?,
        title: String,
        fileExtension: String
    ) async -> AudioFileOutcome {
        if competingAudioActive { return .busy }
        if playingMessageID == messageID, player != nil {
            togglePlayPause()
            return .started
        }
        let ok = await load(
            messageID: messageID,
            mediaToken: mediaToken,
            fileExtension: fileExtension,
            entry: NowPlaying(messageID: messageID, kind: .audioFile, title: title)
        )
        // A call that started while the blob was downloading lands here too.
        if !ok, competingAudioActive { return .busy }
        return ok ? .started : .unplayable
    }

    /// Pause / resume whatever is already loaded. No-op when nothing is.
    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying { pause() } else { resume() }
    }

    func stop() {
        teardownPlayer()
        releaseSession()
    }

    /// Everything `stop` does except handing the audio session back. Used
    /// when one clip immediately replaces another: deactivating and
    /// reactivating between two consecutive voice notes is a pointless
    /// route change the user can hear as a click.
    private func teardownPlayer() {
        player?.stop()
        player = nil
        ticker?.invalidate()
        ticker = nil
        playingMessageID = nil
        isPlaying = false
        progress = 0
        elapsed = 0
        duration = 0
        nowPlaying = nil
    }

    // MARK: - internals

    private func start(
        messageID: UUID,
        mediaToken: String?,
        fileExtension: String,
        entry: NowPlaying?
    ) {
        if playingMessageID == messageID, player != nil {
            togglePlayPause()
            return
        }
        Task {
            await load(
                messageID: messageID,
                mediaToken: mediaToken,
                fileExtension: fileExtension,
                entry: entry
            )
        }
    }

    /// A call, an audio room or a radio session owns the audio session while
    /// it lasts.
    ///
    /// ⚠ Radio counts even when its screen is not on top: `RadioVoiceEngine`
    /// keeps `.playAndRecord`/`.videoChat` with a running engine and an
    /// installed input tap for as long as `activeRoom` / `activeOneToOne` is
    /// non-nil, and dismissing the cover does not end the session (only the
    /// back button calls `leaveActiveSession`). Reconfiguring the session to
    /// `.playback` under it pulls the input node out from under the engine and
    /// PTT transmits nothing for the rest of the session. Same state
    /// `SoundService.inConversation` already treats as "a conversation is up".
    private var competingAudioActive: Bool {
        if CallService.shared.state != .idle { return true }
        if AudioRoomService.shared.activeRoomID != nil { return true }
        if RadioService.shared.activeRoom != nil || RadioService.shared.activeOneToOne != nil { return true }
        return false
    }

    @discardableResult
    private func load(
        messageID: UUID,
        mediaToken: String?,
        fileExtension: String,
        entry: NowPlaying?
    ) async -> Bool {
        guard !competingAudioActive else { return false }

        // Stop whatever's currently going so the next clip starts clean.
        // Keep the session: we are about to want it again.
        if player != nil { teardownPlayer() }

        let ext = fileExtension.isEmpty ? "m4a" : fileExtension.lowercased()
        let url: URL
        if let cached = fileCache[messageID], FileManager.default.fileExists(atPath: cached.path) {
            url = cached
        } else {
            // Every bail-out below has to hand the session back: we may
            // still be holding it from the clip `teardownPlayer` just ended.
            guard let token = mediaToken else {
                releaseSession()
                return false
            }
            let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                releaseSession()
                return false
            }
            let mediaID = parts[0]
            let key = parts[1]
            guard let decrypted = await MediaService.shared.decryptToFile(mediaID: mediaID, keyBase64: key) else {
                releaseSession()
                return false
            }
            // decryptToFile names every file `.mp4`. Give it back the
            // extension the payload actually has: `.m4a` for a voice
            // note, the sender's own extension for an audio document.
            // AVAudioPlayer sniffs the container either way, but a wrong
            // extension is what breaks any later share / export.
            let typedURL = decrypted.deletingPathExtension().appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: typedURL)
            try? FileManager.default.moveItem(at: decrypted, to: typedURL)
            fileCache[messageID] = typedURL
            url = typedURL
        }

        // Audio session — `.playback` so the speaker stays loud even
        // when the silent switch is on (matches every messenger). If
        // the user had earphones plugged in or BT connected, iOS
        // routes there automatically.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            sessionActive = true
        } catch {
            print("[VoicePlayer] session config failed: \(error)")
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else {
                releaseSession()
                return false
            }
            player = p
            playingMessageID = messageID
            isPlaying = true
            duration = p.duration
            nowPlaying = entry
            startTicker()
            return true
        } catch {
            print("[VoicePlayer] AVAudioPlayer init failed: \(error)")
            releaseSession()
            return false
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
        guard !competingAudioActive else { return }
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

    /// Hand the audio session back so the next thing that wants it (a
    /// call's earpiece route, the system music app) gets it. Skipped when
    /// a call or a room is up: those configure the session for themselves
    /// and deactivating under them would drop their route.
    ///
    /// ⚠ The CATEGORY is put back too, not just the activation.
    /// `SoundService` sets `.ambient` + `mixWithOthers` once in its init and
    /// never again, and that is the whole reason the hardware silent switch
    /// silences a chime. Deactivating does not reset the category, so without
    /// this every incoming-message chime for the rest of the process would ring
    /// out loud through our `.playback` on a phone set to silent.
    private func releaseSession() {
        guard sessionActive else { return }
        sessionActive = false
        guard !competingAudioActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        try? session.setCategory(.ambient, options: [.mixWithOthers])
    }

    /// Stop the moment a call or a room takes over. `sink` hands us the
    /// INCOMING value - `@Published` fires in `willSet`, so reading
    /// `CallService.shared.state` inside here would still see the old one.
    private func yieldToCallsAndRooms() {
        CallService.shared.$state
            .sink { [weak self] incoming in
                guard incoming != .idle else { return }
                self?.stop()
            }
            .store(in: &watchers)

        AudioRoomService.shared.$activeRoomID
            .sink { [weak self] incoming in
                guard incoming != nil else { return }
                self?.stop()
            }
            .store(in: &watchers)

        RadioService.shared.$activeRoom
            .sink { [weak self] incoming in
                guard incoming != nil else { return }
                self?.stop()
            }
            .store(in: &watchers)

        RadioService.shared.$activeOneToOne
            .sink { [weak self] incoming in
                guard incoming != nil else { return }
                self?.stop()
            }
            .store(in: &watchers)
    }

    /// The clip belongs to the session that started it, and nothing else in
    /// the app stops this object.
    ///
    /// - PIN lock: `PINLockView` replaces the screen that hosts the strip, and
    ///   the strip is the only stop control there is. With `UIBackgroundModes:
    ///   audio` and category `.playback` the clip keeps playing through the
    ///   lock, audible, with no way to stop it short of force-quitting.
    /// - Duress: `wipeForDecoy` clears every in-memory service that could name
    ///   the real account and never knew about this one, so the real clip kept
    ///   playing over the decoy session and the strip came back on the decoy
    ///   home carrying the real title (for an audio document, the sender's own
    ///   filename).
    /// - Account switch / burn: the previous account's clip outlived its
    ///   account and its strip was re-mounted on the next one's home.
    ///
    /// ⚠ `sink` hands us the INCOMING value, same reason as above.
    private func yieldToSessionChanges() {
        PanicPINService.shared.$lockState
            .sink { [weak self] incoming in
                guard incoming == .locked else { return }
                self?.stopIfActive()
            }
            .store(in: &watchers)

        // Entering (or leaving) a decoy session, which can happen without a
        // lock in between when the app is re-opened straight into one.
        PanicPINService.shared.$mode
            .sink { [weak self] incoming in
                guard let self, incoming != self.sessionMode else { return }
                self.sessionMode = incoming
                self.stopIfActive()
            }
            .store(in: &watchers)

        AccountManager.shared.$activeAccountID
            .sink { [weak self] incoming in
                guard let self, incoming != self.accountID else { return }
                self.accountID = incoming
                self.stopIfActive()
            }
            .store(in: &watchers)
    }

    /// `stop()` writes six `@Published` properties, so it is not free to call
    /// on a subscription's first emission or on a transition that changes
    /// nothing. Nothing is playing = nothing to do.
    private func stopIfActive() {
        guard playingMessageID != nil || sessionActive else { return }
        stop()
    }

    /// A phone call (or Siri) takes the session away without telling the
    /// player, which leaves a live-looking strip over dead audio.
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.pause()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}
