import Foundation

/// Fixed-price marketplace listing for a UIN sitting in someone's
/// `OwnedUin` inventory. Wire shape mirrors the backend
/// `UinListingOut` schema. Parallel surface to `MarketplaceListing`
/// (item-for-tokens) — kept as its own model so neither carries
/// nullable columns from the other.
///
/// The listed UIN is always an inventory UIN (not the seller's
/// active identity). Sale flips `OwnedUin.owner_uin` to the buyer
/// in one server commit; no escrow row.
struct UinMarketplaceListing: Codable, Identifiable, Hashable {
    let id: String
    /// The UIN being sold. Renders monospaced with a "#" prefix on
    /// the listing card — same affordance as everywhere else in the
    /// app where a UIN is shown.
    let uin: Int
    /// Tier label captured at listing time ("common" / "mid" /
    /// "legendary"). Drives the rarity badge on the card without
    /// re-resolving via OwnedUin (which may move owners during the
    /// listing's lifetime).
    let tier: String
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
        case uin
        case tier
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
}
