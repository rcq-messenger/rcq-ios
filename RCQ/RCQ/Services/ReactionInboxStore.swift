import Combine
import Foundation

@MainActor
final class ReactionInboxStore: ObservableObject {
    static let shared = ReactionInboxStore()

    @Published private(set) var threads: Set<String> = []

    private static let storageKey = "rcq.reaction_inbox"

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
