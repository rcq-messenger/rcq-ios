import AVFoundation
import AudioToolbox
import Foundation

/// Plays ICQ-style sounds. Uses `.ambient` so the hardware silent switch silences playback.
@MainActor
final class SoundService: ObservableObject {
    static let shared = SoundService()

    // Only the live cues remain — the casino/lootbox/temper games and
    // their sounds were removed with the cosmetics pivot.
    enum Cue: String, CaseIterable {
        case messageIncoming
        case contactOnline
        case contactOffline
        case messageSent
        case joinMe
        case joinAll
    }

    private func filename(for cue: Cue) -> String? {
        switch cue {
        case .messageIncoming:   return "message_incoming"
        case .contactOnline:     return "contact_online"
        case .contactOffline:    return "contact_offline"
        case .messageSent:       return "message_sent"
        case .joinMe:            return "join-me"
        case .joinAll:           return "join-all"
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

    /// Per-thread "mentions only" set (group threads). Disjoint from
    /// `mutedThreads`: a thread is at most one of all/mentions/none.
    @Published private(set) var mentionsOnlyThreads: Set<String> = Set(
        (UserDefaults.standard.array(forKey: "sound.mentions_only_threads") as? [String]) ?? []
    )

    /// Per-thread notification preference. `.none` = silent everywhere
    /// (server-backed mute). `.mentions` = quiet except when @mentioned
    /// (client-side; the server still pushes since it can't read sealed
    /// content, and the NSE/foreground gate filters). `.all` = default.
    enum NotifyMode: String { case all, mentions, none }

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

    /// Current 3-way notification mode for a thread.
    func notifyMode(thread: ThreadID) -> NotifyMode {
        let k = Self.key(for: thread)
        if mutedThreads.contains(k) { return .none }
        if mentionsOnlyThreads.contains(k) { return .mentions }
        return .all
    }

    /// Set the 3-way notification mode. `.none` flips the server-backed mute
    /// on (so the fan-out skips the push entirely); `.mentions`/`.all` clear
    /// it (the client filters instead). The mentions-only group set is
    /// mirrored to the App Group so the NSE can drop non-mention pushes.
    func setNotifyMode(_ mode: NotifyMode, thread: ThreadID) {
        let k = Self.key(for: thread)
        let wasMuted = mutedThreads.contains(k)
        switch mode {
        case .none:     mutedThreads.insert(k);  mentionsOnlyThreads.remove(k)
        case .mentions: mutedThreads.remove(k);  mentionsOnlyThreads.insert(k)
        case .all:      mutedThreads.remove(k);  mentionsOnlyThreads.remove(k)
        }
        UserDefaults.standard.set(Array(mutedThreads), forKey: "sound.muted_threads")
        UserDefaults.standard.set(Array(mentionsOnlyThreads), forKey: "sound.mentions_only_threads")
        // Server push-mute reflects ONLY the none-state (server can't tell a
        // mention from sealed content). Only call when it actually changed.
        let nowMuted = (mode == .none)
        if nowMuted != wasMuted {
            switch thread {
            case .peer(let uin):  Task { await NotificationPrefsService.shared.setMuted(uin, muted: nowMuted) }
            case .group(let gid): Task { await NotificationPrefsService.shared.setGroupMuted(gid, muted: nowMuted) }
            }
        }
        // Mirror the mentions-only GROUP ids to the App Group for the NSE.
        let mentionGroupIDs: [Int] = mentionsOnlyThreads.compactMap { key in
            key.hasPrefix("group:") ? Int(key.dropFirst("group:".count)) : nil
        }
        MutedStore.shared.setMentionsOnlyGroups(mentionGroupIDs)
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

    /// The group ids the UI currently holds fully muted (mode == .none).
    /// Backed by UserDefaults, so this survives relaunches even when the
    /// optimistic server PUT failed (offline, expired token) —
    /// NotificationPrefsService re-asserts these after its next successful
    /// sync instead of letting the server's stale (empty) list win.
    func mutedGroupIDsSnapshot() -> [Int] {
        mutedThreads.compactMap { $0.hasPrefix("group:") ? Int($0.dropFirst("group:".count)) : nil }
    }

    func mutedUINsSnapshot() -> [Int] {
        mutedThreads.compactMap { $0.hasPrefix("peer:") ? Int($0.dropFirst("peer:".count)) : nil }
    }

    private static func key(for thread: ThreadID) -> String {
        "\(thread.kindString):\(thread.rawKey)"
    }
}
