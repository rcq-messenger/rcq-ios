import Combine
import Foundation

/// Thin client over `/polls/*` and `/groups/{id}/polls`. Keeps an
/// in-memory cache of `PollState` keyed by `pollID` so the chat
/// bubble can render counts immediately on tap without a refetch.
/// Subscribers (the bubble view) bind to the `Published` cache and
/// auto-refresh when `vote` / `close` settles.
@MainActor
final class PollService: ObservableObject {
    static let shared = PollService()

    @Published private(set) var statesByID: [Int: PollState] = [:]

    private init() {}

    /// Create a server-side poll for a group. Returns the new
    /// `poll_id` which the caller then folds into the
    /// `Envelope.poll(...)` it broadcasts to the group's members.
    func createPoll(
        inGroupID groupID: Int,
        messageID: String,
        numOptions: Int,
        singleChoice: Bool,
        anonymous: Bool
    ) async throws -> Int {
        struct Body: Encodable {
            let message_id: String
            let num_options: Int
            let single_choice: Bool
            let anonymous: Bool
        }
        struct Out: Decodable {
            let poll_id: Int
            let created_at: Date
        }
        let out: Out = try await APIClient.shared.request(
            "POST",
            "/groups/\(groupID)/polls",
            body: Body(
                message_id: messageID,
                num_options: numOptions,
                single_choice: singleChoice,
                anonymous: anonymous
            )
        )
        return out.poll_id
    }

    /// Toggle a vote on `optionIndex`. Server enforces single-vs-multi
    /// semantics: single-choice re-vote replaces the prior pick, multi
    /// toggles the specific option independently. Re-clicking the same
    /// option in single-choice mode is interpreted as unvote.
    @discardableResult
    func vote(pollID: Int, optionIndex: Int) async throws -> PollState {
        struct Body: Encodable { let option_index: Int }
        let out: PollState = try await APIClient.shared.request(
            "POST",
            "/polls/\(pollID)/vote",
            body: Body(option_index: optionIndex)
        )
        statesByID[pollID] = out
        return out
    }

    /// Creator-only close. Subsequent vote attempts on this poll 403.
    @discardableResult
    func close(pollID: Int) async throws -> PollState {
        let out: PollState = try await APIClient.shared.request(
            "POST",
            "/polls/\(pollID)/close"
        )
        statesByID[pollID] = out
        return out
    }

    /// Pull fresh state. Called by the bubble on appear so a poll
    /// rendered from a stale local copy reconciles with the latest
    /// tallies before the user interacts.
    @discardableResult
    func refresh(pollID: Int) async -> PollState? {
        do {
            let out: PollState = try await APIClient.shared.request(
                "GET",
                "/polls/\(pollID)"
            )
            statesByID[pollID] = out
            return out
        } catch {
            return nil
        }
    }

    /// Recovery path for `.poll` chat rows that lost their server-
    /// side `pollID` on a CoreData reload (the column was added
    /// later — pre-existing rows reload with `pollID = 0`, which
    /// the model layer surfaces as nil). The envelope's UUID
    /// uniquely maps to the originating poll, so this re-resolves
    /// the server id without any user action. The bubble caches
    /// the recovered id in @State so subsequent renders skip the
    /// lookup.
    func lookupByMessage(messageID: String) async -> PollState? {
        do {
            let out: PollState = try await APIClient.shared.request(
                "GET",
                "/polls/by_message/\(messageID)"
            )
            statesByID[out.pollID] = out
            return out
        } catch {
            return nil
        }
    }
}
