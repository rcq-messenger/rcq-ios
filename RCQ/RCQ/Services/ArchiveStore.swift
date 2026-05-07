import Combine
import Foundation

/// Local-only "archived" list. Hides contacts and groups from the
/// regular sections of the contact list — they collapse into a
/// dedicated "Archive" disclosure at the bottom. To unarchive, the
/// user opens that section, long-presses the row, and picks
/// "Unarchive" from the context menu.
///
/// Pure per-device organizational hint — server is never told. The
/// underlying contact / group still exists, still receives messages
/// (they just don't appear in the main list while archived). Mirrors
/// `FavoritesStore`'s shape so the two coexist cleanly: a row can be
/// favorited *or* archived (but not both — archiving auto-removes
/// from favorites; un-archiving doesn't auto-restore).
@MainActor
final class ArchiveStore: ObservableObject {
    static let shared = ArchiveStore()

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

    private static let storageKey = "rcq.archive"

    private init() { load() }

    func contains(peer uin: Int) -> Bool { entries.contains(.peer(uin: uin)) }
    func contains(group id: Int) -> Bool { entries.contains(.group(id: id)) }

    func toggle(peer uin: Int) {
        let key: Entry = .peer(uin: uin)
        if entries.contains(key) {
            entries.remove(key)
        } else {
            entries.insert(key)
            // Mutually exclusive with favorites — pinning + hiding
            // doesn't make sense. The user can re-favorite after
            // unarchiving if they want.
            FavoritesStore.shared.remove(peer: uin)
        }
        save()
    }

    func toggle(group id: Int) {
        let key: Entry = .group(id: id)
        if entries.contains(key) {
            entries.remove(key)
        } else {
            entries.insert(key)
            FavoritesStore.shared.remove(group: id)
        }
        save()
    }

    /// Burn-account hook.
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
