import Foundation

/// One row from the item's append-only journal — a drop, gift,
/// trade, temper attempt or disassemble. Drives the public ownership
/// chain on the detail sheet. Burned / disassembled items still
/// surface their final tombstone row.
struct ItemHistoryEvent: Codable, Hashable {
    let action: String        // "drop" | "trade" | "temper_success" | "temper_burn" | "disassemble" | "gift" | "market_sold"
    let fromUIN: Int?
    let toUIN: Int?
    let levelBefore: Int?
    let levelAfter: Int?
    /// Tokens paid by the buyer, populated only for the
    /// `market_sold` row. Renders as "за N жетонов" next to the
    /// from→to chips.
    let priceTokens: Int?
    let at: Date

    enum CodingKeys: String, CodingKey {
        case action
        case fromUIN = "from_uin"
        case toUIN = "to_uin"
        case levelBefore = "level_before"
        case levelAfter = "level_after"
        case priceTokens = "price_tokens"
        case at
    }

    /// Optional decoder so older server responses (pre-marketplace
    /// build) without `price_tokens` still parse — Swift's auto-
    /// synthesized Codable would throw on the missing key without
    /// this. Keeps the transition zero-downtime.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try c.decode(String.self, forKey: .action)
        self.fromUIN = try c.decodeIfPresent(Int.self, forKey: .fromUIN)
        self.toUIN = try c.decodeIfPresent(Int.self, forKey: .toUIN)
        self.levelBefore = try c.decodeIfPresent(Int.self, forKey: .levelBefore)
        self.levelAfter = try c.decodeIfPresent(Int.self, forKey: .levelAfter)
        self.priceTokens = try c.decodeIfPresent(Int.self, forKey: .priceTokens)
        self.at = try c.decode(Date.self, forKey: .at)
    }
}

struct ItemHistoryResponse: Codable {
    let events: [ItemHistoryEvent]
}
