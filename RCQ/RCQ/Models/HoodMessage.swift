import Foundation

/// One message in the geohash-bucket public room. Mirrors `HoodMessageOut`
/// from `backend/app/routers/hood.py`. Plaintext, pseudonymous — the only
/// "identity" is the nickname chosen at check-in time + the optional
/// `ownerUIN` exposed when `anonymous == false`.
struct HoodMessage: Identifiable, Hashable, Decodable {
    let id: Int
    let bucketID: String
    let nickname: String
    let ownerUIN: Int?
    var body: String
    let anonymous: Bool
    let replyToID: Int?
    let replyToNickname: String?
    let replyToBody: String?
    var deleted: Bool
    /// Maps `emoji -> "uin1,uin2,..."` per the backend's compact wire format.
    var reactions: [String: String]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bucketID = "bucket_id"
        case nickname
        case ownerUIN = "owner_uin"
        case body
        case anonymous
        case replyToID = "reply_to_id"
        case replyToNickname = "reply_to_nickname"
        case replyToBody = "reply_to_body"
        case deleted
        case reactions
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.bucketID = try c.decode(String.self, forKey: .bucketID)
        self.nickname = try c.decode(String.self, forKey: .nickname)
        self.ownerUIN = try? c.decodeIfPresent(Int.self, forKey: .ownerUIN)
        self.body = try c.decode(String.self, forKey: .body)
        self.anonymous = (try? c.decodeIfPresent(Bool.self, forKey: .anonymous)) ?? true
        self.replyToID = try? c.decodeIfPresent(Int.self, forKey: .replyToID)
        self.replyToNickname = try? c.decodeIfPresent(String.self, forKey: .replyToNickname)
        self.replyToBody = try? c.decodeIfPresent(String.self, forKey: .replyToBody)
        self.deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        self.reactions = (try? c.decodeIfPresent([String: String].self, forKey: .reactions)) ?? [:]
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

/// Response from `GET /hood/messages?bucket=...`.
struct HoodListResponse: Decodable {
    let messages: [HoodMessage]
    let bucketCount: Int

    enum CodingKeys: String, CodingKey {
        case messages
        case bucketCount = "bucket_count"
    }
}
