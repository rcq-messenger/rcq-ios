import Combine
import Foundation

/// Per-contact notification-sound override. ICQ-classic feature
/// (different "uh-oh!" per buddy) revived for RCQ — ties directly
/// into the lootbox Voices section: each pack is a tradable
/// collectible, the user assigns it to one contact at a time and
/// the incoming-message cue plays that pack's sound instead of the
/// default. Until the lootbox surface ships, the available pack
/// list is hardcoded; once Voices land, `availablePacks` reads from
/// the user's inventory.
///
/// Persistence is local UserDefaults — assignments don't survive
/// account-burn (intentional, alongside FavoritesStore /
/// ArchiveStore — those are device-local organizational hints).
@MainActor
final class ContactSoundStore: ObservableObject {
    static let shared = ContactSoundStore()

    /// `uin → packID` map. Missing entry = peer uses the default
    /// system cue. SoundService falls back to the global default
    /// player when no override is registered.
    @Published private(set) var assignments: [Int: String] = [:]

    private static let storageKey = "rcq.contact_sounds"

    private init() { load() }

    func packID(for uin: Int) -> String? {
        return assignments[uin]
    }

    /// Set a pack for a contact, or pass `nil` to revert to the
    /// default. Idempotent on the same value.
    func setPack(_ packID: String?, for uin: Int) {
        if let id = packID, !id.isEmpty {
            assignments[uin] = id
        } else {
            assignments.removeValue(forKey: uin)
        }
        save()
    }

    /// Burn-account hook.
    func wipe() {
        assignments.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - persistence

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String]
        else { return }
        var map: [Int: String] = [:]
        for (k, v) in raw {
            if let uin = Int(k) { map[uin] = v }
        }
        assignments = map
    }

    private func save() {
        var raw: [String: String] = [:]
        for (uin, packID) in assignments { raw[String(uin)] = packID }
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }
}

/// One row in the per-contact sound picker. The `id` is either the
/// fixed `"default"` sentinel or a voice-section `kind_id` from the
/// user's inventory. `SoundService.customPlayer(packID:)` resolves
/// the kind id to a bundled asset via the catalog at playback time.
struct SoundPack: Identifiable, Hashable {
    let id: String
    let label: String

    static let `default` = SoundPack(id: "default", label: "sound.default".localized)

    /// Build the picker's option list for `uin`. Returns `[default]`
    /// plus one entry per UNIQUE voice-section kind the user owns
    /// (multiple instances of the same kind are deduped — owning two
    /// copies of the same voice pack doesn't add two rows to the
    /// picker). Empty inventory ⇒ only `default` is offered, which
    /// matches the user's expectation that mock names are gone.
    @MainActor
    static func availablePacks(
        items: [Item],
        catalog: ItemCatalog?,
    ) -> [SoundPack] {
        var seen = Set<String>()
        var packs: [SoundPack] = [.default]
        for item in items {
            guard !seen.contains(item.kindID) else { continue }
            guard let kind = catalog?.kind(by: item.kindID),
                  kind.section == .voices else { continue }
            seen.insert(item.kindID)
            packs.append(SoundPack(
                id: item.kindID,
                label: ItemDisplay.name(for: item.kindID),
            ))
        }
        return packs
    }
}
