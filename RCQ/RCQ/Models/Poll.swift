import Foundation

/// Encrypted-side poll payload — what travels in `Message.text` for
/// `kind == .poll`. The renderer decodes this lazily; server only
/// holds the structural shape (vote tallies indexed by option index),
/// so a fresh app install with the encrypted envelope still has
/// everything needed to render the question + options.
struct PollPayload: Codable, Hashable {
    let question: String
    let options: [String]
    let singleChoice: Bool
    let anonymous: Bool

    static func decode(from text: String) -> PollPayload? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PollPayload.self, from: data)
    }
}

/// Server-side poll state. Pulled from `/polls/{id}` for tally
/// updates. Field shapes mirror the backend `PollOut` Pydantic model.
struct PollState: Codable, Hashable, Identifiable {
    var id: Int { pollID }

    let pollID: Int
    let groupID: Int
    let creatorUIN: Int
    let messageID: String
    let numOptions: Int
    let singleChoice: Bool
    let anonymous: Bool
    let closedAt: Date?
    let createdAt: Date
    let tallies: [OptionTally]
    let totalVotes: Int
    let myVotes: [Int]

    struct OptionTally: Codable, Hashable {
        let optionIndex: Int
        let count: Int
        let voterUINs: [Int]

        enum CodingKeys: String, CodingKey {
            case optionIndex = "option_index"
            case count
            case voterUINs = "voter_uins"
        }
    }

    enum CodingKeys: String, CodingKey {
        case pollID = "poll_id"
        case groupID = "group_id"
        case creatorUIN = "creator_uin"
        case messageID = "message_id"
        case numOptions = "num_options"
        case singleChoice = "single_choice"
        case anonymous
        case closedAt = "closed_at"
        case createdAt = "created_at"
        case tallies
        case totalVotes = "total_votes"
        case myVotes = "my_votes"
    }
}
