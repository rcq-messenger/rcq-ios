import Combine
import Foundation

@MainActor
final class ReactionInboxStore: ObservableObject {
    static let shared = ReactionInboxStore()

    @Published private(set) var threads: Set<String> = []

    /// Per-thread set of MY message UUIDs (as strings) that received an unseen
    /// reaction from someone else. Powers the reaction-jump-on-open: opening a
    /// chat scrolls to + flashes the first such message, then the thread's set
    /// is consumed by `clear(_:)` so it doesn't re-flash on reopen. Recorded at
    /// the SAME site that flips the heart indicator, gated identically (asset
    /// present, reactor != me, target is my message).
    @Published private(set) var reactedMsgIDs: [String: Set<String>] = [:]

    private static let storageKey = "rcq.reaction_inbox"
    private static let msgStorageKey = "rcq.reaction_inbox_msgids"

    private init() { load() }

    func has(_ thread: ThreadID) -> Bool { threads.contains(key(thread)) }

    func mark(_ thread: ThreadID) {
        let k = key(thread)
        guard !threads.contains(k) else { return }
        threads.insert(k)
        save()
    }

    /// Record `id` (a reacted-to message UUID) as an unseen-reaction target on
    /// `thread`. Idempotent. Paired with `mark(_:)` at the reaction-receive site.
    func markMsg(_ thread: ThreadID, id: UUID) {
        let k = key(thread)
        var set = reactedMsgIDs[k] ?? []
        guard set.insert(id.uuidString).inserted else { return }
        reactedMsgIDs[k] = set
        saveMsgIDs()
    }

    /// Reacted message UUIDs for `thread`, in no particular order. The opener
    /// flashes the first one. Empty when nothing pending.
    func reactedIDs(_ thread: ThreadID) -> [UUID] {
        (reactedMsgIDs[key(thread)] ?? []).compactMap { UUID(uuidString: $0) }
    }

    func clear(_ thread: ThreadID) {
        let k = key(thread)
        var changed = false
        if threads.remove(k) != nil { changed = true }
        if reactedMsgIDs.removeValue(forKey: k) != nil {
            saveMsgIDs()
            changed = true
        }
        if changed { save() }
    }

    func wipe() {
        threads = []
        reactedMsgIDs = [:]
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        UserDefaults.standard.removeObject(forKey: Self.msgStorageKey)
    }

    private func key(_ thread: ThreadID) -> String {
        "\(thread.kindString):\(thread.rawKey)"
    }

    private func load() {
        let raw = (UserDefaults.standard.array(forKey: Self.storageKey) as? [String]) ?? []
        threads = Set(raw)
        if let stored = UserDefaults.standard.dictionary(forKey: Self.msgStorageKey)
            as? [String: [String]] {
            reactedMsgIDs = stored.mapValues { Set($0) }
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(threads), forKey: Self.storageKey)
    }

    private func saveMsgIDs() {
        let serializable = reactedMsgIDs.mapValues { Array($0) }
        UserDefaults.standard.set(serializable, forKey: Self.msgStorageKey)
    }
}

/// Home-row "@mention" indicator store. Identical shape to
/// `ReactionInboxStore` but a separate UserDefaults bucket: a thread can
/// carry the heart (reaction) and the @ (mention) independently. Marked on
/// inbound GROUP `.text` that mentions the local user while the thread isn't
/// being viewed; cleared when the thread is opened.
@MainActor
final class MentionInboxStore: ObservableObject {
    static let shared = MentionInboxStore()

    @Published private(set) var threads: Set<String> = []

    private static let storageKey = "rcq.mention_inbox"

    private init() { load() }

    func has(_ thread: ThreadID) -> Bool { threads.contains(key(thread)) }

    func mark(_ thread: ThreadID) {
        let k = key(thread)
        guard !threads.contains(k) else { return }
        threads.insert(k)
        save()
    }

    func clear(_ thread: ThreadID) {
        guard threads.remove(key(thread)) != nil else { return }
        save()
    }

    func wipe() {
        threads = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func key(_ thread: ThreadID) -> String {
        "\(thread.kindString):\(thread.rawKey)"
    }

    private func load() {
        let raw = (UserDefaults.standard.array(forKey: Self.storageKey) as? [String]) ?? []
        threads = Set(raw)
    }

    private func save() {
        UserDefaults.standard.set(Array(threads), forKey: Self.storageKey)
    }
}

/// Per-group high-water mark of the newest @mention the user has already SEEN
/// (epoch seconds). The in-chat @-jump FAB counts only mentions NEWER than
/// this, so reopening a thread you've already read doesn't resurface the FAB
/// for old mentions — the "собачка always shows / jumps to an old mention"
/// report. Advanced on chat close to the newest loaded mention; monotonic.
@MainActor
final class MentionSeenStore: ObservableObject {
    static let shared = MentionSeenStore()

    @Published private(set) var seenAt: [Int: Double] = [:]   // group id → epoch seconds

    private static let storageKey = "rcq.mention_seen_at"

    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Double] {
            seenAt = stored.reduce(into: [:]) { acc, kv in if let g = Int(kv.key) { acc[g] = kv.value } }
        }
    }

    /// The cut-off: only mentions sent AFTER this are still "unseen".
    func lastSeen(group id: Int) -> Date {
        Date(timeIntervalSince1970: seenAt[id] ?? 0)
    }

    /// Mark every mention up to [date] in [group] as seen. Monotonic — never
    /// moves the cut-off backwards.
    func markSeen(group id: Int, upTo date: Date) {
        let t = date.timeIntervalSince1970
        guard t > (seenAt[id] ?? 0) else { return }
        seenAt[id] = t
        UserDefaults.standard.set(
            seenAt.reduce(into: [String: Double]()) { $0[String($1.key)] = $1.value },
            forKey: Self.storageKey
        )
    }

    func wipe() {
        seenAt = [:]
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}
