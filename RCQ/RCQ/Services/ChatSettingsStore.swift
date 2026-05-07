import Combine
import Foundation

/// Per-thread chat preferences. Currently just disappearing-message TTL,
/// but the structure is here for whatever per-thread toggles we add
/// later (notification mute is in `SoundService` because it needs to
/// gate sound playback at receive time, but that could move here too).
///
/// Each setting is **independent per side** — the user's local
/// preference on a thread doesn't propagate to the peer. For TTL this
/// matches Apple Messages's model: my "delete after 1h" only deletes
/// my copy. Symmetric across-the-wire deletion would need a session
/// settings envelope, which we're keeping out of scope until LibSignal
/// lands.
///
/// Persisted in UserDefaults — the dataset is small (one row per chat
/// the user has touched) and never security-sensitive.
@MainActor
final class ChatSettingsStore: ObservableObject {
    static let shared = ChatSettingsStore()

    /// `peer:<UIN>` / `group:<id>` → TTL in seconds. Absent or `0` means
    /// disappearing is off for that thread.
    @Published private(set) var ttlByThread: [String: Int] = [:]

    private static let storageKey = "rcq.chat.ttl"

    /// Discrete options the UI exposes. Off (`nil`), then a few human
    /// scales — minutes for testing, hours for normal use, a day for
    /// "definitely gone tomorrow."
    static let ttlOptions: [(label: String, seconds: Int?)] = [
        ("Off",        nil),
        ("1 minute",   60),
        ("5 minutes",  300),
        ("1 hour",     3_600),
        ("24 hours",   86_400),
        ("7 days",     604_800),
    ]

    private init() { load() }

    /// Live TTL for a thread, or nil if disappearing is off.
    func ttl(for thread: ThreadID) -> Int? {
        let v = ttlByThread[Self.threadKey(thread)] ?? 0
        return v > 0 ? v : nil
    }

    /// Set or clear the TTL for a thread. Pass nil to turn disappearing off.
    func setTTL(_ ttl: Int?, for thread: ThreadID) {
        let key = Self.threadKey(thread)
        if let ttl, ttl > 0 {
            ttlByThread[key] = ttl
        } else {
            ttlByThread.removeValue(forKey: key)
        }
        save()
    }

    /// Burn-account hook — wipe everything along with the rest of the
    /// local state.
    func wipe() {
        ttlByThread.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    /// Human label for the live TTL of a thread — used by the chat header
    /// menu indicator and the system-notice text.
    static func label(for ttl: Int?) -> String {
        guard let ttl else { return "Off" }
        return ttlOptions.first { $0.seconds == ttl }?.label ?? "\(ttl)s"
    }

    /// Same key shape as `ThreadID.kindString` + `.rawKey` join. Kept
    /// private so Swift name-mangling doesn't drift between callers.
    private static func threadKey(_ thread: ThreadID) -> String {
        switch thread {
        case .peer(let uin):  return "peer:\(uin)"
        case .group(let id):  return "group:\(id)"
        }
    }

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) else { return }
        ttlByThread = raw.compactMapValues { $0 as? Int }
    }

    private func save() {
        UserDefaults.standard.set(ttlByThread, forKey: Self.storageKey)
    }
}
