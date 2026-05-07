import Foundation

/// One owned instance of a kind. Mirrors `ItemOut` on the backend.
///
/// `id` is a server-stamped UUID4 (lowercase). The iOS client always
/// normalizes `UUID.uuidString.lowercased()` before any cross-call —
/// case-sensitive string compare on the server would miss otherwise.
struct Item: Codable, Identifiable, Hashable {
    let id: String  // lowercase UUID4
    let kindID: String
    let rarity: ItemRarity
    let baseEssence: Int
    let purity: Double
    let mintNumber: Int?
    let level: Int
    let equipped: Bool
    let ownerUIN: Int
    let acquiredAt: Date
    /// True when this item currently has an active marketplace listing.
    /// Drives the "for sale" badge in the inventory grid + the gating
    /// on equip/disassemble/trade actions in the iOS UI. Defaults to
    /// false so legacy server payloads (pre-marketplace) decode cleanly.
    var listed: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case kindID = "kind_id"
        case rarity
        case baseEssence = "base_essence"
        case purity
        case mintNumber = "mint_number"
        case level
        case equipped
        case ownerUIN = "owner_uin"
        case acquiredAt = "acquired_at"
        case listed
    }

    init(
        id: String,
        kindID: String,
        rarity: ItemRarity,
        baseEssence: Int,
        purity: Double,
        mintNumber: Int?,
        level: Int,
        equipped: Bool,
        ownerUIN: Int,
        acquiredAt: Date,
        listed: Bool = false
    ) {
        self.id = id
        self.kindID = kindID
        self.rarity = rarity
        self.baseEssence = baseEssence
        self.purity = purity
        self.mintNumber = mintNumber
        self.level = level
        self.equipped = equipped
        self.ownerUIN = ownerUIN
        self.acquiredAt = acquiredAt
        self.listed = listed
    }

    /// Custom decoder so a server response that pre-dates the
    /// `listed` field decodes cleanly with `listed = false` rather
    /// than throwing on the missing key. Swift's auto-synthesised
    /// Codable init doesn't honour property defaults — it always
    /// `decode(_:forKey:)`s, so the explicit init is the safe path.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kindID = try c.decode(String.self, forKey: .kindID)
        self.rarity = try c.decode(ItemRarity.self, forKey: .rarity)
        self.baseEssence = try c.decode(Int.self, forKey: .baseEssence)
        self.purity = try c.decode(Double.self, forKey: .purity)
        self.mintNumber = try c.decodeIfPresent(Int.self, forKey: .mintNumber)
        self.level = try c.decode(Int.self, forKey: .level)
        self.equipped = try c.decode(Bool.self, forKey: .equipped)
        self.ownerUIN = try c.decode(Int.self, forKey: .ownerUIN)
        self.acquiredAt = try c.decode(Date.self, forKey: .acquiredAt)
        self.listed = try c.decodeIfPresent(Bool.self, forKey: .listed) ?? false
    }

    /// Derived showcase value (used by the public leaderboard later).
    /// Same shape the IX project uses: rarity_base × purity × (1 + level/9).
    /// Mint multiplier on capped kinds is applied via `mintMultiplier`.
    func showcaseValue(catalog: ItemCatalog) -> Int {
        let base = catalog.rarityBaseValue[rarity] ?? 1
        let levelBoost = 1.0 + Double(level) / 9.0
        let mintMul = mintMultiplier(for: mintNumber)
        let raw = Double(base) * purity * levelBoost * mintMul
        return Int(raw.rounded())
    }
}

/// Same mint-multiplier curve as IX `Artifact.mintMultiplier`. Higher
/// for the first few mints; flattens to 1× past #25.
func mintMultiplier(for mintNumber: Int?) -> Double {
    guard let m = mintNumber else { return 1.0 }
    if m == 1 { return 5.0 }
    if (2...3).contains(m) { return 3.0 }
    if (4...9).contains(m) { return 2.0 }
    if (10...25).contains(m) { return 1.5 }
    return 1.0
}

/// Pretty mint badge label. `nil` for uncapped kinds.
extension Item {
    var mintBadge: String? {
        guard let m = mintNumber else { return nil }
        return "#\(m)"
    }
    /// Vanity slot markers — surfaced as a "Lucky Mint" pill on the
    /// public profile. Mirrors the spec from `lootbox-plan.md`.
    /// `#1` is the only marker with an English flourish ("FIRST")
    /// in the original spec; routed through localization so the
    /// other locales can pick the right word ("Первый" in ru). The
    /// rest are pure numbers — language-agnostic.
    var luckyMintLabel: String? {
        guard let m = mintNumber else { return nil }
        switch m {
        case 1: return "item.lucky.first".localized
        case 100: return "#100"
        case 777: return "#777"
        case 1000: return "#1000"
        case 10_000: return "#10000"
        default: return nil
        }
    }
    /// Pristine / Flawless purity tiers — localized so non-English
    /// locales render their own short word for the badge.
    var purityTier: String? {
        if purity >= 1.38 { return "item.purity.flawless".localized }
        if purity >= 1.30 { return "item.purity.pristine".localized }
        return nil
    }
}
