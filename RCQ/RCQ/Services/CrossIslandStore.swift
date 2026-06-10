import Foundation

/// Federation Layer B (F2) — local store of cross-island contacts.
///
/// A peer on ANOTHER island is not a flagship user, so it can't live in the
/// server-side `/contacts` list. We keep cross-island contacts on-device, keyed
/// `uin@host`, as full `Contact`s (with `host` set + the keys from the peer's
/// island key card). `ContactService` merges these into its published list so
/// the normal chat-open + send flow works; `MessageService.sendEnvelope` routes
/// by `contact.host`. Mirrors web-chat's crossisland-store + Android's.
final class CrossIslandStore {
    static let shared = CrossIslandStore()

    private static let appGroup = "group.app.rcq.shared"
    private static let key = "rcq.crossisland.contacts.v1"

    private let defaults: UserDefaults
    private var cache: [String: Contact]   // keyed "uin@host"

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        if let data = defaults.data(forKey: Self.key),
           let map = try? JSONDecoder().decode([String: Contact].self, from: data) {
            cache = map
        } else {
            cache = [:]
        }
    }

    private func ciKey(_ uin: Int, _ host: String) -> String { "\(uin)@\(host.lowercased())" }

    func save(_ c: Contact) {
        guard let host = c.host else { return }
        cache[ciKey(c.uin, host)] = c
        persist()
    }

    /// All stored cross-island contacts (each has `host` set).
    func all() -> [Contact] { Array(cache.values) }

    /// Map an incoming sealed message's senderUIN back to a cross-island contact.
    /// Per-island uins can collide in theory; returns the first match.
    func find(uin: Int) -> Contact? { cache.values.first { $0.uin == uin } }

    func remove(uin: Int, host: String) {
        cache.removeValue(forKey: ciKey(uin, host))
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
