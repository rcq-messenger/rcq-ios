import Foundation

/// Mirror of backend `NewsPostOut` Pydantic model. Wire shape is
/// snake_case via custom CodingKeys; Swift surface stays camelCase.
struct NewsPost: Codable, Hashable, Identifiable {
    let id: Int
    let body: String
    let attachments: [Attachment]
    /// The label the post was published under. The island's default was
    /// "RCQ Team" until 2026-09-02 and is the island's own name from then on;
    /// the card names the island itself and shows this only when it adds a
    /// name of its own.
    let authorLabel: String
    let publishedAt: Date

    struct Attachment: Codable, Hashable {
        let mediaID: String
        let mime: String
        let kind: String  // "image" | "video" | "gif"

        enum CodingKeys: String, CodingKey {
            case mediaID = "media_id"
            case mime
            case kind
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case attachments
        case authorLabel = "author_label"
        case publishedAt = "published_at"
    }
}
