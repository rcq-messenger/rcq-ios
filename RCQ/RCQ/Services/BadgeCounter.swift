import Foundation

/// App-Group-shared per-thread unread counter. Both the NSE
/// (incrementing on each user-visible push) and the main app (resetting
/// per-thread on chat open, syncing the total to the app-icon badge)
/// read and write the same JSON blob.
///
/// Why a flat file and not `UserDefaults(suiteName:)` — same reason
/// `LanguageManager` migrated off cfprefsd: the daemon "detaches" App
/// Group suites under memory pressure and we silently lose writes. A
/// single JSON file in the shared container is reliable across the
/// main-app / NSE process boundary.
///
/// Concurrent NSE-vs-main-app writes can race — the file is rewritten
/// atomically (`.atomic` option) so we never read a torn payload, but a
/// simultaneous increment+reset MAY drop one update. The visible cost
/// is at most a stray off-by-one in the badge count until the next
/// event, which is acceptable for v1. If it becomes a real complaint
/// we promote this to a tiny SQLite or to NSFileCoordinator.
enum BadgeCounter {

    /// Thread-key conventions, mirroring `UNMutableNotificationContent.threadIdentifier`:
    /// - 1:1 messages: `peer-<UIN>`
    /// - groups: `group-<GID>` (not yet wired in NSE — reserved)
    /// - pending / trades: `pending`, `trades` (system trays, not counted)
    static func threadKey(peerUIN: Int) -> String { "peer-\(peerUIN)" }
    static func threadKey(groupID: Int) -> String { "group-\(groupID)" }

    private static var fileURL: URL {
        AppGroup.containerURL.appendingPathComponent("unread-counts.json")
    }

    private static func load() -> [String: Int] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: Int]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Bump the counter for `threadKey`. Returns the new TOTAL across
    /// every thread — that's the number the OS expects on the app icon.
    @discardableResult
    static func increment(threadKey: String, by delta: Int = 1) -> Int {
        var dict = load()
        dict[threadKey, default: 0] += delta
        save(dict)
        return dict.values.reduce(0, +)
    }

    /// Zero out a single thread (chat just got opened). Returns the new total.
    @discardableResult
    static func reset(threadKey: String) -> Int {
        var dict = load()
        guard dict[threadKey] != nil else { return dict.values.reduce(0, +) }
        dict.removeValue(forKey: threadKey)
        save(dict)
        return dict.values.reduce(0, +)
    }

    /// Wipe everything (panic-PIN wipe, account burn, sign-out).
    static func resetAll() {
        save([:])
    }

    static func total() -> Int {
        load().values.reduce(0, +)
    }
}
