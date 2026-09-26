import Combine
import Foundation

/// Per-device set of chats the user locked behind the app PIN. Opening a locked
/// chat prompts for the PIN that opened this session first
/// (PanicPINService.verifySessionPIN — never the wipe PIN, so it never wipes).
/// Only meaningful when a PIN is configured; the lock toggle is only offered
/// then. Mirrors `ArchiveStore`.
///
/// ⚠ Turning a lock OFF goes through the PIN (#1045), turning it ON does not.
/// Callers use `set(_:locked:)` for the off half, after the PIN sheet.
@MainActor
final class LockedChatsStore: ObservableObject {
    static let shared = LockedChatsStore()

    enum Entry: Hashable, Codable, Identifiable {
        case peer(uin: Int)
        case group(id: Int)

        var id: String { key }

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

    private init() {
        load()
        // Brings the extension's copy in line on every launch, including the
        // first launch of a build that introduced it (#1045).
        syncExtensionMirror()
    }

    func contains(peer uin: Int) -> Bool { entries.contains(.peer(uin: uin)) }
    func contains(group id: Int) -> Bool { entries.contains(.group(id: id)) }

    /// Whether `thread`'s lock is in force: the flag is set AND there is a PIN
    /// to ask for. The same two conditions ChatView's gate checks, so what the
    /// gate hides, the long-press preview and the banners do not show (#1045).
    func holds(_ thread: ThreadID) -> Bool {
        guard PINVault.isConfigured else { return false }
        switch thread {
        case .peer(let uin): return contains(peer: uin)
        case .group(let id): return contains(group: id)
        }
    }

    /// Set, not flip. There used to be a `toggle` here, and a toggle was what
    /// let anyone holding the unlocked phone take a lock off in one tap
    /// (#1045). The "off" half now runs after a PIN sheet, and a flip there
    /// would lock the chat again if anything had already unlocked it while the
    /// sheet was up.
    func set(_ entry: Entry, locked: Bool) {
        guard entries.contains(entry) != locked else { return }
        if locked { entries.insert(entry) } else { entries.remove(entry) }
        save()
    }

    /// Burn-account hook, and removing the app PIN (#1045): a lock with no PIN
    /// to ask for is not enforced, so it goes with the PIN rather than lying
    /// dormant and coming back the day a new PIN is set.
    func wipe() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        syncExtensionMirror()
    }

    /// Hand the notification extension the locks that are in force (#1045).
    /// Also called from `PanicPINService` on every PIN state change, because
    /// "in force" depends on a PIN existing.
    func syncExtensionMirror() {
        AppGroup.setLockedChats(PINVault.isConfigured ? Set(entries.map(\.key)) : [])
    }

    // MARK: - persistence

    private func load() {
        let raw = (UserDefaults.standard.array(forKey: Self.storageKey) as? [String]) ?? []
        entries = Set(raw.compactMap(Entry.decode))
    }

    private func save() {
        UserDefaults.standard.set(entries.map(\.key), forKey: Self.storageKey)
        syncExtensionMirror()
    }
}
