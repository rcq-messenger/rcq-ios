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

    @Published private(set) var aliases: [Int: String] = [:]

    /// Pre-per-account global slot, kept only so an install that predates
    /// accounts does not lose its names on upgrade.
    private static let legacyKey = "rcq.contactAliases"

    private var storageKey: String {
        guard let id = AppGroup.readActiveAccountID() else { return Self.legacyKey }
        return "rcq.contactAliases.\(id.uuidString)"
    }

    private init() { load() }

    /// The name I gave this person, or nil when I never gave one.
    func alias(for uin: Int) -> String? { aliases[uin] }

    /// Set, or with nil/blank clear, my own name for `uin`.
    func setAlias(_ name: String?, for uin: Int) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)
        if let trimmed, !trimmed.isEmpty {
            aliases[uin] = String(trimmed)
        } else {
            aliases.removeValue(forKey: uin)
        }
        save()
    }

    /// What to CALL this person on screen: my name for them when I set one,
    /// otherwise whatever they call themselves.
    func displayName(for uin: Int, fallback: String) -> String {
        aliases[uin] ?? fallback
    }

    func reload() { load() }

    private func load() {
        let d = UserDefaults.standard
        let raw = d.dictionary(forKey: storageKey) as? [String: String]
            ?? d.dictionary(forKey: Self.legacyKey) as? [String: String]
            ?? [:]
        aliases = raw.reduce(into: [:]) { acc, kv in
            if let uin = Int(kv.key) { acc[uin] = kv.value }
        }
    }

    private func save() {
        let raw = aliases.reduce(into: [String: String]()) { acc, kv in
            acc[String(kv.key)] = kv.value
        }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }
}
