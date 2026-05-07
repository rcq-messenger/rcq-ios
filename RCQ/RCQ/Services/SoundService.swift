import AVFoundation
import AudioToolbox
import Foundation

/// Plays the classic ICQ sounds. Respects iOS silent mode (we use the `.ambient`
/// audio session category, which is silenced by the hardware switch) and a
/// global enable flag. Per-thread mute lets the user kill notifications for an
/// individual peer or group without nuking the whole sound system.
@MainActor
final class SoundService: ObservableObject {
    static let shared = SoundService()

    enum Cue: String, CaseIterable {
        case messageIncoming
        case contactOnline
        case contactOffline
        case messageSent
        case typing
        // Lootbox / temper effects. Lootbox `open` plays on the
        // reveal overlay; `success`/`fail` on temper outcome.
        case lootboxOpen
        case temperSuccess
        case temperFail
        // Audio-room entry sounds.
        case joinMe
        case joinAll
        // ── Game effects ─────────────────────────────────────────
        case crashBetPlaced     // small system tick, no asset
        case crashRunning       // light whoosh, system fallback
        case crashCashout       // celebratory_chime
        case crashBurn          // thud
        case hiloFlip           // system tock (card flip)
        case hiloWin            // celebratory_chime
        case hiloLose           // fail_tone
        case limboRolling       // rolling
        case limboWin           // celebratory_chime
        case limboLose          // fail_tone
        case auctionBidPlaced   // system tick
        case auctionOutbid      // alert
        case auctionWon         // celebratory_chime
        case auctionSoftClose   // tense_beep
    }

    /// Asset basename for cues that map to a bundled audio file.
    /// Multiple cues can map to the same file (`celebratory_chime`
    /// is reused across HiLo/Limbo/Crash/Auction win events). Cues
    /// that don't have a file return `nil` — callers fall through
    /// to the system-sound or haptic path.
    private func filename(for cue: Cue) -> String? {
        switch cue {
        case .messageIncoming:   return "message_incoming"
        case .contactOnline:     return "contact_online"
        case .contactOffline:    return "contact_offline"
        case .messageSent:       return "message_sent"
        case .typing:            return "typing"
        case .lootboxOpen:       return "open"
        case .temperSuccess:     return "success"
        case .temperFail:        return "fail"
        case .joinMe:            return "join-me"
        case .joinAll:           return "join-all"
        case .crashCashout,
             .hiloWin,
             .limboWin,
             .auctionWon:        return "celebratory_chime"
        case .crashBurn:         return "thud"
        case .hiloLose,
             .limboLose:         return "fail_tone"
        case .limboRolling:      return "rolling"
        case .auctionOutbid:     return "alert"
        case .auctionSoftClose:  return "tense_beep"
        // No bundled asset — falls back to a system-sound id below.
        case .crashBetPlaced,
             .crashRunning,
             .hiloFlip,
             .auctionBidPlaced:  return nil
        }
    }

