import AVFoundation
import AudioToolbox
import Foundation

/// Plays ICQ-style sounds. Uses `.ambient` so the hardware silent switch silences playback.
@MainActor
final class SoundService: ObservableObject {
    static let shared = SoundService()

    enum Cue: String, CaseIterable {
        case messageIncoming
        case contactOnline
        case contactOffline
        case messageSent
        case typing
        case lootboxOpen
        case temperSuccess
        case temperFail
        case joinMe
        case joinAll
        case crashBetPlaced
        case crashRunning
        case crashCashout
        case crashBurn
        case hiloFlip
        case hiloWin
        case hiloLose
        case limboRolling
        case limboWin
        case limboLose
        case auctionBidPlaced
        case auctionOutbid
        case auctionWon
        case auctionSoftClose
    }

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
        case .crashBetPlaced,
             .crashRunning,
             .hiloFlip,
             .auctionBidPlaced:  return nil
        }
    }

    // SystemSoundID reference: https://github.com/TUNER88/iOSSystemSoundsLibrary
    private func systemSoundID(for cue: Cue) -> SystemSoundID? {
        switch cue {
        case .crashBetPlaced,
             .auctionBidPlaced:  return 1306
        case .crashRunning:      return 1257
        case .hiloFlip:          return 1104
        default:                 return nil
        }
    }

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: "sound.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "sound.enabled") }
    }

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

    private var previewPlayer: AVAudioPlayer?

    /// Preview a voice-pack. Switches to `.playback` so silent switch doesn't mute, then reverts.
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
        previewPlayer = player
        player.currentTime = 0
        let started = player.play()
        print("[SoundService] preview: played \(kind.id) → \(started ? "OK" : "FAILED")")
        let revertAfter = max(0.5, player.duration + 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + revertAfter) { [weak self] in
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true, options: [])
            self?.previewPlayer = nil
        }
    }

    /// Incoming-message playback with optional per-contact pack override.
    func playIncoming(fromUIN uin: Int?, thread: ThreadID? = nil) {
        guard isEnabled else { return }
        if let thread, isMuted(thread: thread) { return }
        let packID: String? = uin.flatMap { ContactSoundStore.shared.packID(for: $0) }
        if let packID, packID != SoundPack.default.id, let custom = customPlayer(packID: packID) {
            custom.currentTime = 0
            custom.play()
            return
        }
        play(.messageIncoming, thread: thread)
    }

    private var customPlayers: [String: AVAudioPlayer] = [:]
    private func customPlayer(packID: String) -> AVAudioPlayer? {
        if let cached = customPlayers[packID] { return cached }
        if let kind = ItemsService.shared.catalog?.kind(by: packID),
           kind.section == .voices,
           let player = loadPlayerForKind(kind) {
            customPlayers[packID] = player
            return player
        }
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
        // Mirror to backend `push_preferences.muted_uins` for 1:1 only; groups stay client-side.
        if case .peer(let uin) = thread {
            Task { await NotificationPrefsService.shared.setMuted(uin, muted: nowMuted) }
        }
    }

    private static func key(for thread: ThreadID) -> String {
        "\(thread.kindString):\(thread.rawKey)"
    }
}
