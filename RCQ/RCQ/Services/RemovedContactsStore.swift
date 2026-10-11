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

/// App-group mirror of the mute lists so the NSE + foreground presentation can
/// suppress a muted sender/group locally (sealed sender hides 1:1 senders from
/// the server). Reads hit UserDefaults directly so a reused NSE process stays current.
final class MutedStore {
    static let shared = MutedStore()

    private static let uinKey = "rcq.muted_uins"
    private static let groupKey = "rcq.muted_group_ids"
    private static let appGroup = "group.app.rcq.shared"

    private let defaults: UserDefaults
    private init() { defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard }

    // A FLAT FILE is the source of truth. App Group UserDefaults is read by the
    // NSE in a separate process, where cfprefsd "detaches" routinely and serves
    // a STALE snapshot — so a freshly-muted group/user still pushed (the exact
    // bug). The file dodges that layer (same fix as AppGroup.languageFileURL).
    // UserDefaults is kept written for back-compat with in-flight installs.
    // `mentionGroupIDs` is the "mentions only" set: groups the user wants
    // QUIET for ordinary messages but still surfaced when @mentioned. It is
    // OPTIONAL in the Codable so a muted.json written by an older build (no
    // such field) still decodes. None-mode groups live in `groupIDs` (the
    // server-backed mute), mentions-only groups live here (client-only —
    // the server can't read sealed content to know about a mention).
    //
    // `account` names the account whose island the two server-backed lists
    // came from (absent in a file written by an older build). The file holds
    // one account's lists, the active one's, and an account switch empties it;
    // the owner is what lets a write made for one account refuse to start
    // from another account's lists in the moment before that happens.
    private struct Lists: Codable { var uins: [Int]; var groupIDs: [Int]; var mentionGroupIDs: [Int]?; var account: String? }
    private static let mentionGroupKey = "rcq.mention_only_group_ids"
    private var fileURL: URL { AppGroup.containerURL.appendingPathComponent("muted.json") }

    private func read() -> Lists {
        if let data = try? Data(contentsOf: fileURL),
           let l = try? JSONDecoder().decode(Lists.self, from: data) {
            return l
        }
        // Fallback for installs that muted before the file existed.
        return Lists(
            uins: (defaults.array(forKey: Self.uinKey) as? [Int]) ?? [],
            groupIDs: (defaults.array(forKey: Self.groupKey) as? [Int]) ?? [],
            mentionGroupIDs: (defaults.array(forKey: Self.mentionGroupKey) as? [Int]) ?? [],
            account: nil
        )
    }

    func isMuted(_ uin: Int) -> Bool { read().uins.contains(uin) }
    /// The server-backed lists as last mirrored for `account`, for a change
    /// made while its island cannot be reached (`NotificationPrefsService`).
    /// Nil when they are another account's. A file from an older build names
    /// nobody and is taken as the active account's, whose it was.
    func lists(for account: UUID) -> (uins: [Int], groupIDs: [Int])? {
        let l = read()
        if let owner = l.account, owner != account.uuidString { return nil }
        return (l.uins, l.groupIDs)
    }
    func isGroupMuted(_ groupID: Int) -> Bool { read().groupIDs.contains(groupID) }
    /// Group set to "mentions only" — the NSE drops a group push that
    /// doesn't mention the user (and, for an undecryptable sender-keys
    /// `gmsg`, drops it outright since a mention can't be verified
    /// out-of-process; the in-app path catches mentions when online).
    func isGroupMentionsOnly(_ groupID: Int) -> Bool { (read().mentionGroupIDs ?? []).contains(groupID) }

    /// Mirror the authoritative muted lists from NotificationPrefsService,
    /// as `account`'s. Preserves the client-only mentions-only set (not
    /// server-backed).
    func setMuted(uins: [Int], groupIDs: [Int], account: UUID) {
        let mentions = read().mentionGroupIDs ?? []
        defaults.set(uins, forKey: Self.uinKey)
        defaults.set(groupIDs, forKey: Self.groupKey)
        let lists = Lists(uins: uins, groupIDs: groupIDs, mentionGroupIDs: mentions, account: account.uuidString)
        if let data = try? JSONEncoder().encode(lists) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Mirror the mentions-only group set (client-only) for the NSE.
    func setMentionsOnlyGroups(_ groupIDs: [Int]) {
        var cur = read()
        defaults.set(groupIDs, forKey: Self.mentionGroupKey)
        cur.mentionGroupIDs = groupIDs
        if let data = try? JSONEncoder().encode(cur) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func wipe() {
        defaults.removeObject(forKey: Self.uinKey)
        defaults.removeObject(forKey: Self.groupKey)
        defaults.removeObject(forKey: Self.mentionGroupKey)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
