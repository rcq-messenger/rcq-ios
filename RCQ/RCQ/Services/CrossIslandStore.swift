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
    // Per-account: a cross-island contact added on one local account must NOT
    // bleed into another (founder report: `911@api` added on the is2 account
    // showed up on the 911 account, where it read as "I added myself"). The
    // old single global key `rcq.crossisland.contacts.v1` is left orphaned.
    private static let keyPrefix = "rcq.crossisland.contacts.v1."

    private let defaults: UserDefaults
    private var accountKey: String
    private var cache: [String: Contact]   // keyed "uin@host"

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        // Non-isolated file read (same source MessageDB/KeychainStore resolve
        // the per-account slot from) so init stays off the main actor.
        accountKey = Self.keyFor(AppGroup.readActiveAccountID())
        cache = Self.load(defaults, accountKey)
    }

    private static func keyFor(_ id: UUID?) -> String {
        keyPrefix + (id?.uuidString ?? "none")
    }

    private static func load(_ defaults: UserDefaults, _ key: String) -> [String: Contact] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Contact].self, from: data) else { return [:] }
        return map
    }

    /// Re-point at the active account's cross-island contacts. Called on launch
    /// and on every account switch (AppState.rebootForActiveAccount), so the
    /// list is per-account and never bleeds across local accounts.
    func bind(accountID: UUID?) {
        accountKey = Self.keyFor(accountID)
        cache = Self.load(defaults, accountKey)
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
            defaults.set(data, forKey: accountKey)
        }
    }
}
