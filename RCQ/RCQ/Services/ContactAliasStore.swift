import Foundation

/// My own name for a contact, keyed by UIN.
///
/// DEVICE-ONLY on purpose, and that is the whole design decision: what I chose
/// to call someone says more about the relationship than the contact row does,
/// it serves no server-side function, and an island that stores it is an island
/// that can be made to hand it over. The cost is honest and is stated in the
/// UI — aliases do not follow you to another device until the backup does.
///
/// Per-account like every other device-local store, so two identities on one
/// phone never see each other's naming.
@MainActor
final class ContactAliasStore: ObservableObject {
    static let shared = ContactAliasStore()

    /// My own names for people, keyed by ``aliasKey(_:host:)`` — the bare uin
    /// for someone on this island, `uin@host` for someone on another one.
    ///
    /// ⚠ A uin is issued per island, so keying by the number alone gave `1234`
    /// here and `1234@is2.rcq.app` ONE name between them: renaming the stranger
    /// renamed your friend, and vice versa.
    @Published private(set) var aliases: [String: String] = [:]

    /// Pre-per-account global slot, kept only so an install that predates
    /// accounts does not lose its names on upgrade.
    private static let legacyKey = "rcq.contactAliases"

    private var storageKey: String {
        guard let id = AppGroup.readActiveAccountID() else { return Self.legacyKey }
        return "rcq.contactAliases.\(id.uuidString)"
    }

    private init() { load() }

    /// The map key for a person: the bare uin on this island, `uin@host` on
    /// another. A bare key written before this existed is still the correct
    /// same-island key, so nothing already saved is lost.
    static func aliasKey(_ uin: Int, host: String? = nil) -> String {
        guard let host, !host.isEmpty else { return String(uin) }
        return "\(uin)@\(host.lowercased())"
    }

    /// The name I gave this person, or nil when I never gave one.
    func alias(for uin: Int, host: String? = nil) -> String? {
        aliases[Self.aliasKey(uin, host: host)]
    }

    /// Set, or with nil/blank clear, my own name for them.
    func setAlias(_ name: String?, for uin: Int, host: String? = nil) {
        let key = Self.aliasKey(uin, host: host)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)
        if let trimmed, !trimmed.isEmpty {
            aliases[key] = String(trimmed)
        } else {
            aliases.removeValue(forKey: key)
        }
        save()
    }

    /// What to CALL this person on screen: my name for them when I set one,
    /// otherwise whatever they call themselves.
    func displayName(for uin: Int, fallback: String, host: String? = nil) -> String {
        aliases[Self.aliasKey(uin, host: host)] ?? fallback
    }

    func reload() { load() }

    private func load() {
        let d = UserDefaults.standard
        let raw = d.dictionary(forKey: storageKey) as? [String: String]
            ?? d.dictionary(forKey: Self.legacyKey) as? [String: String]
            ?? [:]
        // Keys are taken as written: "1234" is the same-island key, "1234@host"
        // the cross-island one. The old format is a subset of the new one.
        aliases = raw
    }

    private func save() {
        UserDefaults.standard.set(aliases, forKey: storageKey)
    }
}
