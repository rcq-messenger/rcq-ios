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
