import Foundation

/// A single marketplace listing — decodes the backend's
/// `ListingOut` row. Snapshots the item's rarity/level/purity at
/// listing time so the browse tile renders without a separate
/// `/items/{id}` round-trip per row.
struct MarketplaceListing: Codable, Identifiable, Hashable {
    let id: String
    let itemID: String
    let kindID: String
    let rarity: ItemRarity
    let level: Int
    let purity: Double
    /// Mint snapshot — drives the showcase essence multiplier on the
    /// listing tile (mint #1–#25 carry a value boost). Nil for
    /// uncapped kinds and for legacy rows pre-mint-snapshot.
    let mintNumber: Int?
    let sellerUIN: Int
    let sellerNickname: String?
    let priceTokens: Int
    /// Floor-rounded payout the seller receives after the 5% house
    /// fee. Server-computed so iOS doesn't drift on rounding.
    let sellerPayoutTokens: Int
    let status: String  // "active" | "sold" | "cancelled"
    let soldToUIN: Int?
    let soldToNickname: String?
    let createdAt: Date
    let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case itemID = "item_id"
        case kindID = "kind_id"
        case rarity
        case level
        case purity
        case mintNumber = "mint_number"
        case sellerUIN = "seller_uin"
        case sellerNickname = "seller_nickname"
        case priceTokens = "price_tokens"
        case sellerPayoutTokens = "seller_payout_tokens"
        case status
        case soldToUIN = "sold_to_uin"
        case soldToNickname = "sold_to_nickname"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    /// Same showcase formula `Item.showcaseValue` uses — base value
    /// per rarity × purity × (1 + level/9) × mint multiplier.
    /// Returns 0 when the catalog hasn't loaded yet so the row's
    /// "essence" cell can render a placeholder until it does.
    func showcaseValue(catalog: ItemCatalog?) -> Int {
        guard let catalog else { return 0 }
        let base = catalog.rarityBaseValue[rarity] ?? 1
        let levelBoost = 1.0 + Double(level) / 9.0
        let mintMul = mintMultiplier(for: mintNumber)
        let raw = Double(base) * purity * levelBoost * mintMul
        return Int(raw.rounded())
    }
}

/// Sort modes accepted by `GET /market/listings?sort=...`.
enum MarketSort: String, CaseIterable, Identifiable {
    case newest
    case priceAsc = "price_asc"
    case priceDesc = "price_desc"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest:    return "market.sort.newest".localized
        case .priceAsc:  return "market.sort.price_asc".localized
        case .priceDesc: return "market.sort.price_desc".localized
        }
    }
}
