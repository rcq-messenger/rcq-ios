import Foundation
import SwiftUI

/// Static catalog kind. Mirrors `ItemKindOut` on the backend.
///
/// The server is the source of truth for the catalog; the iOS client
/// fetches a snapshot once at app start (cached in `ItemCatalog`) and
/// uses it to render kind-specific UI without round-trips. Adding a
/// kind = adding it to `app/services/lootbox_catalog.py` on the
/// server, redeploy, restart the iOS app to refresh the cache.
struct ItemKind: Codable, Identifiable, Hashable {
    let id: String                 // slug, e.g. "analog_heart"
    let section: ItemSection
    let pullWeight: Double
    let limit: Int?
    let rarity: ItemRarity         // legacy default rarity (catalog hint only)
    let appliesAs: ItemAppliesAs
    let assetRef: String           // "items/coll1/Item1.png"
    let perPullChance: Double      // % within the catalog (server-computed)
    /// Number of mints already issued for capped kinds. nil for uncapped.
    /// `remaining = limit - mintedCount`. Old backends omit this; treat
    /// nil as "unknown" and don't show the remaining badge.
    let mintedCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, section
        case pullWeight = "pull_weight"
        case limit, rarity
        case appliesAs = "applies_as"
        case assetRef = "asset_ref"
        case perPullChance = "per_pull_chance"
        case mintedCount = "minted_count"
    }

    /// Remaining mint slots for capped kinds. nil if uncapped or if the
    /// server hasn't reported `minted_count` yet (older backend).
    var remainingMints: Int? {
        guard let limit, let mintedCount else { return nil }
        return max(0, limit - mintedCount)
    }

    /// Bundle URL for the kind's image. The server stores asset_refs
    /// like "items/coll1/Item1.png"; the iOS bundle has a folder
    /// reference at "Items/" so we strip the "items/" prefix and
    /// look the file up via `subdirectory:`.
    var bundleURL: URL? {
        let trimmed = assetRef.hasPrefix("items/")
            ? String(assetRef.dropFirst("items/".count))
            : assetRef
        let basename = (trimmed as NSString).lastPathComponent
        let subdir = (trimmed as NSString).deletingLastPathComponent
        let stem = (basename as NSString).deletingPathExtension
        let ext = (basename as NSString).pathExtension
        let bundleSubdir = subdir.isEmpty ? "Items" : "Items/\(subdir)"
        return Bundle.main.url(
            forResource: stem, withExtension: ext, subdirectory: bundleSubdir,
        )
    }

    /// Whether this kind can be tempered. Only the collectible
    /// section (pets) — cosmetics never have a level.
    var isTemperable: Bool {
        section == .pets
    }

    /// Whether this kind can be equipped (cosmetic packs).
    var isEquippable: Bool {
        appliesAs != .none
    }
}

enum ItemSection: String, Codable, CaseIterable, Hashable {
    case smileys, voices, pets

    var displayName: String {
        switch self {
        case .smileys:  return "inventory.section.smileys".localized
        case .voices:   return "inventory.section.voices".localized
        case .pets:     return "inventory.section.pets".localized
        }
    }
    /// Order in which sections appear in the inventory grid.
    var sortOrder: Int {
        switch self {
        case .pets:     return 0
        case .smileys:  return 1
        case .voices:   return 2
        }
    }
}

enum ItemRarity: String, Codable, CaseIterable, Hashable {
    case common, uncommon, rare, epic, legendary

    /// Sort order for the inventory grid (legendary first).
    var rollWeight: Int {
        switch self {
        case .legendary: return 0
        case .epic:      return 1
        case .rare:      return 2
        case .uncommon:  return 3
        case .common:    return 4
        }
    }

    /// Palette tint per rarity. Uses RCQ's accent green for common
    /// and tones up through the gold/purple/red ladder.
    var color: Color {
        switch self {
        case .common:    return Color(hex: 0x6BB12C)  // RCQ accent green
        case .uncommon:  return Color(hex: 0x4A9DDB)
        case .rare:      return Color(hex: 0x8E5BD4)
        case .epic:      return Color(hex: 0xD9923A)
        case .legendary: return Color(hex: 0xC8442A)
        }
    }

    var label: String {
        switch self {
        case .common:    return "rarity.common".localized
        case .uncommon:  return "rarity.uncommon".localized
        case .rare:      return "rarity.rare".localized
        case .epic:      return "rarity.epic".localized
        case .legendary: return "rarity.legendary".localized
        }
    }
}

/// What equipping this kind does. Smiley/voice packs are additive
/// (multiple equipped = all stack). Skins are exclusive (one equipped
/// at a time — exclusivity enforced server-side by the equip endpoint).
/// Pet companions are likewise exclusive — one pet rides over the
/// status icon at a time. `none` = no in-app function, pure showcase.
enum ItemAppliesAs: String, Codable, Hashable {
    case cosmeticSmileys = "cosmetic_smileys"
    case cosmeticVoice = "cosmetic_voice"
    case cosmeticSkin = "cosmetic_skin"
    case petCompanion = "pet_companion"
    case none = "none"
}
