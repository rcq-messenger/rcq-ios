import Foundation

/// Local "I removed this UIN from my contacts" set. Sealed-sender
/// means the server can't filter incoming messages by sender, so the
/// recipient enforces the block client-side: sealed envelopes from
/// any UIN in this set are dropped on ingest (no banner, no sound,
/// no thread row) and the NSE skips alert rewrites for them.
///
/// Persisted in UserDefaults so the filter survives app relaunch /
/// background unload. App-group-scoped (`group.app.rcq.shared`) so
/// the NSE shares the same view of the set.
final class RemovedContactsStore {
    static let shared = RemovedContactsStore()

    private static let key = "rcq.removed_contacts"
    private static let appGroup = "group.app.rcq.shared"

    private let defaults: UserDefaults
    private var cache: Set<Int>

    private init() {
        let suite = UserDefaults(suiteName: Self.appGroup) ?? .standard
        self.defaults = suite
        let raw = (suite.array(forKey: Self.key) as? [Int]) ?? []
        self.cache = Set(raw)
    }

    func contains(_ uin: Int) -> Bool {
        cache.contains(uin)
    }

    func add(_ uin: Int) {
        guard cache.insert(uin).inserted else { return }
        defaults.set(Array(cache), forKey: Self.key)
    }

    /// Used when the user re-adds a previously removed contact —
    /// they explicitly want messages from this UIN again.
    func remove(_ uin: Int) {
        guard cache.remove(uin) != nil else { return }
        defaults.set(Array(cache), forKey: Self.key)
    }

    func wipe() {
        cache.removeAll()
        defaults.removeObject(forKey: Self.key)
    }
}

/// Local "I blocked this UIN" set. Like [RemovedContactsStore] but for the
/// explicit Block action — and it is the SOURCE OF TRUTH, because the server's
/// `/contacts/{uin}/block` 404s for non-contacts (so you can't block a stranger
/// group member there) and group messages are sealed-sender (the server can't
/// filter). Drives ingest filtering + the Blocked list. App-group-scoped so the
/// NSE can suppress a blocked sender's push too. Mirrors Android's local
/// blocked set.
final class BlockedContactsStore {
    static let shared = BlockedContactsStore()

    private static let key = "rcq.blocked_contacts"
    private static let appGroup = "group.app.rcq.shared"

    private let defaults: UserDefaults
    private var cache: Set<Int>

    private init() {
        let suite = UserDefaults(suiteName: Self.appGroup) ?? .standard
        self.defaults = suite
        self.cache = Set((suite.array(forKey: Self.key) as? [Int]) ?? [])
    }

    func contains(_ uin: Int) -> Bool { cache.contains(uin) }
    func all() -> [Int] { Array(cache) }

    func set(_ uin: Int, blocked: Bool) {
        if blocked {
            guard cache.insert(uin).inserted else { return }
        } else {
            guard cache.remove(uin) != nil else { return }
        }
        defaults.set(Array(cache), forKey: Self.key)
    }

    func wipe() {
        cache.removeAll()
        defaults.removeObject(forKey: Self.key)
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
    private struct Lists: Codable { var uins: [Int]; var groupIDs: [Int]; var mentionGroupIDs: [Int]? }
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
        )
    }

    func isMuted(_ uin: Int) -> Bool { read().uins.contains(uin) }
    func isGroupMuted(_ groupID: Int) -> Bool { read().groupIDs.contains(groupID) }
    /// Group set to "mentions only" — the NSE drops a group push that
    /// doesn't mention the user (and, for an undecryptable sender-keys
    /// `gmsg`, drops it outright since a mention can't be verified
    /// out-of-process; the in-app path catches mentions when online).
    func isGroupMentionsOnly(_ groupID: Int) -> Bool { (read().mentionGroupIDs ?? []).contains(groupID) }

    /// Mirror the authoritative muted lists from NotificationPrefsService.
    /// Preserves the client-only mentions-only set (not server-backed).
    func setMuted(uins: [Int], groupIDs: [Int]) {
        let mentions = read().mentionGroupIDs ?? []
        defaults.set(uins, forKey: Self.uinKey)
        defaults.set(groupIDs, forKey: Self.groupKey)
        if let data = try? JSONEncoder().encode(Lists(uins: uins, groupIDs: groupIDs, mentionGroupIDs: mentions)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Mirror the mentions-only group set (client-only) for the NSE.
    func setMentionsOnlyGroups(_ groupIDs: [Int]) {
        let cur = read()
        defaults.set(groupIDs, forKey: Self.mentionGroupKey)
        if let data = try? JSONEncoder().encode(Lists(uins: cur.uins, groupIDs: cur.groupIDs, mentionGroupIDs: groupIDs)) {
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