    /// Apple `SystemSoundID` to play when a cue has no bundled
    /// asset. These are short, stock UI clicks shipped with iOS —
    /// good enough as placeholders until proper effects ship.
    /// Reference: <https://github.com/TUNER88/iOSSystemSoundsLibrary>
    private func systemSoundID(for cue: Cue) -> SystemSoundID? {
        switch cue {
        case .crashBetPlaced,
             .auctionBidPlaced:  return 1306  // begin_record (small click)
        case .crashRunning:      return 1257  // ChromeTab (subtle swoosh-ish)
        case .hiloFlip:          return 1104  // Tock (sharp click)
        default:                 return nil
        }
    }

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: "sound.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "sound.enabled") }
    }

    /// `@Published` so context-menu labels and rows that depend on mute state
    /// can react when the user toggles. Backed by UserDefaults so the choice
    /// survives an app restart.
    @Published private(set) var mutedThreads: Set<String> = Set(
        (UserDefaults.standard.array(forKey: "sound.muted_threads") as? [String]) ?? []
    )

    private var players: [Cue: AVAudioPlayer] = [:]

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        preload()
    }

    private func preload() {
        // Try multiple extensions so the original ICQ Adium pack (.aif) and any
        // future .wav replacements both work without rewiring the loader.
        let candidates = ["aif", "aiff", "wav", "m4a", "mp3"]
        for cue in Cue.allCases {
            guard let basename = filename(for: cue) else { continue }
            for ext in candidates {
                guard let url = Bundle.main.url(forResource: basename, withExtension: ext) else { continue }
                if let player = try? AVAudioPlayer(contentsOf: url) {
                    player.prepareToPlay()
                    players[cue] = player
                    break
                }
            }
        }
    }

    // MARK: - playback

    /// Per-thread playback. If the thread is muted, the cue is silently
    /// skipped. Pass `nil` for global cues like app startup. Cues without
    /// a bundled asset fall back to a stock iOS system sound (see
    /// `systemSoundID(for:)`); without one, the cue is silently dropped.
    func play(_ cue: Cue, thread: ThreadID? = nil) {
        guard isEnabled else { return }
        if let thread, isMuted(thread: thread) { return }
        if let player = players[cue] {
            player.currentTime = 0
            player.play()
            return
        }
        if let sid = systemSoundID(for: cue) {
            AudioServicesPlaySystemSound(sid)
        }
    }

    /// Persisted preview player. Held for the lifetime of playback
    /// so the AVAudioPlayer instance isn't deallocated mid-play —
    /// the local-only player I had before could vanish when the
    /// stack frame popped, leaving silent playback.
    private var previewPlayer: AVAudioPlayer?

    /// One-shot preview of a voice-pack sound. Used by the item
    /// detail sheet's play button so the user can audition the
    /// pack without assigning it to a contact first.
    ///
    /// Bypasses the silent switch by switching the audio session to
    /// `.playback` for the duration of the preview, then reverts to
    /// `.ambient`. Without this, every preview is silenced on the
    /// (very common) phone with the hardware mute toggled — and
    /// users reasonably interpret silence as "the button doesn't
    /// work".
    func preview(kindID: String) {
        guard isEnabled else {
            print("[SoundService] preview: sound disabled")
            return
        }
        guard let kind = ItemsService.shared.catalog?.kind(by: kindID) else {
            print("[SoundService] preview: kind \(kindID) not in catalog (catalog stale?)")
            return
        }
        guard kind.section == .voices else {
            print("[SoundService] preview: kind \(kindID) is not a voice (section=\(kind.section))")
            return
        }
        guard let player = loadPlayerForKind(kind) else {
            print("[SoundService] preview: AVAudioPlayer load failed for assetRef=\(kind.assetRef)")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("[SoundService] preview: audio session setup failed \(error)")
        }
        // Hold the player on `self` so it survives past this scope.
        previewPlayer = player
        player.currentTime = 0
        let started = player.play()
        print("[SoundService] preview: played \(kind.id) → \(started ? "OK" : "FAILED")")
        // Restore the ambient category once playback finishes so
        // notification cues elsewhere still respect the silent switch.
        let revertAfter = max(0.5, player.duration + 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + revertAfter) { [weak self] in
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true, options: [])
            self?.previewPlayer = nil
        }
    }

    /// Incoming-message playback with optional per-contact pack
    /// override. ICQ-classic feature: the same `messageIncoming`
    /// cue plays a different sound depending on who sent the
    /// message. Pack assignments live in `ContactSoundStore`;
    /// inventory of available packs comes from `SoundPack` (and
    /// later from the user's lootbox Voices inventory). Falls
    /// through to the default `messageIncoming` player when no
    /// override is registered or the pack's asset isn't bundled
    /// yet.
    func playIncoming(fromUIN uin: Int?, thread: ThreadID? = nil) {
        guard isEnabled else { return }
        if let thread, isMuted(thread: thread) { return }
        // Look up the per-contact override on the main actor; this
        // method is already @MainActor via the class annotation, so
        // the synchronous read is safe.
        let packID: String? = uin.flatMap { ContactSoundStore.shared.packID(for: $0) }
        if let packID, packID != SoundPack.default.id, let custom = customPlayer(packID: packID) {
            custom.currentTime = 0
            custom.play()
            return
        }
        play(.messageIncoming, thread: thread)
    }

    /// Lazy-loaded custom-pack player. Cached per pack id so we
    /// don't re-decode the asset on every notification. Returns
    /// nil when the pack's asset isn't bundled — caller falls
    /// through to the default cue.
    private var customPlayers: [String: AVAudioPlayer] = [:]
    private func customPlayer(packID: String) -> AVAudioPlayer? {
        if let cached = customPlayers[packID] { return cached }
        // The pack id is a voice-section kind id from the user's
        // inventory. Resolve the asset path through the catalog so
        // sounds shipped via the lootbox land at their declared
        // bundle location instead of forcing every pack to live as
        // `<id>.aif` flat in Sounds/.
        if let kind = ItemsService.shared.catalog?.kind(by: packID),
           kind.section == .voices,
           let player = loadPlayerForKind(kind) {
            customPlayers[packID] = player
            return player
        }
        // Legacy / direct-name fallback. Older `ContactSoundStore`
        // assignments (pre-marketplace) used hardcoded ids like
        // `icq_classic`; the lookup below misses gracefully so the
        // caller can fall through to the default cue.
        let candidates = ["aif", "aiff", "wav", "m4a", "mp3"]
        for ext in candidates {
            guard let url = Bundle.main.url(forResource: packID, withExtension: ext) else { continue }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                customPlayers[packID] = player
                return player
            }
        }
        return nil
    }

    /// Build an AVAudioPlayer from a voice-section `ItemKind`'s
    /// `assetRef`. The asset ref shape mirrors what the inventory
    /// grid uses: `items/voices/<stem>.<ext>` rooted under the
    /// app bundle's `Resources/`. Bundles ship flattened (per the
    /// xcodegen folder-reference behaviour documented on
    /// `ItemAssetImage`) so the flat lookup is the canonical path
    /// — the subdir attempt is a paranoid first try.
    private func loadPlayerForKind(_ kind: ItemKind) -> AVAudioPlayer? {
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let basename = (trimmed as NSString).lastPathComponent
        let stem = (basename as NSString).deletingPathExtension
        let ext = (basename as NSString).pathExtension
        let exts = ext.isEmpty ? ["mp3", "aif", "aiff", "wav", "m4a"] : [ext]
        for tryExt in exts {
            if let url = Bundle.main.url(forResource: stem, withExtension: tryExt) {
                do {
                    let p = try AVAudioPlayer(contentsOf: url)
                    p.prepareToPlay()
                    return p
                } catch {
                    print("[SoundService] AVAudioPlayer init failed for \(url.lastPathComponent): \(error)")
                }
            }
        }
        print("[SoundService] no asset found for stem=\(stem) ext=\(ext) (assetRef=\(kind.assetRef))")
        return nil
    }

    // MARK: - mute

    func isMuted(thread: ThreadID) -> Bool {
        mutedThreads.contains(Self.key(for: thread))
    }

    func toggleMute(thread: ThreadID) {
        let k = Self.key(for: thread)
        let nowMuted: Bool
        if mutedThreads.contains(k) {
            mutedThreads.remove(k)
            nowMuted = false
        } else {
            mutedThreads.insert(k)
            nowMuted = true
        }
        UserDefaults.standard.set(Array(mutedThreads), forKey: "sound.muted_threads")
        // Mirror per-peer mute to the backend's `push_preferences.muted_uins`
        // so APNs pushes stop firing for muted senders too. Only propagates
        // for 1:1 threads — the muted list is UIN-keyed; group threads have
        // no equivalent server-side knob in v1 (would need per-recipient
        // group-membership filtering, scope creep). Group mute therefore
        // remains client-side sound-only.
        if case .peer(let uin) = thread {
            Task { await NotificationPrefsService.shared.setMuted(uin, muted: nowMuted) }
        }
    }

    private static func key(for thread: ThreadID) -> String {
        "\(thread.kindString):\(thread.rawKey)"
    }
}
