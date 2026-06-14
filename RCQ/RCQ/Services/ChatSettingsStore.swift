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

    /// `peer:<UIN>` / `group:<id>` → screen-secure mode on. When on for a
    /// thread, that chat's screen is blanked in screenshots/recording (on
    /// BOTH sides — the flag is propagated to the peer via a `secureScreen`
    /// envelope), and a screenshot posts a "took a screenshot" notice.
    @Published private(set) var secureByThread: [String: Bool] = [:]

    private static let storageKey = "rcq.chat.ttl"
    private static let secureKey = "rcq.chat.secure"

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

    /// Whether screen-secure mode is on for a thread.
    func isSecure(thread: ThreadID) -> Bool {
        secureByThread[Self.threadKey(thread)] ?? false
    }

    /// Set/clear screen-secure mode for a thread (local store only — the
    /// caller propagates to the peer via a `secureScreen` envelope).
    func setSecure(_ on: Bool, for thread: ThreadID) {
        let key = Self.threadKey(thread)
        if on { secureByThread[key] = true } else { secureByThread.removeValue(forKey: key) }
        saveSecure()
    }

    /// Burn-account hook — wipe everything along with the rest of the
    /// local state.
    func wipe() {
        ttlByThread.removeAll()
        secureByThread.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        UserDefaults.standard.removeObject(forKey: Self.secureKey)
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
        if let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) {
            ttlByThread = raw.compactMapValues { $0 as? Int }
        }
        if let raw = UserDefaults.standard.dictionary(forKey: Self.secureKey) {
            secureByThread = raw.compactMapValues { $0 as? Bool }
        }
    }

    private func save() {
        UserDefaults.standard.set(ttlByThread, forKey: Self.storageKey)
    }

    private func saveSecure() {
        UserDefaults.standard.set(secureByThread, forKey: Self.secureKey)
    }
}

/// GLOBAL chat wallpaper (one for the whole app, Android parity). The
/// selection is `""` (default theme bg), `preset:<id>`, or `custom` (a JPEG
/// saved on disk). Persisted in UserDefaults; the custom image is a file.
@MainActor
final class ChatBackgroundStore: ObservableObject {
    static let shared = ChatBackgroundStore()

    @Published private(set) var selection: String = ""
    /// HOME / chat-list wallpaper (a SEPARATE selection, founder's choice).
    @Published private(set) var homeSelection: String = ""
    /// Bumped when a custom image file is replaced, so views re-read it.
    @Published private(set) var customStamp: Int = 0
    @Published private(set) var homeCustomStamp: Int = 0

    private static let key = "rcq.chat.background"
    private static let homeKey = "rcq.home.background"

    private init() {
        selection = UserDefaults.standard.string(forKey: Self.key) ?? ""
        homeSelection = UserDefaults.standard.string(forKey: Self.homeKey) ?? ""
    }

    static func imageURL(home: Bool) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(home ? "rcq-home-bg.jpg" : "rcq-chat-bg.jpg")
    }
    static var customImageURL: URL { imageURL(home: false) }

    func selection(home: Bool) -> String { home ? homeSelection : selection }
    func customStamp(home: Bool) -> Int { home ? homeCustomStamp : customStamp }

    func set(_ s: String, home: Bool = false) {
        if home {
            homeSelection = s
            UserDefaults.standard.set(s, forKey: Self.homeKey)
        } else {
            selection = s
            UserDefaults.standard.set(s, forKey: Self.key)
        }
    }

    /// Save a picked image (already JPEG-compressed) as the custom wallpaper.
    func saveCustom(_ data: Data, home: Bool = false) {
        let url = Self.imageURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        if home { homeCustomStamp &+= 1 } else { customStamp &+= 1 }
        set("custom", home: home)
    }

    func wipe() {
        set(""); set("", home: true)
        try? FileManager.default.removeItem(at: Self.imageURL(home: false))
        try? FileManager.default.removeItem(at: Self.imageURL(home: true))
    }
}
