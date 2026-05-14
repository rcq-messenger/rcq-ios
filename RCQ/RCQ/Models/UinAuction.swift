import Foundation

/// One premium-UIN auction round. Decodes the FastAPI `AuctionOut`
/// payload. The numbers field is a 6-9 digit Int (or 4-5 digit when
/// premium); we keep it as `Int` since UINs always fit in 32 bits
/// comfortably.
struct UinAuction: Identifiable, Hashable, Codable {
    let id: Int
    let uin: Int
    /// "common" | "mid" | "legendary" — drives the rarity badge.
    let tier: String
    let startingBid: Int
    let startedAt: Date
    /// Mutable on the wire — server bumps it on soft-close. Decoded
    /// fresh from every WS event so the live timer ticks correctly.
    var endsAt: Date
    var highBid: Int
    var highBidderUIN: Int?
    var highBidderNickname: String?
    let status: String  // "active" | "ended" | "void"

    enum CodingKeys: String, CodingKey {
        case id, uin, tier
        case startingBid = "starting_bid"
        case startedAt = "started_at"
        case endsAt = "ends_at"
        case highBid = "high_bid"
        case highBidderUIN = "high_bidder_uin"
        case highBidderNickname = "high_bidder_nickname"
        case status
    }
}

/// One bid in the live history strip.
struct UinAuctionBid: Hashable, Codable, Identifiable {
    let bidderUIN: Int
    let bidderNickname: String
    let amount: Int
    let placedAt: Date

    var id: String { "\(bidderUIN)-\(placedAt.timeIntervalSince1970)-\(amount)" }

    enum CodingKeys: String, CodingKey {
        case bidderUIN = "bidder_uin"
        case bidderNickname = "bidder_nickname"
        case amount
        case placedAt = "placed_at"
    }
}

/// `GET /uin_auctions/{id}` payload — auction snapshot + recent bids.
struct UinAuctionDetail: Codable {
    let auction: UinAuction
    let bids: [UinAuctionBid]
    let minNextBid: Int

    enum CodingKeys: String, CodingKey {
        case auction, bids
        case minNextBid = "min_next_bid"
    }
}

/// One row in the user's inventory of premium UINs they've won.
struct OwnedUIN: Identifiable, Hashable, Codable {
    let uin: Int
    let tier: String
    let wonAt: Date
    let source: String  // "auction" v1; v2 adds "marketplace" / "gift"

    var id: Int { uin }

    enum CodingKeys: String, CodingKey {
        case uin, tier
        case wonAt = "won_at"
        case source
    }
}

/// Past winner row for the "recent winners" history strip in the
/// auction surface.
struct UinAuctionRecentWinner: Hashable, Codable, Identifiable {
    let uin: Int
    let tier: String
    let winningBid: Int
    let winnerUIN: Int?
    let winnerNickname: String?

    var id: Int { uin }

    enum CodingKeys: String, CodingKey {
        case uin, tier
        case winningBid = "winning_bid"
        case winnerUIN = "winner_uin"
        case winnerNickname = "winner_nickname"
    }
}
