import AVFoundation
import AudioToolbox
import Foundation
import UIKit

/// Plays the classic-style cue sounds. Uses `.ambient` so the hardware silent switch silences playback.
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

    /// Every account's silent chats ("None"), by account id (`uuidString`), in
    /// `MuteKeys` spelling. Read through the account pointer at every call, so
    /// no switch path can leave one account's list in front of another's chats.
    ///
    /// ⚠ PER ACCOUNT. This used to be one list for the whole phone, so a chat
    /// muted in one account showed as muted in every other, where the same
    /// number is somebody else (each island numbers on its own) and the same
    /// group id is another group. Somebody on another island is filed by
    /// uin@host for the same reason.
    @Published private var mutedByAccount: [String: Set<String>] = SoundService.loadMap(SoundService.mutedKey)

    /// Per-account "mentions only" groups, same shape. A setting of "None"
    /// clears it; a long-press mute leaves it under the mute.
    @Published private var mentionsByAccount: [String: Set<String>] = SoundService.loadMap(SoundService.mentionsKey)

    /// The phone-wide lists older builds kept, until `migrateLegacyIfNeeded`
    /// has handed them to the accounts that hold those chats. Read beside every
    /// real account's own lists until then, which is where they were in force.
    private var legacy: (muted: Set<String>, mentions: Set<String>)? = SoundService.loadLegacy()
    private var migrating = false

    nonisolated private static let mutedKey = "sound.muted_threads.v2"
    nonisolated private static let mentionsKey = "sound.mentions_only_threads.v2"
    nonisolated private static let legacyMutedKey = "sound.muted_threads"
    nonisolated private static let legacyMentionsKey = "sound.mentions_only_threads"
    /// Set once the hand-out has run, empty lists or not: it also turns the
    /// extension's file into the per-account form.
    nonisolated private static let handedOutKey = "sound.mutes_per_account"

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
                guard cache.get(cue) == nil,
                      let built = Self.makePlayer(for: cue, prepare: false) else { continue }
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
    /// - Parameter prepare: whether to claim the audio hardware now.
    ///
    /// ⚠⚠ FALSE FROM `prewarm`, AND THAT IS THE WHOLE POINT. `prepareToPlay()`
    /// does not just parse the file, it allocates an audio queue and STARTS THE
    /// AUDIO DEVICE. Doing that for six cues at launch, under the category
    /// iOS gives an app that has not set one — `soloAmbient`, which is not
    /// mixable — took the output away from whatever the person was listening
    /// to. Open RCQ, your music stops, and nothing in the app has made a sound
    /// (founder, 07.09). Confirmed in the simulator's own log: at launch
    /// `AudioQueueObject: New output; 1 ch, 22050 Hz` followed by
    /// `AudioDeviceStart (err 0)`, with no session configured.
    ///
    /// The lazy path still prepares, and by then `play` has run
    /// `ensureSessionConfigured` and the category is `.ambient` with
    /// `.mixWithOthers`, so claiming the device costs the music nothing.
    /// Parsing the file — the expensive part, and the reason prewarm exists —
    /// happens in the initialiser either way.
    private nonisolated static func makePlayer(for cue: Cue, prepare: Bool = true) -> AVAudioPlayer? {
        guard let basename = Self.filename(for: cue) else { return nil }
        for ext in ["aif", "aiff", "wav", "m4a", "mp3"] {
            guard let url = Bundle.main.url(forResource: basename, withExtension: ext) else { continue }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                if prepare { player.prepareToPlay() }
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

    /// A chat as the mute lists know it. A peer carries the island they live
    /// on (nil: ours), because the number alone is somebody else on every
    /// other island.
    enum Chat: Hashable {
        case peer(uin: Int, host: String?)
        case group(id: Int)
    }

    /// Whose lists a read or a tap means: the active account's, or in a decoy
    /// session the decoy's own slot, which lives in memory only (the active
    /// account id stays the REAL one during duress, like `LockedChatsStore`).
    /// Nil before there is any account.
    private var slot: String? {
        if PanicPINService.shared.isDecoy { return Self.decoySlot }
        return AccountManager.shared.activeAccountID?.uuidString
    }

    private static var decoySlot: String { PanicPINService.decoyNamespace.uuidString }

    func isMuted(thread: ThreadID) -> Bool { isMuted(chat(for: thread)) }

    func isMuted(_ chat: Chat) -> Bool { has(chat, in: mutedByAccount, legacy: legacy?.muted) }

    /// Current 3-way notification mode for a thread.
    func notifyMode(thread: ThreadID) -> NotifyMode { notifyMode(chat(for: thread)) }

    func notifyMode(_ chat: Chat) -> NotifyMode {
        if isMuted(chat) { return .none }
        if has(chat, in: mentionsByAccount, legacy: legacy?.mentions) { return .mentions }
        return .all
    }

    /// The active account's silent peers, ours by number first, then the
    /// people on other islands: Settings -> Notifications lists them.
    var mutedPeers: [Chat] {
        guard let s = slot else { return [] }
        var keys = mutedByAccount[s] ?? []
        if let legacy, s != Self.decoySlot { keys.formUnion(legacy.muted) }
        let own = keys.compactMap(MuteKeys.ownPeer).sorted().map { Chat.peer(uin: $0, host: nil) }
        let elsewhere: [Chat] = keys.compactMap(MuteKeys.address).sorted().compactMap { address in
            let parts = address.split(separator: "@", maxSplits: 1)
            guard parts.count == 2, let uin = Int(parts[0]) else { return nil }
            return .peer(uin: uin, host: String(parts[1]))
        }
        return own + elsewhere
    }

    /// Set the 3-way notification mode. `.none` flips the server-backed mute
    /// on (so the fan-out skips the push entirely); `.mentions`/`.all` clear
    /// it (the client filters instead). The mentions-only groups reach the
    /// extension with the rest of this account's lists, so it can drop
    /// non-mention pushes.
    func setNotifyMode(_ mode: NotifyMode, thread: ThreadID) { setNotifyMode(mode, chat(for: thread)) }

    func setNotifyMode(_ mode: NotifyMode, _ chat: Chat) {
        switch mode {
        case .none:     change(chat, muted: true, mentions: false)
        case .mentions: change(chat, muted: false, mentions: true)
        case .all:      change(chat, muted: false, mentions: false)
        }
    }

    func toggleMute(thread: ThreadID) { toggleMute(chat(for: thread)) }

    /// Mute or unmute and nothing else: a "mentions only" group keeps that
    /// setting under a mute, and gets it back on the unmute.
    func toggleMute(_ chat: Chat) { change(chat, muted: !isMuted(chat), mentions: nil) }

    /// The one write. Into the active account's lists, and from there to its
    /// island (only what that island keeps, see `MuteKeys.isIslandKept`) and to
    /// the extension. In a decoy session nothing leaves memory: the account on
    /// file is the real one, and nothing done there may reach it.
    private func change(_ chat: Chat, muted: Bool, mentions: Bool?) {
        guard let s = slot else { return }
        let k = Self.key(chat)
        let wasMuted = isMuted(chat)
        var m = mutedByAccount[s] ?? []
        var t = mentionsByAccount[s] ?? []
        if muted { m.insert(k) } else { m.remove(k) }
        if let mentions {
            if mentions { t.insert(k) } else { t.remove(k) }
        }
        mutedByAccount[s] = m.isEmpty ? nil : m
        mentionsByAccount[s] = t.isEmpty ? nil : t
        guard s != Self.decoySlot, let account = UUID(uuidString: s) else { return }
        // Before the hand-out the phone-wide lists still say it, by the number
        // alone too, and they are read beside this account's: taken off there
        // as well, or they would keep saying it.
        if legacy != nil {
            let bare = Self.legacyKey(chat)
            if !muted {
                legacy?.muted.remove(k)
                legacy?.muted.remove(bare)
            }
            if mentions == false {
                legacy?.mentions.remove(k)
                legacy?.mentions.remove(bare)
            }
        }
        save()
        // Server push-mute reflects ONLY the none-state (server can't tell a
        // mention from sealed content). Only sent when it actually changed,
        // for the account the tap was made in, read now.
        if muted != wasMuted {
            if let uin = MuteKeys.ownPeer(k) {
                NotificationPrefsService.shared.setMuted(.peer(uin), muted: muted, account: account)
            } else if let id = MuteKeys.groupID(k), MuteKeys.isIslandKept(k) {
                NotificationPrefsService.shared.setMuted(.group(id), muted: muted, account: account)
            }
        }
        syncExtensionMirror()
    }

    /// What `account`'s island answered it holds muted becomes what this phone
    /// shows for that account: the chats the island keeps follow it (a mute or
    /// an unmute made on another device), everybody on other islands and every
    /// room there stays as it was. `uins`/`groupIDs` already carry the changes
    /// made here that the island has not confirmed (`NotificationPrefsService`),
    /// so an answer to an older read never undoes a tap.
    func adoptIslandMutes(uins: Set<Int>, groupIDs: Set<Int>, account: UUID) {
        guard !PanicPINService.shared.isDecoy else { return }
        let s = account.uuidString
        let current = mutedByAccount[s] ?? []
        let next = MuteKeys.adopt(muted: current, islandUINs: uins, islandGroups: groupIDs)
        guard next != current else { return }
        mutedByAccount[s] = next.isEmpty ? nil : next
        save()
        syncExtensionMirror()
    }

    /// An account that left the device takes its lists with it.
    func forget(accountID: UUID) {
        let s = accountID.uuidString
        let a = mutedByAccount.removeValue(forKey: s) != nil
        let b = mentionsByAccount.removeValue(forKey: s) != nil
        if a || b, !PanicPINService.shared.isDecoy { save() }
        syncExtensionMirror()
    }

    /// Burn hook: the active account's lists and nobody else's. A burn mints a
    /// fresh identity under the same account id, and the chats these named are
    /// gone with the burned one.
    func wipeActiveAccount() {
        guard let s = slot else { return }
        if s == Self.decoySlot { return forgetDecoy() }
        if let id = UUID(uuidString: s) { forget(accountID: id) }
    }

    /// The decoy's lists, when the decoy PIN is removed or a new decoy is
    /// made: kept, a muted chat would say that a decoy session once existed.
    func forgetDecoy() {
        mutedByAccount[Self.decoySlot] = nil
        mentionsByAccount[Self.decoySlot] = nil
    }

    /// Hand the notification extension every account's lists (`MutedStore`),
    /// so a push for an account that is not the active one is judged by that
    /// account's own mutes. Not before the hand-out: until then the file an
    /// older build wrote stands, and the extension reads it the way it was
    /// written. Never the decoy's.
    func syncExtensionMirror() {
        guard legacy == nil, !PanicPINService.shared.isDecoy else { return }
        var map: [String: MutedStore.Lists] = [:]
        for account in AccountManager.shared.accounts {
            let id = account.id.uuidString
            map[id] = MuteKeys.lists(muted: mutedByAccount[id] ?? [], mentions: mentionsByAccount[id] ?? [])
        }
        MutedStore.shared.setAll(map)
    }

    /// Hand the phone-wide lists older builds kept to the accounts that hold
    /// those chats (`MuteKeys.handOut`), once. Called from every real boot and
    /// unlock: it needs the rosters on disk of every account here, so it waits
    /// for a real session with the data key open (a sealed roster cannot be
    /// read), and until it has run the old lists stay in force everywhere.
    func migrateLegacyIfNeeded() async {
        guard legacy != nil, !migrating, Self.mayHandOut else { return }
        migrating = true
        defer { migrating = false }
        let ids = AccountManager.shared.accounts.map(\.id)
        let dataKey = PanicPINService.shared.dataKey
        // The roster files off the main thread: they can be large (see
        // `AppState.hydrateRosterFromDisk`). Numbers and ids only.
        let rosters = await Task.detached(priority: .utility) { () -> [UUID: (peers: Set<Int>?, groups: Set<Int>?)] in
            var out: [UUID: (peers: Set<Int>?, groups: Set<Int>?)] = [:]
            for id in ids {
                let peers = RosterSnapshot.loadOffMain(.contacts, as: RosterNumbers.self, dataKey: dataKey, accountID: id)
                let groups = RosterSnapshot.loadOffMain(.groups, as: [GroupNumber].self, dataKey: dataKey, accountID: id)
                out[id] = (peers?.all, groups.map { Set($0.map(\.id)) })
            }
            return out
        }.value
        // The phone may have moved on while the files were read, and a tap
        // in the meantime may have taken a chat off the old lists.
        guard let pending = legacy, Self.mayHandOut, AccountManager.shared.accounts.map(\.id) == ids else { return }
        var holdings: [String: MuteKeys.Holdings] = [:]
        for id in ids {
            var h = MuteKeys.Holdings()
            let roster = rosters[id]
            h.known = roster?.peers != nil || roster?.groups != nil
            h.peers = roster?.peers ?? []
            h.groups = roster?.groups ?? []
            h.addresses = Set(CrossIslandStore.storedAddresses(accountID: id))
            h.groups.formUnion(VisitedIslandsStore.aliasIDs(accountID: id))
            if let known = AppGroup.strangerQuarantine(accountID: id)?.known { h.peers.formUnion(known) }
            let touched = NotificationPrefsService.pendingKeys(account: id)
            h.peers.formUnion(touched.all.compactMap(MuteKeys.ownPeer))
            h.groups.formUnion(touched.all.compactMap(MuteKeys.groupID))
            h.unmuted = touched.unmutes
            holdings[id.uuidString] = h
        }
        let active = AccountManager.shared.activeAccountID?.uuidString
        let out = MuteKeys.handOut(muted: pending.muted, mentions: pending.mentions, holdings: holdings)
        for (a, keys) in out.muted { mutedByAccount[a, default: []].formUnion(keys) }
        for (a, keys) in out.mentions { mentionsByAccount[a, default: []].formUnion(keys) }
        // The island lists the older build's extension file kept, for the
        // account they were read for: what its island said, as its next sync
        // would say again.
        if let older = MutedStore.shared.olderBuildIslandLists(),
           let owner = older.owner ?? active, holdings[owner] != nil {
            let island = older.uins.map { MuteKeys.peer($0) } + older.groupIDs.filter { $0 > 0 }.map(MuteKeys.group)
            mutedByAccount[owner, default: []].formUnion(island)
        }
        for (a, keys) in out.pending {
            if let id = UUID(uuidString: a) { NotificationPrefsService.shared.notePendingMutes(keys, account: id) }
        }
        legacy = nil
        UserDefaults.standard.removeObject(forKey: Self.legacyMutedKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyMentionsKey)
        UserDefaults.standard.set(true, forKey: Self.handedOutKey)
        save()
        syncExtensionMirror()
        // What the active account's island must hear goes now, not on the next
        // launch.
        if let active, out.pending[active]?.isEmpty == false {
            Task { await NotificationPrefsService.shared.refresh() }
        }
    }

    /// A real session whose rosters can be read: not a decoy, an account to
    /// hand to, the phone unlocked (the files are `.complete`), and the data
    /// key open when a PIN seals them.
    private static var mayHandOut: Bool {
        let pin = PanicPINService.shared
        return !pin.isDecoy
            && !AccountManager.shared.accounts.isEmpty
            && UIApplication.shared.isProtectedDataAvailable
            && (!pin.isConfigured || pin.dataKey != nil)
    }

    /// The numbers in a contacts roster file (`ContactService.Snapshot`):
    /// contacts, and requests either way.
    private struct RosterNumbers: Decodable {
        struct Peer: Decodable { let uin: Int }
        struct In: Decodable { let from_uin: Int }
        struct Out: Decodable { let to_uin: Int }
        let contacts: [Peer]
        let pending: [In]?
        let outgoing: [Out]?

        var all: Set<Int> {
            Set(contacts.map(\.uin) + (pending ?? []).map(\.from_uin) + (outgoing ?? []).map(\.to_uin))
        }
    }

    private struct GroupNumber: Decodable { let id: Int }

    /// The chat a thread is in this account. One number is one thread here
    /// (`CrossIslandLogic.fold`): the roster row that holds it says which
    /// island it is on, our own first.
    private func chat(for thread: ThreadID) -> Chat {
        switch thread {
        case .group(let id):
            return .group(id: id)
        case .peer(let uin):
            let rows = ContactService.shared.contacts.filter { $0.uin == uin }
            if rows.contains(where: { $0.host == nil }) { return .peer(uin: uin, host: nil) }
            return .peer(uin: uin, host: rows.first?.host)
        }
    }

    /// `MuteKeys` spelling. Our own island by any of its names is the number
    /// alone.
    private static func key(_ chat: Chat) -> String {
        switch chat {
        case .group(let id):
            return MuteKeys.group(id)
        case .peer(let uin, let host):
            return MuteKeys.peer(uin, host: Multihome.isOwnHost(host) ? nil : host)
        }
    }

    /// How the phone-wide lists named the chat: the number alone.
    private static func legacyKey(_ chat: Chat) -> String {
        switch chat {
        case .group(let id): return MuteKeys.group(id)
        case .peer(let uin, _): return MuteKeys.peer(uin)
        }
    }

    private func has(_ chat: Chat, in map: [String: Set<String>], legacy: Set<String>?) -> Bool {
        guard let s = slot else { return false }
        let k = Self.key(chat)
        if map[s]?.contains(k) == true { return true }
        guard let legacy, s != Self.decoySlot else { return false }
        return legacy.contains(k) || legacy.contains(Self.legacyKey(chat))
    }

    /// Every real account's lists, and the phone-wide ones while they wait for
    /// the hand-out. Never the decoy's slot: on disk it would say that a decoy
    /// session existed and what it muted.
    private func save() {
        let decoy = Self.decoySlot
        let d = UserDefaults.standard
        d.set(mutedByAccount.filter { $0.key != decoy }.mapValues { $0.sorted() }, forKey: Self.mutedKey)
        d.set(mentionsByAccount.filter { $0.key != decoy }.mapValues { $0.sorted() }, forKey: Self.mentionsKey)
        if let legacy {
            d.set(legacy.muted.sorted(), forKey: Self.legacyMutedKey)
            d.set(legacy.mentions.sorted(), forKey: Self.legacyMentionsKey)
        }
    }

    nonisolated private static func loadMap(_ key: String) -> [String: Set<String>] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return raw.mapValues(Set.init).filter { !$0.value.isEmpty }
    }

    nonisolated private static func loadLegacy() -> (muted: Set<String>, mentions: Set<String>)? {
        let d = UserDefaults.standard
        guard !d.bool(forKey: handedOutKey) else { return nil }
        return (
            Set(d.stringArray(forKey: legacyMutedKey) ?? []),
            Set(d.stringArray(forKey: legacyMentionsKey) ?? [])
        )
    }
}
