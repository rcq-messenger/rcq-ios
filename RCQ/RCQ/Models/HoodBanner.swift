import Foundation

/// One paid district-banner placement. Lives in a geohash-level-6
/// bucket (same key the Nearby surface uses); auto-expires when
/// `expiresAt` passes. Created via mock-IAP through
/// `HoodBannerService.create(...)`.
struct HoodBanner: Codable, Identifiable, Hashable {
    let id: Int
    let bucketID: String
    let text: String
    let imageURL: String?
    let imageThumbURL: String?
    let isAnonymous: Bool
    let isMine: Bool
    let ownerNickname: String?
    let ownerUIN: Int?
    let duration: String
    let createdAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, text, duration
        case bucketID = "bucket_id"
        case imageURL = "image_url"
        case imageThumbURL = "image_thumb_url"
        case isAnonymous = "is_anonymous"
        case isMine = "is_mine"
        case ownerNickname = "owner_nickname"
        case ownerUIN = "owner_uin"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct HoodBannerList: Codable {
    let items: [HoodBanner]
    let totalActive: Int
    let canPost: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case totalActive = "total_active"
        case canPost = "can_post"
    }
}

/// Pricing tier returned by `/hood/banners/pricing`. Display-only on
/// iOS — the cents are also baked into the iOS composer as a fallback
/// when the network probe lags.
struct HoodBannerPricing: Codable, Identifiable {
    let duration: String
    let label: String
    let priceCents: Int
    let priceDisplay: String

    var id: String { duration }

    enum CodingKeys: String, CodingKey {
        case duration, label
        case priceCents = "price_cents"
        case priceDisplay = "price_display"
    }
}

enum BannerDuration: String, CaseIterable, Codable, Identifiable {
    case oneHour   = "1h"
    case sixHours  = "6h"
    case oneDay    = "24h"
    case sevenDays = "7d"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .oneHour:   return "hood.duration.1h".localized
        case .sixHours:  return "hood.duration.6h".localized
        case .oneDay:    return "hood.duration.24h".localized
        case .sevenDays: return "hood.duration.7d".localized
        }
    }

    /// Fallback price (cents) if the /pricing probe hasn't landed
    /// yet. Mirrors `_PRICES_CENTS` on the server.
    var fallbackCents: Int {
        switch self {
        case .oneHour:   return 99
        case .sixHours:  return 199
        case .oneDay:    return 499
        case .sevenDays: return 1499
        }
    }

    var fallbackDisplay: String {
        let dollars = Double(fallbackCents) / 100.0
        return String(format: "$%.2f", dollars)
    }
}
