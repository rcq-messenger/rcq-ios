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

    func isMuted(_ uin: Int) -> Bool {
        ((defaults.array(forKey: Self.uinKey) as? [Int]) ?? []).contains(uin)
    }
    func isGroupMuted(_ groupID: Int) -> Bool {
        ((defaults.array(forKey: Self.groupKey) as? [Int]) ?? []).contains(groupID)
    }

    /// Mirror the authoritative lists from NotificationPrefsService.
    func setMuted(uins: [Int], groupIDs: [Int]) {
        defaults.set(uins, forKey: Self.uinKey)
        defaults.set(groupIDs, forKey: Self.groupKey)
    }

    func wipe() {
        defaults.removeObject(forKey: Self.uinKey)
        defaults.removeObject(forKey: Self.groupKey)
    }
}
