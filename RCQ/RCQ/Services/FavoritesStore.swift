import Combine
import Foundation

/// Local-only "favourites" list. Pinned contacts and groups float to a
/// dedicated section at the top of the contact list, surviving across
/// launches in UserDefaults. Server doesn't see the list — it's a pure
/// per-device organizational hint, like iOS Mail's flags.
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

    private static let storageKey = "rcq.favorites"

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

    /// Burn-account hook — clears the list along with everything else.
    func wipe() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - persistence

    private func load() {
        let raw = (UserDefaults.standard.array(forKey: Self.storageKey) as? [String]) ?? []
        entries = Set(raw.compactMap(Entry.decode))
    }

    private func save() {
        UserDefaults.standard.set(entries.map(\.key), forKey: Self.storageKey)
    }
}
