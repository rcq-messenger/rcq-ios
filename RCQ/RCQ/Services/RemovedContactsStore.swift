import Foundation

/// Local "I removed this UIN from my contacts" set. Sealed-sender
/// means the server can't filter incoming messages by sender, so the
/// recipient enforces the block client-side: sealed envelopes from
/// any UIN in this set are dropped on ingest (no banner, no sound,
/// no thread row) and the NSE skips alert rewrites for them.
///
/// ⚠ Numbers of OUR OWN island only, written and read (report 1064, the
/// iOS twin of Android's #1055). The number names nobody on another
/// island: removing 134@is2 used to land here as a bare 134 and drop
/// everything from every 134 for good, with nothing to take it off again.
/// A removed contact from another island goes through the cross-island
/// gate like any stranger (their messages wait in Requests).
///
/// ⚠ Per account, like `BlockedContactsStore`. It used to be one device-wide
/// set: a removal in account A dropped the pushes of a different person who
/// holds that number in account B, and every account switch wiped the set,
/// so switching away and back brought every removed contact's messages back.
///
/// Persisted in UserDefaults so the filter survives app relaunch /
/// background unload. App-group-scoped (`group.app.rcq.shared`) so
/// the NSE shares the same view of the set (`stored(accountID:)`).
final class RemovedContactsStore {
    static let shared = RemovedContactsStore()

    /// The device-wide set older builds kept. Read until migrated.
    private static let legacyKey = "rcq.removed_contacts"
    private static let prefix = "rcq.removed_contacts.v2."
    private static let appGroup = "group.app.rcq.shared"

    private let defaults: UserDefaults
    private var key: String
    private var cache: Set<Int>

    private init() {
        let suite = UserDefaults(suiteName: Self.appGroup) ?? .standard
        self.defaults = suite
        // The extension only reads (`stored` below), like BlockedContactsStore.
        if !Bundle.main.bundlePath.hasSuffix(".appex") { Self.migrateLegacyIfNeeded() }
        key = Self.prefix + (AppGroup.readActiveAccountID()?.uuidString ?? "none")
        cache = Self.load(suite, key)
    }

    /// Re-point at the active account on every account switch and on entering
    /// or leaving a decoy session, like `BlockedContactsStore.bind`.
    func bind(accountID: UUID?) {
        Self.migrateLegacyIfNeeded()
        key = Self.prefix + (accountID?.uuidString ?? "none")
        cache = Self.load(defaults, key)
    }

    func contains(_ uin: Int) -> Bool {
        cache.contains(uin)
    }

    func add(_ uin: Int) {
        guard cache.insert(uin).inserted else { return }
        defaults.set(Array(cache), forKey: key)
    }

    /// Used when the user re-adds a previously removed contact —
    /// they explicitly want messages from this UIN again.
    func remove(_ uin: Int) {
        guard cache.remove(uin) != nil else { return }
        defaults.set(Array(cache), forKey: key)
    }

    /// The bound account's set only (burn, UIN move).
    func wipe() {
        cache.removeAll()
        defaults.removeObject(forKey: key)
    }

    /// Another account's set, for an account erased from this phone.
    static func wipeStored(accountID: UUID) {
        (UserDefaults(suiteName: appGroup) ?? .standard).removeObject(forKey: prefix + accountID.uuidString)
    }

    private static func load(_ d: UserDefaults, _ key: String) -> Set<Int> {
        Set((d.array(forKey: key) as? [Int]) ?? [])
    }

    /// Older builds wiped the device-wide set on every switch, so it only ever
    /// held the ACTIVE account's removals: it moves there and nowhere else.
    /// Waits while no account is active, so a removal cannot land under none.
    static func migrateLegacyIfNeeded() {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        guard let legacy = d.array(forKey: legacyKey) as? [Int] else { return }
        if legacy.isEmpty { d.removeObject(forKey: legacyKey); return }
        guard let active = AppGroup.readActiveAccountID() else { return }
        let k = prefix + active.uuidString
        d.set(Array(load(d, k).union(legacy)), forKey: k)
        d.removeObject(forKey: legacyKey)
    }

    // MARK: read-only, for the notification extension

    /// The account's removals, read from disk (another process wrote them, and
    /// a reused extension process must not answer from an old cache). An older
    /// build's set counts only for the account that was active when it was
    /// written, until the app has migrated it.
    static func stored(accountID: UUID?) -> Set<Int> {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        var out = load(d, prefix + (accountID?.uuidString ?? "none"))
        if let accountID, accountID == AppGroup.readActiveAccountID() {
            out.formUnion(load(d, legacyKey))
        }
        return out
    }
}

