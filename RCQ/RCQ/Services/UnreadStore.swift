import Foundation

/// Persistent unread counters per 1:1 thread (by peer UIN) and per group.
///
/// Lives in UserDefaults so counts survive app launches — without this,
/// `ContactService.contacts` and `GroupService.unread` are pure
/// in-memory state that gets reset to zero on every cold start
/// (contacts are reloaded from the server, which doesn't track
/// per-client unread). Symptom: a message arrives over WS while
/// online, the red dot lights up, the user closes the app and
/// reopens it — the message is still there in the chat (MessageDB
/// rehydrates) but the contact list has no badge.
///
/// We deliberately key by UIN / group id rather than ThreadID so the
/// stored map stays JSON-friendly (UserDefaults can persist
/// `[String: Int]` directly). The dictionary is small (one entry per
/// unread thread, cleared when the user opens the chat) so we just
/// rewrite the whole thing on every mutation — no risk of partial
/// writes, no need for a serialization queue.
@MainActor
final class UnreadStore {
    static let shared = UnreadStore()

    private static let key = "rcq.unread.v1"

    /// In-memory mirror of the persisted dictionary. Loaded once on init
    /// and kept in sync with UserDefaults on every mutation.
    private var counts: [String: Int]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Int]
        self.counts = raw ?? [:]
    }

    func unread(forPeer uin: Int) -> Int {
        counts[Self.peerKey(uin)] ?? 0
    }

    func unread(forGroup id: Int) -> Int {
        counts[Self.groupKey(id)] ?? 0
    }

    /// Bump the counter for `uin`. Called regardless of whether the
    /// contact is currently in `ContactService.contacts` — if the
    /// sender isn't in our list yet (race between push tap +
    /// contact list refresh, or a peer who reset their account
    /// after we last refreshed), we still record the unread so the
    /// count appears the moment the contact lands.
    func incrementPeer(_ uin: Int) {
        counts[Self.peerKey(uin), default: 0] += 1
        persist()
    }

    func incrementGroup(_ id: Int) {
        counts[Self.groupKey(id), default: 0] += 1
        persist()
    }

    func clearPeer(_ uin: Int) {
        guard counts.removeValue(forKey: Self.peerKey(uin)) != nil else { return }
        persist()
    }

    func clearGroup(_ id: Int) {
        guard counts.removeValue(forKey: Self.groupKey(id)) != nil else { return }
        persist()
    }

    /// Burn-account / wipe path. Drop every counter at once.
    func wipeAll() {
        guard !counts.isEmpty else { return }
        counts = [:]
        persist()
    }

    /// Snapshot of every persisted peer counter, exposed so
    /// `GroupService.refresh` can hydrate its in-memory `unread`
    /// dictionary without going through UserDefaults a second time.
    var allPeerCounts: [Int: Int] {
        var out: [Int: Int] = [:]
        for (k, v) in counts {
            if k.hasPrefix("peer:"), let uin = Int(k.dropFirst("peer:".count)) {
                out[uin] = v
            }
        }
        return out
    }

    var allGroupCounts: [Int: Int] {
        var out: [Int: Int] = [:]
        for (k, v) in counts {
            if k.hasPrefix("group:"), let id = Int(k.dropFirst("group:".count)) {
                out[id] = v
            }
        }
        return out
    }

    private func persist() {
        UserDefaults.standard.set(counts, forKey: Self.key)
    }

    private static func peerKey(_ uin: Int) -> String { "peer:\(uin)" }
    private static func groupKey(_ id: Int) -> String { "group:\(id)" }
}
