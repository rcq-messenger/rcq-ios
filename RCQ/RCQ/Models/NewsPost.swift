import Foundation

/// Mirror of backend `NewsPostOut` Pydantic model. Wire shape is
/// snake_case via custom CodingKeys; Swift surface stays camelCase.
struct NewsPost: Codable, Hashable, Identifiable {
    let id: Int
    let body: String
    let attachments: [Attachment]
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
