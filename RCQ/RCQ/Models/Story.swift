import Foundation

/// 24h ephemeral story. One row per `POST /stories` on the backend.
///
/// **Anonymity contract**: when `isAnonymous == true` and `ownerUIN`
/// is `nil`, the byline in the viewer must read "Anonymous" — the
/// server stripped the identity at the wire level. The poster sees
/// their own anonymous stories with the real `ownerUIN` populated
/// (so they can manage / delete / view counts).
///
/// `viewed` is per-viewer state — true if the current user already
/// marked this story watched. Drives the segment colour in
/// `StoryThumbnailRing`.
struct Story: Identifiable, Codable, Hashable {
    let id: String
    let ownerUIN: Int?           // nil for anonymous stories from non-self
    let ownerNickname: String?   // nil for anonymous stories from non-self
    let mediaID: String
    let mediaKind: MediaKind
    let mediaKeyB64: String
    let caption: String?
    let isAnonymous: Bool
    let durationSec: Int?
    let postedAt: Date
    let expiresAt: Date
    let viewCount: Int
    let viewed: Bool

    enum MediaKind: String, Codable {
        case photo
        case video
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUIN = "owner_uin"
        case ownerNickname = "owner_nickname"
        case mediaID = "media_id"
        case mediaKind = "media_kind"
        case mediaKeyB64 = "media_key_b64"
        case caption
        case isAnonymous = "is_anonymous"
        case durationSec = "duration_sec"
        case postedAt = "posted_at"
        case expiresAt = "expires_at"
        case viewCount = "view_count"
        case viewed
    }
}

/// One contact's bundle of active stories. The feed view groups
/// stories by owner so the contact list shows a single ring per
/// person, regardless of how many stories they've posted today.
struct StoryGroup: Identifiable, Codable, Hashable {
    /// Group identity for ForEach. For non-anonymous groups it's the
    /// owner UIN; for anonymous groups (where `ownerUIN` is nil)
    /// it's the first story's id so each anonymous group has a
    /// stable, unique key.
    var id: String {
        if let uin = ownerUIN { return "u:\(uin)" }
        return "anon:\(stories.first?.id ?? UUID().uuidString)"
    }

    let ownerUIN: Int?
    let ownerNickname: String?
    let isAnonymous: Bool
    let stories: [Story]

    /// Any unviewed story in the group → the ring renders accent-
    /// coloured segments; otherwise grey.
    var hasUnviewed: Bool {
        stories.contains { !$0.viewed }
    }

    enum CodingKeys: String, CodingKey {
        case ownerUIN = "owner_uin"
        case ownerNickname = "owner_nickname"
        case isAnonymous = "is_anonymous"
        case stories
    }
}

/// Wire shape for `/stories/feed`.
struct StoryFeedResponse: Codable {
    let groups: [StoryGroup]
}

/// Wire shape for `POST /stories`.
struct StoryPostResponse: Codable {
    let story: Story
}

/// Wire shape for `GET /stories/{id}/viewers`. Owner-only.
struct StoryViewer: Codable, Identifiable, Hashable {
    var id: Int { viewerUIN }
    let viewerUIN: Int
    let viewerNickname: String
    let viewedAt: Date

    enum CodingKeys: String, CodingKey {
        case viewerUIN = "viewer_uin"
        case viewerNickname = "viewer_nickname"
        case viewedAt = "viewed_at"
    }
}

struct StoryViewersResponse: Codable {
    let viewers: [StoryViewer]
}
