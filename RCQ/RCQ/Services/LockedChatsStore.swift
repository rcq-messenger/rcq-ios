import Combine
import Foundation

/// Per-device set of chats the user locked behind the app PIN. Opening a locked
/// chat prompts for the existing PIN first (PanicPINService.verifyRealPIN — never
/// the panic PIN, so it never wipes). Only meaningful when a PIN is configured;
/// the lock toggle is only offered then. Mirrors `ArchiveStore`.
@MainActor
final class LockedChatsStore: ObservableObject {
    static let shared = LockedChatsStore()

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

    private static let storageKey = "rcq.locked_chats"

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