/// Local "I blocked this number" set: numbers on THIS ACCOUNT'S OWN island.
/// Like [RemovedContactsStore] but for the explicit Block action, and it is
/// the SOURCE OF TRUTH, because the server's `/contacts/{uin}/block` 404s for
/// non-contacts (so you can't block a stranger group member there) and group
/// messages are sealed-sender (the server can't filter). Drives ingest
/// filtering + the Blocked list. Somebody on another island is blocked by
/// address in `CrossIslandRequestsStore`, never here (reports 1064, 1065).
///
/// ⚠ Per account. It used to be one device-wide set of bare numbers, so a
/// block in one account blocked that number in every other account on the
/// phone, and a block of 134@is2 silenced our own island's 134 too.
///
/// ⚠ `everyIsland` is what that old set held, copied into every account by
/// `migrateLegacyIfNeeded`. Those blocks keep meaning "this number on every
/// island" (`BlockRule`), so updating the app unblocks nobody. Nothing new is
/// ever written there; unblocking the number removes it.
///
/// App-group-scoped so the notification extension can keep a blocked sender
/// off the lock screen (the static readers at the bottom).
final class BlockedContactsStore {
    static let shared = BlockedContactsStore()

    /// The device-wide set older builds kept. Read until migrated.
    private static let legacyKey = "rcq.blocked_contacts"
    private static let ownPrefix = "rcq.blocked_contacts.own.v2."
    private static let everyIslandPrefix = "rcq.blocked_contacts.any.v2."
    /// The island's own flags (see `storeServerBlocked`), kept apart because
    /// every roster fetch rewrites them whole.
    private static let serverPrefix = "rcq.blocked_contacts.server.v1."
    private static let appGroup = "group.app.rcq.shared"

    private let defaults: UserDefaults
    private var ownKey: String
    private var everyIslandKey: String
    private var serverKey: String
    private var own: Set<Int>
    private var everyIsland: Set<Int>

    private init() {
        let suite = UserDefaults(suiteName: Self.appGroup) ?? .standard
        self.defaults = suite
        // The extension only reads (the statics below): a migration there could
        // land under an app process that already holds the old set in memory.
        if !Self.inExtension { Self.migrateLegacyIfNeeded() }
        let id = AppGroup.readActiveAccountID()
        ownKey = Self.ownPrefix + (id?.uuidString ?? "none")
        everyIslandKey = Self.everyIslandPrefix + (id?.uuidString ?? "none")
        serverKey = Self.serverPrefix + (id?.uuidString ?? "none")
        own = Self.load(suite, ownKey)
        everyIsland = Self.load(suite, everyIslandKey).union(Self.load(suite, Self.legacyKey))
    }

    /// Re-point at the active account on every account switch and on entering
    /// or leaving a decoy session, like `CrossIslandRequestsStore.bind`.
    func bind(accountID: UUID?) {
        Self.migrateLegacyIfNeeded()
        ownKey = Self.ownPrefix + (accountID?.uuidString ?? "none")
        everyIslandKey = Self.everyIslandPrefix + (accountID?.uuidString ?? "none")
        serverKey = Self.serverPrefix + (accountID?.uuidString ?? "none")
        own = Self.load(defaults, ownKey)
        everyIsland = Self.load(defaults, everyIslandKey).union(Self.load(defaults, Self.legacyKey))
    }

    /// Is this number on our own island blocked (by a block made here, or by an
    /// older build's any-island one)?
    func contains(_ uin: Int) -> Bool { own.contains(uin) || everyIsland.contains(uin) }
    /// An older build's block of this number, which covers every island.
    func blocksOnEveryIsland(_ uin: Int) -> Bool { everyIsland.contains(uin) }
    func all() -> [Int] { Array(own.union(everyIsland)) }

    /// Unblocking also lifts an older build's any-island block of the number:
    /// that was the only record those builds kept, and their Unblock lifted it.
    func set(_ uin: Int, blocked: Bool) {
        Self.migrateLegacyIfNeeded()
        if blocked {
            guard own.insert(uin).inserted else { return }
            defaults.set(Array(own), forKey: ownKey)
        } else {
            let a = own.remove(uin) != nil
            let b = everyIsland.remove(uin) != nil
            if a { defaults.set(Array(own), forKey: ownKey) }
            if b { defaults.set(Array(everyIsland), forKey: everyIslandKey) }
        }
    }

