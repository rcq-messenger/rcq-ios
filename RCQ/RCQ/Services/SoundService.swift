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

    /// Separate toggles for the contact-online and contact-offline
    /// chimes — testers wanted to mute one without the other (e.g.
    /// keep the "X is online" cue but lose the "X went offline"
    /// chirp that fired on every brief WS drop). Both default off
    /// because the original combined toggle was opted out of by
    /// nearly every tester who tried it.
    @Published var contactOnlineSoundEnabled: Bool = UserDefaults.standard.object(forKey: "sound.contact_online_enabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(contactOnlineSoundEnabled, forKey: "sound.contact_online_enabled") }
    }
    @Published var contactOfflineSoundEnabled: Bool = UserDefaults.standard.object(forKey: "sound.contact_offline_enabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(contactOfflineSoundEnabled, forKey: "sound.contact_offline_enabled") }
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
        // Presence chimes ride their own (separate) toggles. Default-
        // off so testers who hate the in-out chatter aren't forced to
        // mute ALL sounds to silence them.
        if cue == .contactOnline && !contactOnlineSoundEnabled { return }
        if cue == .contactOffline && !contactOfflineSoundEnabled { return }
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

    /// Incoming-message playback (jeton-bought sound packs are gone after pivot).
    func playIncoming(fromUIN uin: Int?, thread: ThreadID? = nil) {
        guard isEnabled else { return }
        if let thread, isMuted(thread: thread) { return }
        play(.messageIncoming, thread: thread)
    }

    private var customPlayers: [String: AVAudioPlayer] = [:]
    private func customPlayer(packID: String) -> AVAudioPlayer? {
        if let cached = customPlayers[packID] { return cached }
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
        // Mirror to backend so the push fan-out can suppress APNs
        // alerts for muted threads. 1:1 → `muted_uins`; groups →
        // `muted_group_ids`.
        switch thread {
        case .peer(let uin):
            Task { await NotificationPrefsService.shared.setMuted(uin, muted: nowMuted) }
        case .group(let gid):
            Task { await NotificationPrefsService.shared.setGroupMuted(gid, muted: nowMuted) }
        }
    }

    private static func key(for thread: ThreadID) -> String {
        "\(thread.kindString):\(thread.rawKey)"
    }
}
