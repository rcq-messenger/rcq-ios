import Combine
import Foundation

/// Anonymous bucket-local public chat. Joined alongside an
/// active People Nearby check-in. Server fans out every event
/// (`hood_message`, `hood_delete`, `hood_reaction`) to every
/// UIN in the same bucket — the sender included — so all
/// state mutations flow through the WS stream and the local
/// UI never has to optimistic-append.
///
/// Privacy posture: messages are *not* end-to-end encrypted.
/// Senders are pseudonymous (the anonymous label
/// `NearbyService` minted at check-in time) and UIN is
/// included so receivers can fire `/contacts/request` from a
/// bubble. The UI surfaces a permanent "this chat is
/// unencrypted, don't share private info" banner — see
/// `HoodChatView`.
@MainActor
final class HoodChatService: ObservableObject {
    static let shared = HoodChatService()

    @Published private(set) var activeBucket: String?
    @Published private(set) var messages: [HoodMessage] = []
    /// How many UINs are currently checked into this bucket
    /// (us included). Updated on every send broadcast and on
    /// every refresh.
    @Published private(set) var bucketCount: Int = 0
    @Published private(set) var sending: Bool = false
    @Published var lastError: String?

    /// The message we're currently composing a reply to. Set by
    /// the long-press menu's "Reply" action; cleared on send or
    /// by tapping the X on the compose preview.
    @Published var replyTarget: HoodMessage?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    func join(bucket: String) async {
        activeBucket = bucket
        messages = []
        replyTarget = nil
        // Mark our connection as actively viewing this bucket
        // BEFORE the catch-up fetch — that way the fetch's
        // `bucket_count` already includes us, and any
        // `hood_message` that lands while the request is in
        // flight is fanned out to us too.
        WebSocketService.shared.subscribeHood(bucket: bucket)
        await refresh()
    }

    func leave() {
        if activeBucket != nil {
            WebSocketService.shared.unsubscribeHood()
        }
        activeBucket = nil
        messages = []
        bucketCount = 0
        replyTarget = nil
        lastError = nil
    }

    func refresh() async {
        guard let bucket = activeBucket else { return }
        do {
            let resp: HoodListResponse = try await APIClient.shared.request(
                "GET", "/hood/messages",
                query: ["bucket": bucket]
            )
            messages = resp.messages
            bucketCount = resp.bucket_count
        } catch {
            // soft-fail
        }
    }

    func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activeBucket != nil else { return }
        sending = true
        defer { sending = false }
        let reply = replyTarget
        replyTarget = nil
        struct Body: Encodable {
            let body: String
            let reply_to_id: Int?
            let reply_to_nickname: String?
            let reply_to_body: String?
        }
        let payload = Body(
            body: trimmed,
            reply_to_id: reply?.id,
            reply_to_nickname: reply?.nickname,
            reply_to_body: reply.map { Self.snippet(for: $0) }
        )
        do {
            let _: HoodMessage = try await APIClient.shared.request(
                "POST", "/hood/send", body: payload
            )
            lastError = nil
        } catch {
            // Restore the reply target on failure so the user
            // can retry without re-selecting.
            replyTarget = reply
            if let api = error as? APIError, case .http(let code, let body) = api {
                if code == 429 {
                    lastError = "Slow down — give the room a beat."
                } else if let body, !body.isEmpty {
                    lastError = body
                } else {
                    lastError = "Couldn't send (\(code))."
                }
            } else {
                lastError = "Couldn't send. Check your connection."
            }
        }
    }

    /// Soft-delete one of our own messages. Server enforces the
    /// "only the author" rule; we don't pre-check beyond hiding
    /// the menu row, so a drift between client UI state and
    /// server state still produces the right outcome.
    func delete(messageID: Int) async {
        struct Body: Encodable { let message_id: Int }
        do {
            let _: EmptyResponse? = try? await APIClient.shared.request(
                "POST", "/hood/delete", body: Body(message_id: messageID)
            )
        }
        // Local mark-deleted is fire-and-forget; the WS event
        // hood_delete fires for everyone (including us) and
        // applies the soft-delete uniformly via `handle`.
    }

    /// Toggle a reaction. `asset` is the sticker name; passing
    /// the same asset twice clears it. UI should pre-render the
    /// flip optimistically to feel snappy — the server-side
    /// answer arrives via `hood_reaction` over WS within a few
    /// hundred ms.
    func toggleReaction(messageID: Int, asset: String) async {
        struct Body: Encodable {
            let message_id: Int
            let asset: String?
        }
        // Optimistic local apply so the bubble flips immediately.
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            var m = messages[idx]
            var reactions = m.reactions
            let myKey = String(AuthService.shared.ownUIN ?? -1)
            if reactions[myKey] == asset {
                reactions.removeValue(forKey: myKey)
            } else {
                reactions[myKey] = asset
            }
            m.reactions = reactions
            messages[idx] = m
        }
        do {
            let _: HoodMessage = try await APIClient.shared.request(
                "POST", "/hood/react", body: Body(message_id: messageID, asset: asset)
            )
        } catch {
            // The next hood_reaction broadcast for this msg
            // will reconcile us back to truth, so don't try to
            // un-flip locally on failure.
        }
    }

    func wipe() {
        leave()
    }

    /// Snippet used for both the reply quote stored on the
    /// server and the inline preview rendered above the
    /// composer. Keeps the wire and UI in sync.
    static func snippet(for message: HoodMessage) -> String {
        if message.deleted { return "Message deleted" }
        let body = message.body
        if body.count <= 80 { return body }
        return body.prefix(80) + "…"
    }

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .hoodMessage(let msg):
            guard let bucket = activeBucket, msg.bucketID == bucket else { return }
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[idx] = msg
            } else {
                messages.append(msg)
            }
        case .hoodCount(let bucketID, let count):
            guard let bucket = activeBucket, bucketID == bucket else { return }
            bucketCount = count
        case .hoodDelete(let bucketID, let messageID):
            guard let bucket = activeBucket, bucketID == bucket else { return }
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                var m = messages[idx]
                m.deleted = true
                m.body = ""
                messages[idx] = m
            }
        case .hoodReaction(let bucketID, let messageID, let reactions):
            guard let bucket = activeBucket, bucketID == bucket else { return }
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                var m = messages[idx]
                m.reactions = reactions
                messages[idx] = m
            }
        default:
            break
        }
    }
}