    /// Only an older build's any-island block of `uin` (the person unblocked
    /// was on another island; our own island's block, if any, stays).
    func liftEveryIslandBlock(_ uin: Int) {
        Self.migrateLegacyIfNeeded()
        guard everyIsland.remove(uin) != nil else { return }
        defaults.set(Array(everyIsland), forKey: everyIslandKey)
    }

    func wipe() {
        own.removeAll()
        everyIsland.removeAll()
        defaults.removeObject(forKey: ownKey)
        defaults.removeObject(forKey: everyIslandKey)
        defaults.removeObject(forKey: serverKey)
    }

    /// Own-island numbers whose roster row the island served with `blocked`
    /// (a block made on web or another device: web sends no `ciack`, so this
    /// device never files it here), i.e. `ContactService.serverBlocked`. The
    /// app drops these senders; mirrored so the extension keeps them off the
    /// lock screen too. Written only from an answer of the island.
    static func storeServerBlocked(_ uins: Set<Int>, accountID: UUID?) {
        guard let accountID else { return }
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        d.set(Array(uins), forKey: serverPrefix + accountID.uuidString)
    }

    /// The mirror above, for an identity that is gone (burn, an erased account).
    static func wipeServerBlocked(accountID: UUID?) {
        guard let accountID else { return }
        (UserDefaults(suiteName: appGroup) ?? .standard).removeObject(forKey: serverPrefix + accountID.uuidString)
    }

    private static var inExtension: Bool { Bundle.main.bundlePath.hasSuffix(".appex") }

    private static func load(_ d: UserDefaults, _ key: String) -> Set<Int> {
        Set((d.array(forKey: key) as? [Int]) ?? [])
    }

    /// Copy the device-wide set older builds kept into EVERY account's
    /// any-island set, then drop it. Every account, not a guess at whose: the
    /// set never said, and a wrong guess would unblock somebody. Waits while
    /// no account is listed yet, so a block cannot land under no account.
    static func migrateLegacyIfNeeded() {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        guard let legacy = d.array(forKey: legacyKey) as? [Int] else { return }
        var ids = AppGroup.readAccountIDs()
        if let active = AppGroup.readActiveAccountID(), !ids.contains(active) { ids.append(active) }
        if legacy.isEmpty { d.removeObject(forKey: legacyKey); return }
        guard !ids.isEmpty else { return }
        for id in ids {
            let k = everyIslandPrefix + id.uuidString
            d.set(Array(load(d, k).union(legacy)), forKey: k)
        }
        d.removeObject(forKey: legacyKey)
    }

    // MARK: read-only, for the notification extension

    /// The account's own-island blocks, read from disk (another process wrote
    /// them): made here, flagged by the island, and an older build's set
    /// until the app has migrated it.
    static func storedOwnIsland(accountID: UUID?) -> Set<Int> {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        let id = accountID?.uuidString ?? "none"
        return load(d, ownPrefix + id)
            .union(load(d, serverPrefix + id))
            .union(storedEveryIsland(accountID: accountID))
    }

    /// The account's any-island blocks (an older build's), read from disk.
    static func storedEveryIsland(accountID: UUID?) -> Set<Int> {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        let id = accountID?.uuidString ?? "none"
        return load(d, everyIslandPrefix + id).union(load(d, legacyKey))
    }
}

/// App-group mirror of every account's mute lists, so the NSE + foreground
/// presentation can suppress a muted sender/group locally (sealed sender hides
/// 1:1 senders from the server). Reads hit the file directly so a reused NSE
/// process stays current.
///
/// ⚠ PER ACCOUNT, written by `SoundService` (the only writer). It used to hold
/// the ACTIVE account's island lists and nothing else, and an account switch
/// emptied it, so a push for any other account on the phone was judged by
/// another account's mutes or by none: two people can hold the same number on
/// two islands, and the same group id is another group on another island.
/// The extension reads the lists of the account a push is addressed to
/// (`mutes(for:)`).
final class MutedStore {
    static let shared = MutedStore()

    /// One account's mutes, in the form the extension reads them.
    struct Lists: Codable, Equatable {
        /// Numbers of the account's own island set to silent (the island's
        /// `muted_uins`).
        var uins: [Int] = []
        /// Groups set to silent: the island's `muted_group_ids`, and a room on
        /// another island by this account's local alias (negative).
        var groupIDs: [Int] = []
        /// People on other islands set to silent, "uin@host" in
        /// `AppGroup.canonicalHost`'s spelling. The number alone is somebody
        /// else on our island.
        var addresses: [String] = []
        /// Groups set to "mentions only": quiet for ordinary messages, still
        /// surfaced when @mentioned. Client-only (the island cannot read
        /// sealed content to know about a mention).
        var mentionGroupIDs: [Int] = []

