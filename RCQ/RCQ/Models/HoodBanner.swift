import Foundation

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
    let createdAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, text
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
    let cooldownRemainingSeconds: Int

    enum CodingKeys: String, CodingKey {
        case items
        case totalActive = "total_active"
        case canPost = "can_post"
        case cooldownRemainingSeconds = "cooldown_remaining_seconds"
    }
}

enum BannerDuration: String, CaseIterable, Codable, Identifiable {
    case oneHour  = "1h"
    case sixHours = "6h"
    case oneDay   = "24h"
    case sevenDays = "7d"

    var id: String { rawValue }

    var tokens: Int {
        switch self {
        case .oneHour:   return 5
        case .sixHours:  return 20
        case .oneDay:    return 50
        case .sevenDays: return 200
        }
    }

    var label: String {
        switch self {
        case .oneHour:   return "hood_banner.duration.1h".localized
        case .sixHours:  return "hood_banner.duration.6h".localized
        case .oneDay:    return "hood_banner.duration.24h".localized
        case .sevenDays: return "hood_banner.duration.7d".localized
        }
    }
}