private struct HoodListResponse: Decodable {
    let messages: [HoodMessage]
    let bucket_count: Int
}

/// One message in `HoodChatService.messages`. Mirrors the
/// server's `HoodOut`; mutability is on the in-memory copy
/// only — it gets rewritten when WS events deliver new
/// reactions or a soft-delete from the bucket.
struct HoodMessage: Identifiable, Hashable, Decodable {
    let id: Int
    let bucketID: String
    let uin: Int
    let nickname: String
    var body: String
    let createdAt: Date
    /// Sender's account status snapshot at write time. Server
    /// includes it on every send / refresh / reaction broadcast
    /// so the row's status dot stays close-enough current
    /// without a separate presence subscription per bucket.
    let status: UserStatus
    /// Whether the byline is the anonymous handle (true) or the
    /// real account nickname (false). UI surfaces UIN in the
    /// non-anonymous case, hides it when anonymous.
    let anonymous: Bool
    /// Gender hint, server-gated by `gender_visibility = "everyone"`.
    /// Null = hide; non-null = `"male"`/`"female"`/`"other"`.
    let gender: String?
    var deleted: Bool
    let replyToID: Int?
    let replyToNickname: String?
    let replyToBody: String?
    var reactions: [String: String]

    enum CodingKeys: String, CodingKey {
        case id
        case bucketID = "bucket_id"
        case uin
        case nickname
        case body
        case createdAt = "created_at"
        case status
        case anonymous
        case gender
        case deleted
        case replyToID = "reply_to_id"
        case replyToNickname = "reply_to_nickname"
        case replyToBody = "reply_to_body"
        case reactions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.bucketID = try c.decode(String.self, forKey: .bucketID)
        self.uin = try c.decode(Int.self, forKey: .uin)
        self.nickname = try c.decode(String.self, forKey: .nickname)
        self.body = try c.decode(String.self, forKey: .body)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "online"
        self.status = UserStatus(rawValue: raw) ?? .online
        self.anonymous = (try? c.decodeIfPresent(Bool.self, forKey: .anonymous)) ?? true
        self.gender = try? c.decodeIfPresent(String.self, forKey: .gender)
        self.deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        self.replyToID = try? c.decodeIfPresent(Int.self, forKey: .replyToID)
        self.replyToNickname = try? c.decodeIfPresent(String.self, forKey: .replyToNickname)
        self.replyToBody = try? c.decodeIfPresent(String.self, forKey: .replyToBody)
        self.reactions = (try? c.decodeIfPresent([String: String].self, forKey: .reactions)) ?? [:]
    }
}