        var isEmpty: Bool { uins.isEmpty && groupIDs.isEmpty && addresses.isEmpty && mentionGroupIDs.isEmpty }
    }

    /// What one push is judged by: the lists of the account(s) it may be for.
    struct Mutes {
        var uins: Set<Int> = []
        var groupIDs: Set<Int> = []
        var addresses: Set<String> = []
        var mentionGroupIDs: Set<Int> = []
        /// The file an older build wrote: one list for the whole phone, by
        /// bare number, which silenced that number on every island. Read the
        /// way it was written until the app has handed it out per account.
        var olderBuild = false

        /// A number of the account's own island.
        func silences(uin: Int) -> Bool { uins.contains(uin) }

        /// Somebody on another island, by their address.
        func silences(uin: Int, host: String) -> Bool {
            if olderBuild, uins.contains(uin) { return true }
            guard let h = AppGroup.canonicalHost(host) else { return false }
            return addresses.contains("\(uin)@\(h)")
        }

        func silencesGroup(_ id: Int) -> Bool { groupIDs.contains(id) }
        func mentionsOnly(_ groupID: Int) -> Bool { mentionGroupIDs.contains(groupID) }
    }

    /// What the file holds.
    enum Stored {
        /// Account id (`uuidString`) -> that account's lists.
        case perAccount([String: Lists])
        /// An older build's file: one account's island lists (`owner`, absent
        /// in the oldest files) beside the phone-wide "mentions only" set, in
        /// force for every push.
        case olderBuild(Lists, owner: String?)
    }

    private struct File: Codable { var accounts: [String: Lists] }
    private struct OlderFile: Decodable {
        var uins: [Int]
        var groupIDs: [Int]
        var mentionGroupIDs: [Int]?
        var account: String?
    }

    // Keys of the App Group UserDefaults copy the oldest builds kept, before
    // the file existed. Read only while there is no file; dropped once the
    // per-account file is written.
    private static let uinKey = "rcq.muted_uins"
    private static let groupKey = "rcq.muted_group_ids"
    private static let mentionGroupKey = "rcq.mention_only_group_ids"
    private static let appGroup = "group.app.rcq.shared"

    private let defaults: UserDefaults
    private init() { defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard }

    // A FLAT FILE is the source of truth. App Group UserDefaults is read by the
    // NSE in a separate process, where cfprefsd "detaches" routinely and serves
    // a STALE snapshot — so a freshly-muted group/user still pushed (the exact
    // bug). The file dodges that layer (same fix as AppGroup.languageFileURL).
    private var fileURL: URL { AppGroup.containerURL.appendingPathComponent("muted.json") }

    /// The file as written, either form. Nil for bytes that are neither.
    static func decode(_ data: Data) -> Stored? {
        if let file = try? JSONDecoder().decode(File.self, from: data) { return .perAccount(file.accounts) }
        if let old = try? JSONDecoder().decode(OlderFile.self, from: data) {
            return .olderBuild(
                Lists(uins: old.uins, groupIDs: old.groupIDs, mentionGroupIDs: old.mentionGroupIDs ?? []),
                owner: old.account
            )
        }
        return nil
    }

    /// The lists for a push to any of `accounts`: several when one number is
    /// held by more than one account here (one key restored onto two islands),
    /// and the push cannot say which of them it is for. Those are all one
    /// person's accounts, and a mute any of them set is kept rather than a
    /// muted chat ringing. An older build's file judges every push, as it did.
    static func mutes(in stored: Stored?, for accounts: [String]) -> Mutes {
        switch stored {
        case .perAccount(let map)?:
            var out = Mutes()
            for id in accounts {
                guard let l = map[id] else { continue }
                out.uins.formUnion(l.uins)
                out.groupIDs.formUnion(l.groupIDs)
                out.addresses.formUnion(l.addresses)
                out.mentionGroupIDs.formUnion(l.mentionGroupIDs)
            }
            return out
        case .olderBuild(let l, _)?:
            return Mutes(
                uins: Set(l.uins), groupIDs: Set(l.groupIDs),
                mentionGroupIDs: Set(l.mentionGroupIDs), olderBuild: true
            )
        case nil:
            return Mutes()
        }
    }

