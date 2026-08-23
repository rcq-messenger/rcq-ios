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

    private nonisolated static func filename(for cue: Cue) -> String? {
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

    /// Cue players, in a lock-protected box rather than main-actor state, so
    /// `prewarm()` can build them on a background queue. `AVAudioPlayer` is
    /// created on one thread and played from another all over iOS; what is not
    /// safe is two threads writing the same dictionary, and that is what the
    /// lock is for.
    private final class PlayerCache: @unchecked Sendable {
        private let lock = NSLock()
        private var players: [Cue: AVAudioPlayer] = [:]

        func get(_ cue: Cue) -> AVAudioPlayer? {
            lock.lock()
            defer { lock.unlock() }
            return players[cue]
        }

        /// Keeps the first player built for a cue. `play` and `prewarm` can
        /// both build one for the same cue in the same instant; either is
        /// playable, and returning the incumbent means nobody swaps a player
        /// out from under a `play()` in flight.
        func putIfAbsent(_ player: AVAudioPlayer, for cue: Cue) -> AVAudioPlayer {
            lock.lock()
            defer { lock.unlock() }
            if let existing = players[cue] { return existing }
            players[cue] = player
            return player
        }
    }

    private let players = PlayerCache()
    private var sessionConfigured = false
    private var prewarmed = false

    /// Deliberately empty. This singleton is a `@StateObject` of
    /// `ContactListView`, so its initialiser is the last thing that runs before
    /// the first painted chat list, and it used to activate an `AVAudioSession`
    /// and open, parse and prepare six audio files there. Measured on the
    /// simulator: 25 ms for the first `setCategory` (it wakes mediaserverd),
    /// 5 ms for `setActive`, 90 ms for the six players. None of it is needed to
    /// draw a list of contacts.
    private init() {}

    /// Builds the six cue players off the main thread. Called from
    /// `RootView.task`, so it starts after the first frame rather than before
    /// it, and it costs the main thread nothing at all.
    ///
    /// Deliberately does NOT touch `AVAudioSession`: that stays lazy in
    /// `ensureSessionConfigured` below, on the main actor, where it can see
    /// whether a call or a room owns the session. Doing it from here would open
    /// a window in which a call started in the same instant gets `.ambient` set
    /// on top of its `playAndRecord`.
    func prewarm() {
        guard !prewarmed else { return }
        prewarmed = true
        let cache = players
        DispatchQueue.global(qos: .utility).async {
            for cue in Cue.allCases {
                guard cache.get(cue) == nil, let built = Self.makePlayer(for: cue) else { continue }
                _ = cache.putIfAbsent(built, for: cue)
            }
        }
    }

    /// Configure and activate the shared session, once, and only from outside a
    /// conversation.
    ///
    /// ⚠ The guard is the whole point. `preload()` used to run at launch, long
    /// before any call or room existed, so the `.ambient` category was always
    /// set on an idle session. Called lazily instead, the first cue that plays
    /// could be `joinMe` INSIDE an audio room, and setting `.ambient` on top of
    /// a live `playAndRecord`/`voiceChat` session kills the room's audio. Skip
    /// it there (the room owns an active session, the cue is audible through
    /// it, which is exactly what happened before) and leave the flag down so a
    /// later chime outside a conversation still configures it.
    private func ensureSessionConfigured() {
        guard !sessionConfigured, !inConversation else { return }
        sessionConfigured = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// One player per cue, taken from the cache or built on the spot when a cue
    /// plays before `prewarm` got to it.
    private func player(for cue: Cue) -> AVAudioPlayer? {
        if let cached = players.get(cue) { return cached }
        guard let built = Self.makePlayer(for: cue) else { return nil }
        return players.putIfAbsent(built, for: cue)
    }

    /// Pure: opens the bundled file and prepares a player. Callable from any
    /// thread, which is what lets `prewarm` run off the main one.
    private nonisolated static func makePlayer(for cue: Cue) -> AVAudioPlayer? {
        guard let basename = Self.filename(for: cue) else { return nil }
        for ext in ["aif", "aiff", "wav", "m4a", "mp3"] {
            guard let url = Bundle.main.url(forResource: basename, withExtension: ext) else { continue }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                return player
            }
        }
        return nil
    }

    // MARK: - playback

    /// A conversation is up: our own call, an audio room, or a radio session.
    ///
    /// The audio session is configured for voice in all three (playAndRecord +
    /// voiceChat/videoChat) and is ACTIVE, so a chime does not get suppressed
    /// by anything — it plays straight into the call route, at call volume.
    /// That is report #424: a contact coming online announced itself in the
    /// middle of a conversation.
    private var inConversation: Bool {
        if CallService.shared.state.isActive { return true }
        if AudioRoomService.shared.activeRoomID != nil { return true }
        if RadioService.shared.activeRoom != nil || RadioService.shared.activeOneToOne != nil { return true }
        return false
    }

    func play(_ cue: Cue, thread: ThreadID? = nil) {
        guard isEnabled else { return }
        // ⚠ Deliberately NOT a blanket guard at the top of play(): joinMe and
        // joinAll are the audio room's own confirmations ("you are in", "someone
        // joined"), and they are supposed to be heard from INSIDE a room. Only
        // the chimes that can wait are silenced.
        switch cue {
        case .messageIncoming, .contactOnline, .contactOffline, .messageSent:
            if inConversation { return }
        case .joinMe, .joinAll:
            break
        }
        // Presence chimes ride their own (separate) toggles. Default-
        // off so testers who hate the in-out chatter aren't forced to
        // mute ALL sounds to silence them.
        if cue == .contactOnline && !contactOnlineSoundEnabled { return }
        if cue == .contactOffline && !contactOfflineSoundEnabled { return }
        if let thread, isMuted(thread: thread) { return }
        ensureSessionConfigured()
        if let player = player(for: cue) {
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
