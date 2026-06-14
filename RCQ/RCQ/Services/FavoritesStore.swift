import Combine
import Foundation

/// Local-only "favourites" list. Pinned contacts and groups float to a
/// dedicated section at the top of the contact list, surviving across
/// launches in UserDefaults. Server doesn't see the list — it's a pure
/// per-device organizational hint, like iOS Mail's flags.
///
/// ## Per-account scoping
///
/// The stored set is keyed by the **active account's id**
/// (`rcq.favorites.<accountUUID>`) so two accounts on one device never
/// bleed each other's stars. `rebindActiveAccount()` reloads the set
/// after an account switch (called from `rebootForActiveAccount`). The
/// pre-per-account global `rcq.favorites` slot is migrated ONCE into the
/// first account that loads with a real active id, then deleted, so it
/// can't leak into every account.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    /// One key per kind/id pair so Set membership stays cheap. Encoded
    /// as `peer:UIN` or `group:GROUPID` for JSON-friendly persistence.
    enum Entry: Hashable, Codable {
        case peer(uin: Int)
        case group(id: Int)

        var key: String {
            switch self {
            case .peer(let uin): return "peer:\(uin)"
            case .group(let id): return "group:\(id)"
            }
        }

        static func decode(_ key: String) -> Entry? {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let n = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "peer": return .peer(uin: n)
            case "group": return .group(id: n)
            default: return nil
            }
        }
    }

    @Published private(set) var entries: Set<Entry> = []

    /// Pre-per-account global slot. Migrated once, then removed.
    private static let legacyKey = "rcq.favorites"

    /// UserDefaults key for the CURRENTLY active account. Falls back to the
    /// legacy global key only when no account is active yet (fresh launch
    /// before onboarding), which is harmless — there are no favorites then.
    private var storageKey: String {
        guard let id = AppGroup.readActiveAccountID() else { return Self.legacyKey }
        return "rcq.favorites.\(id.uuidString)"
    }

    private init() { load() }

    func contains(peer uin: Int) -> Bool { entries.contains(.peer(uin: uin)) }
    func contains(group id: Int) -> Bool { entries.contains(.group(id: id)) }

    func toggle(peer uin: Int) {
        let key: Entry = .peer(uin: uin)
        if entries.contains(key) { entries.remove(key) } else { entries.insert(key) }
        save()
    }

    func toggle(group id: Int) {
        let key: Entry = .group(id: id)
        if entries.contains(key) { entries.remove(key) } else { entries.insert(key) }
        save()
    }

    /// One-way removal (no toggle-on if absent). Used by `ArchiveStore`
    /// to enforce mutual exclusion when a row gets archived.
    func remove(peer uin: Int) {
        if entries.remove(.peer(uin: uin)) != nil { save() }
    }

    func remove(group id: Int) {
        if entries.remove(.group(id: id)) != nil { save() }
    }

    /// Reload the set for the now-active account. Call after an account
    /// switch so favorites don't carry over from the previous account.
    func rebindActiveAccount() { load() }

    /// Burn-account hook — clears the active account's list.
    func wipe() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - persistence

    private func load() {
        let key = storageKey
        // One-time migration: adopt the legacy GLOBAL favorites into the
        // first account that loads with a real active id, then clear the
        // global slot so it can't bleed into every other account.
        if key != Self.legacyKey,
           UserDefaults.standard.object(forKey: key) == nil,
           let legacy = UserDefaults.standard.array(forKey: Self.legacyKey) as? [String] {
            UserDefaults.standard.set(legacy, forKey: key)
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        }
        let raw = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
        entries = Set(raw.compactMap(Entry.decode))
    }

    private func save() {
        UserDefaults.standard.set(entries.map(\.key), forKey: storageKey)
    }
}
