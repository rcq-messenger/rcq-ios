import Combine
import Foundation

/// In-memory cache + ping coordinator for the closed-group view-count
/// feature. Mirrors what Telegram shows under each message in a
/// channel-style group: an aggregate count of unique members who
/// have read the message, with no identity reveal.
///
/// Server endpoints:
///   POST /groups/{group_id}/messages/{message_id}/viewed
///   POST /groups/{group_id}/view-counts  body: { message_ids: [...] }
///
/// Closed groups only (server enforces). For open groups every
/// method here is a no-op so the iOS gate can be added wherever a
/// counter is rendered without branching on `isClosed` first.
@MainActor
final class GroupViewsService: ObservableObject {
    static let shared = GroupViewsService()

    /// `[groupID: [messageID: count]]`. Published so SwiftUI bubbles
    /// react when a fresh count lands from `refresh(...)`.
    @Published private(set) var counts: [Int: [String: Int]] = [:]

    /// `[groupID: Set<messageID>]` — message IDs we have already
    /// pinged in the current process. Prevents the on-appear hook
    /// from firing a ping every scroll-by.
    private var pinged: [Int: Set<String>] = [:]

    private init() {}

    func count(group: Int, message: UUID) -> Int? {
        counts[group]?[message.uuidString.lowercased()]
    }

    /// Fire a single view-ping. Deduplicated client-side so the same
    /// message never gets multiple pings from this device. Silent on
    /// failure — counts are best-effort metadata.
    func ping(group: Int, message: UUID, groupIsClosed: Bool) {
        guard groupIsClosed else { return }
        let mid = message.uuidString.lowercased()
        if pinged[group, default: []].contains(mid) { return }
        pinged[group, default: []].insert(mid)
        Task {
            do {
                let _: EmptyResponse = try await APIClient.shared.request(
                    "POST",
                    "/groups/\(group)/messages/\(mid)/viewed",
                )
            } catch {
                pinged[group]?.remove(mid)
            }
        }
    }

    /// Refresh counts for a batch of message IDs in one round-trip.
    /// Called when the chat opens (visible window) and after a few
    /// seconds of scroll inactivity. Missing IDs in the response are
    /// treated as zero views.
    func refresh(group: Int, messages: [UUID], groupIsClosed: Bool) async {
        guard groupIsClosed, !messages.isEmpty else { return }
        struct Body: Encodable { let message_ids: [String] }
        struct Resp: Decodable { let counts: [String: Int] }
        let ids = messages.map { $0.uuidString.lowercased() }
        do {
            let resp: Resp = try await APIClient.shared.request(
                "POST",
                "/groups/\(group)/view-counts",
                body: Body(message_ids: ids),
            )
            var merged = counts[group] ?? [:]
            // Server omits zero-count keys. Make sure missing IDs
            // settle at 0 instead of staying nil, so a previously-
            // viewed message that was deleted server-side resets
            // visually.
            for id in ids {
                merged[id] = resp.counts[id] ?? 0
            }
            counts[group] = merged
        } catch {
            // Soft-fail. Next refresh tries again; bubble shows
            // whatever count was cached or hides the badge entirely.
        }
    }

    /// Drop everything we know — used on logout / account migration
    /// so the next user does not inherit stale state.
    func clear() {
        counts = [:]
        pinged = [:]
    }
}