    private func read() -> Stored? {
        if let data = try? Data(contentsOf: fileURL) { return Self.decode(data) }
        // Fallback for installs that muted before the file existed.
        guard defaults.object(forKey: Self.uinKey) != nil || defaults.object(forKey: Self.groupKey) != nil
                || defaults.object(forKey: Self.mentionGroupKey) != nil else { return nil }
        return .olderBuild(Lists(
            uins: (defaults.array(forKey: Self.uinKey) as? [Int]) ?? [],
            groupIDs: (defaults.array(forKey: Self.groupKey) as? [Int]) ?? [],
            mentionGroupIDs: (defaults.array(forKey: Self.mentionGroupKey) as? [Int]) ?? []
        ), owner: nil)
    }

    /// For the extension: the mutes of the account(s) a push is for (see the
    /// static `mutes`). An empty list reads nothing and silences nothing.
    func mutes(for accounts: [UUID]) -> Mutes {
        Self.mutes(in: read(), for: accounts.map(\.uuidString))
    }

    /// The island lists an older build's file kept, and whose they were (nil:
    /// a file too old to say, written for the account active then). For the
    /// app's one-time hand-out (`SoundService.migrateLegacyIfNeeded`).
    func olderBuildIslandLists() -> (owner: String?, uins: [Int], groupIDs: [Int])? {
        guard case .olderBuild(let l, let owner)? = read() else { return nil }
        return (owner, l.uins, l.groupIDs)
    }

