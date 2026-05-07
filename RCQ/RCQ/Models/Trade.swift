import Foundation

/// One pending or resolved trade. Mirrors `TradeOut` on the backend.
///
/// `isGift` is server-computed: empty `requestedItems` AND zero
/// requested currencies AND non-empty offered side. Surfaced as a
/// flag so iOS doesn't reverse-engineer the same predicate.
struct Trade: Codable, Identifiable, Hashable {
    let id: String
    let fromUIN: Int
    let toUIN: Int
    let status: String        // "pending" | "accepted" | "declined" | "cancelled"
    let offeredItems: [Item]
    let requestedItems: [Item]
    /// UINs the proposer is putting up. Carries `tier` snapshot so
    /// the chip renders rarity-tinted without a follow-up catalog
    /// lookup. Default empty for legacy trades that pre-date UIN
    /// trading + for compatibility with old wire payloads.
    let offeredUins: [TradeUinChip]
    let requestedUins: [TradeUinChip]
    let offeredTokens: Int
    let offeredScrolls: Int
    let requestedTokens: Int
    let requestedScrolls: Int
    let note: String?
    let createdAt: Date
    let resolvedAt: Date?
    let isGift: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case fromUIN = "from_uin"
        case toUIN = "to_uin"
        case status
        case offeredItems = "offered_items"
        case requestedItems = "requested_items"
        case offeredUins = "offered_uins"
        case requestedUins = "requested_uins"
        case offeredTokens = "offered_tokens"
        case offeredScrolls = "offered_scrolls"
        case requestedTokens = "requested_tokens"
        case requestedScrolls = "requested_scrolls"
        case note
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
        case isGift = "is_gift"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fromUIN = try c.decode(Int.self, forKey: .fromUIN)
        toUIN = try c.decode(Int.self, forKey: .toUIN)
        status = try c.decode(String.self, forKey: .status)
        offeredItems = try c.decode([Item].self, forKey: .offeredItems)
        requestedItems = try c.decode([Item].self, forKey: .requestedItems)
        // UIN arrays default to empty when the server omits them — the
        // pre-UIN-trade rows in DB don't have these fields and fan out
        // through the same WS event encoder.
        offeredUins = (try? c.decode([TradeUinChip].self, forKey: .offeredUins)) ?? []
        requestedUins = (try? c.decode([TradeUinChip].self, forKey: .requestedUins)) ?? []
        offeredTokens = try c.decode(Int.self, forKey: .offeredTokens)
        offeredScrolls = try c.decode(Int.self, forKey: .offeredScrolls)
        requestedTokens = try c.decode(Int.self, forKey: .requestedTokens)
        requestedScrolls = try c.decode(Int.self, forKey: .requestedScrolls)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        isGift = try c.decode(Bool.self, forKey: .isGift)
    }

    /// True for the "I'm asking and offering nothing" shape — useful
    /// to distinguish from a Gift in the UI ("Buying X" vs "Gifting X").
    var isBuyOnly: Bool {
        offeredItems.isEmpty
            && offeredUins.isEmpty
            && offeredTokens == 0
            && offeredScrolls == 0
            && (
                requestedItems.count > 0
                || requestedUins.count > 0
                || requestedTokens > 0
                || requestedScrolls > 0
            )
    }
}

/// Compact UIN snapshot inside a trade. Mirror of backend
/// `UinTradePayload`. Renders as a `#NNNNNN` chip with a tier-tinted
/// border on the trade card; the tier carries with the chip so we
/// don't have to reach for the catalog at render time.
struct TradeUinChip: Codable, Hashable, Identifiable {
    let uin: Int
    let tier: String

    var id: Int { uin }
}
