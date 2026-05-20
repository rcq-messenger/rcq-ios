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
    /// Token cost per pull at boost 0. Server-side enforced; client
    /// uses it to gate the Open button label and check the wallet.
    let pullCost: Int
    /// Pet-boost slider params — mirror of the server constants so
    /// the client can render live odds + price as the slider drags
    /// (server stays the authority on the actual roll).
    let petBoostWeightMax: Double
    let petBoostPriceMult: Double
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
        case petBoostWeightMax = "pet_boost_weight_max"
        case petBoostPriceMult = "pet_boost_price_mult"
        case kinds
        case tokenPacks = "token_packs"
    }

    // MARK: - Pet-boost mirror (matches lootbox_catalog.py)

    private func clampBoost(_ b: Double) -> Double { min(1, max(0, b)) }

    /// Pets-section weight (0–100) at the given boost — mirror of
    /// `boosted_section_weights` on the server.
    func boostedPetWeight(_ boost: Double) -> Double {
        let b = clampBoost(boost)
        let base = sectionWeights["pets"] ?? 0
        return base + b * (petBoostWeightMax - base)
    }

    /// Overall probability a pull yields a pet at the given boost —
    /// section weight discounted by the scroll-bundle branch. Drives
    /// the slider's live "pet chance" readout.
    func boostedPetChance(_ boost: Double) -> Double {
        (1.0 - scrollDropChance) * boostedPetWeight(boost) / 100.0
    }

    /// Token price for one pull at the given boost — mirror of
    /// `pull_cost_for` on the server.
    func boostedPullCost(_ boost: Double) -> Int {
        let b = clampBoost(boost)
        return max(pullCost, Int((Double(pullCost) * (1.0 + b * petBoostPriceMult)).rounded()))
    }

    /// Section weights (0–100) re-balanced for the boost — mirror of
    /// `boosted_section_weights` on the server. `pets` grows, the
    /// rest shrink proportionally so the total stays 100.
    func boostedSectionWeights(_ boost: Double) -> [String: Double] {
        let petW = boostedPetWeight(boost)
        let others = sectionWeights.filter { $0.key != "pets" }
        let othersTotal = others.values.reduce(0, +)
        var out: [String: Double] = ["pets": petW]
        let remaining = 100.0 - petW
        if othersTotal > 0 {
            for (s, w) in others { out[s] = remaining * (w / othersTotal) }
        } else {
            for s in others.keys { out[s] = 0 }
        }
        return out
    }

    /// Per-kind drop chance (conditional on an item dropping, i.e.
    /// before the scroll-bundle branch) at the given boost. Section
    /// slice × the kind's share of its section's pull weights.
    func boostedPerKindChance(_ kindID: String, boost: Double) -> Double {
        guard let k = kind(by: kindID) else { return 0 }
        let siblings = kinds.filter { $0.section == k.section }
        let total = siblings.reduce(0.0) { $0 + $1.pullWeight }
        guard total > 0 else { return 0 }
        let slice = boostedSectionWeights(boost)[k.section.rawValue] ?? 0
        return slice * (k.pullWeight / total)
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
