import Foundation

/// Catalog snapshot fetched from `GET /catalog`. Cached in
/// `ItemsService.shared.catalog` for the lifetime of the app — the
/// catalog only changes on a server redeploy, and we accept that
/// users see the previous version until they restart.
struct ItemCatalog: Codable, Hashable {
    let sectionWeights: [String: Double]
    let rarityWeights: [String: Double]
    let purityMin: Double
    let purityMax: Double
    let scrollDropChance: Double
    let scrollDropMin: Int
    let scrollDropMax: Int
    let rarityEssenceRange: [String: [Int]]   // [lo, hi]
    let rarityBaseValueRaw: [String: Int]
    /// Token cost per pull. Server-side enforced; client uses it
    /// to gate the Open button label and check the wallet.
    let pullCost: Int
    let kinds: [ItemKind]
    let tokenPacks: [TokenPack]

    enum CodingKeys: String, CodingKey {
        case sectionWeights = "section_weights"
        case rarityWeights = "rarity_weights"
        case purityMin = "purity_min"
        case purityMax = "purity_max"
        case scrollDropChance = "scroll_drop_chance"
        case scrollDropMin = "scroll_drop_min"
        case scrollDropMax = "scroll_drop_max"
        case rarityEssenceRange = "rarity_essence_range"
        case rarityBaseValueRaw = "rarity_base_value"
        case pullCost = "pull_cost"
        case kinds
        case tokenPacks = "token_packs"
    }

    /// Typed convenience accessor.
    var rarityBaseValue: [ItemRarity: Int] {
        var out: [ItemRarity: Int] = [:]
        for (k, v) in rarityBaseValueRaw {
            if let r = ItemRarity(rawValue: k) { out[r] = v }
        }
        return out
    }

    func kind(by id: String) -> ItemKind? {
        kinds.first { $0.id == id }
    }
}

/// Token pack on the in-app shop. Tap → server credits the wallet
/// (mock IAP for now; real StoreKit comes in Session 5).
struct TokenPack: Codable, Identifiable, Hashable {
    let id: String          // "rcq.tokens.5" / 20 / 100
    let tokens: Int
    let priceLabel: String

    enum CodingKeys: String, CodingKey {
        case id, tokens
        case priceLabel = "price_label"
    }
}