    /// The file for `byAccount`, accounts with nothing muted left out. Nil
    /// when nobody has anything muted.
    static func encode(_ byAccount: [String: Lists]) -> Data? {
        let nonEmpty = byAccount.filter { !$0.value.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(File(accounts: nonEmpty))
    }

    /// Every account's lists at once, from `SoundService`. An unchanged file
    /// is left alone: the extension reads it on every push.
    func setAll(_ byAccount: [String: Lists]) {
        defaults.removeObject(forKey: Self.uinKey)
        defaults.removeObject(forKey: Self.groupKey)
        defaults.removeObject(forKey: Self.mentionGroupKey)
        guard let data = Self.encode(byAccount) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        if (try? Data(contentsOf: fileURL)) == data { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// How the mute lists name a chat, and the rules over those names that need no
/// singleton (`Tools/MuteScopeCheck` drives them).
///
/// "peer:<uin>" is a number of the account's own island, "peer:<uin>@<host>"
/// somebody on another island (the host in `AppGroup.canonicalHost`'s
/// spelling, like `rcq.ci-blocked.v1`), "group:<id>" a group: one of the
/// island's own (positive id), or a room on another island by this account's
/// local alias (negative, `VisitedIslandsStore`). A number alone does not name
/// a person: islands number on their own, and #134 is somebody else on each.
enum MuteKeys {
    static func peer(_ uin: Int, host: String? = nil) -> String {
        guard let host, let h = AppGroup.canonicalHost(host) else { return "peer:\(uin)" }
        return "peer:\(uin)@\(h)"
    }

    static func group(_ id: Int) -> String { "group:\(id)" }

    /// The number, when the key is a peer of the account's own island.
    static func ownPeer(_ key: String) -> Int? {
        key.hasPrefix("peer:") ? Int(key.dropFirst("peer:".count)) : nil
    }

    /// "uin@host", when the key is somebody on another island.
    static func address(_ key: String) -> String? {
        guard key.hasPrefix("peer:"), key.contains("@") else { return nil }
        return String(key.dropFirst("peer:".count))
    }

    static func groupID(_ key: String) -> Int? {
        key.hasPrefix("group:") ? Int(key.dropFirst("group:".count)) : nil
    }

    /// Kept by the account's island as well (`muted_uins`, `muted_group_ids`):
    /// its own numbers and its own groups. Anybody on another island and any
    /// room there is muted on this phone alone, because the island's lists
    /// name ITS numbers and groups, and the same ones there are others.
    static func isIslandKept(_ key: String) -> Bool {
        if ownPeer(key) != nil { return true }
        if let id = groupID(key) { return id > 0 }
        return false
    }

    /// The extension's copy of one account's lists.
    static func lists(muted: Set<String>, mentions: Set<String>) -> MutedStore.Lists {
        MutedStore.Lists(
            uins: muted.compactMap(ownPeer).sorted(),
            groupIDs: muted.compactMap(groupID).sorted(),
            addresses: muted.compactMap(address).sorted(),
            mentionGroupIDs: mentions.compactMap(groupID).sorted()
        )
    }

    /// An account's muted set once its island has answered: what the island
    /// keeps is what the island says (`uins`/`groups` already carry the
    /// changes made here it has not confirmed yet), and everything it does not
    /// keep stays as it was. A negative group id on the island's list was put
    /// there by an older build and names nothing there.
    static func adopt(muted: Set<String>, islandUINs: Set<Int>, islandGroups: Set<Int>) -> Set<String> {
        var out = muted.filter { !isIslandKept($0) }
        out.formUnion(islandUINs.map { peer($0) })
        out.formUnion(islandGroups.filter { $0 > 0 }.map(group))
        return out
    }

    /// What an account on this phone is shown to hold, for the hand-out of the
    /// lists older builds kept for the whole phone.
    struct Holdings {
        /// Numbers of its own island it has a contact, a request or a pending
        /// mute change with, or wrote to.
        var peers: Set<Int> = []
        /// People on other islands it holds, "uin@host".
        var addresses: Set<String> = []
        /// Groups it is in, and its aliases of rooms on other islands.
        var groups: Set<Int> = []
        /// Chats this account unmuted itself since mutes were per account
        /// (an unmute its island has not confirmed): its own last word.
        var unmuted: Set<String> = []
        /// False when nothing on disk says what the account holds (no roster
        /// was ever saved for it).
        var known = true
    }

    struct Handout: Equatable {
        var muted: [String: Set<String>] = [:]
        var mentions: [String: Set<String>] = [:]
        /// Mutes each account's island must hear (see `handOut`).
        var pending: [String: Set<String>] = [:]
    }

    /// Hand the phone-wide lists to the accounts (by `uuidString`) that hold
    /// those chats, losing none.
    ///
    /// - A peer goes to every account holding the number on its own island,
    ///   and as "uin@host" to every account holding somebody of that number on
    ///   another island (older builds named both by the number alone). A group
    ///   goes to every account in it.
    /// - Also to every account nothing on disk speaks for: it may hold it too.
    /// - Held by nobody that can be shown: to every account, which is where
    ///   the list was in force.
    /// - Never as a mute to an account whose own last word on that chat was
    ///   an unmute.
    ///
    /// `pending`: the island-kept mutes each holder's island must have, sent
    /// on its next sync if it lacks them (a failed write of an older build
    /// would otherwise be undone by the island's answer). Never to an island
    /// not shown to hold the chat, where the number is somebody else. A mute
    /// nobody is shown to hold (a burned or removed account's, which older
    /// builds left on the list) stays on the phone only: no island is told
    /// about it, and the first sync's `adopt` drops it where that island
    /// does not keep it.
    static func handOut(
        muted: Set<String>, mentions: Set<String>,
        holdings: [String: Holdings]
    ) -> Handout {
        let accounts = holdings.keys.sorted()
        // (account, key in that account's spelling, shown to hold it)
        func targets(_ key: String) -> [(String, String, Bool)] {
            var hits: [(String, String, Bool)] = []
            if let uin = ownPeer(key) {
                for a in accounts {
                    guard let h = holdings[a] else { continue }
                    if h.peers.contains(uin) { hits.append((a, key, true)) }
                    for addr in h.addresses.sorted() where addr.hasPrefix("\(uin)@") {
                        hits.append((a, "peer:\(addr)", true))
                    }
                }
            } else if let id = groupID(key) {
                for a in accounts where holdings[a]?.groups.contains(id) == true { hits.append((a, key, true)) }
            }
            guard !hits.isEmpty else { return accounts.map { ($0, key, false) } }
            let holders = Set(hits.map(\.0))
            let unknown = accounts.filter { !holders.contains($0) && holdings[$0]?.known == false }
            return hits + unknown.map { ($0, key, false) }
        }
        var out = Handout()
        for key in muted.sorted() {
            for (a, k, holds) in targets(key) where holdings[a]?.unmuted.contains(key) != true && holdings[a]?.unmuted.contains(k) != true {
                out.muted[a, default: []].insert(k)
                if isIslandKept(k), holds {
                    out.pending[a, default: []].insert(k)
                }
            }
        }
        for key in mentions.sorted() {
            // An unmute here may be the switch from "None" to "mentions
            // only" itself, so it does not keep this one away.
            for (a, k, _) in targets(key) {
                out.mentions[a, default: []].insert(k)
            }
        }
        return out
    }
}
