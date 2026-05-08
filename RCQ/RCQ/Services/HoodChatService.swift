import Combine
import Foundation

/// Anonymous bucket-local public chat. Joined alongside a People Nearby
/// check-in. Server fans out every event to every UIN in the bucket
/// (sender included), so all state flows through WS — no optimistic append.
///
/// Messages are NOT end-to-end encrypted. Senders are pseudonymous via
/// the anonymous label minted at check-in. UI surfaces a permanent
/// "unencrypted" banner via `HoodChatView`.
@MainActor
final class HoodChatService: ObservableObject {
    static let shared = HoodChatService()

    @Published private(set) var activeBucket: String?
    @Published private(set) var messages: [HoodMessage] = []
    /// UINs checked into this bucket (us included).
    @Published private(set) var bucketCount: Int = 0
    @Published private(set) var sending: Bool = false
    @Published var lastError: String?

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
        // Subscribe BEFORE the catch-up fetch so the fetch's count
        // includes us and any in-flight `hood_message` is fanned out.
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
            // Restore reply target on failure so the user can retry.
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

    /// Server enforces "only the author" — local UI just hides the menu row.
    /// `hood_delete` WS event applies the soft-delete uniformly via `handle`.
    func delete(messageID: Int) async {
        struct Body: Encodable { let message_id: Int }
        do {
            let _: EmptyResponse? = try? await APIClient.shared.request(
                "POST", "/hood/delete", body: Body(message_id: messageID)
            )
        }
    }

    /// Toggle a reaction. Passing the same asset twice clears it.
    func toggleReaction(messageID: Int, asset: String) async {
        struct Body: Encodable {
            let message_id: Int
            let asset: String?
        }
        // Optimistic local apply.
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
            // Next hood_reaction broadcast reconciles us — don't un-flip.
        }
    }

    func wipe() {
        leave()
    }

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

/// One message in `HoodChatService.messages`. Mirrors `HoodOut`.
struct HoodMessage: Identifiable, Hashable, Decodable {
    let id: Int
    let bucketID: String
    let uin: Int
    let nickname: String
    var body: String
    let createdAt: Date
    /// Sender's status at write time — keeps the row's dot fresh
    /// without per-bucket presence subscription.
    let status: UserStatus
    /// True = anonymous handle, false = real nickname (UIN visible).
    let anonymous: Bool
    /// Gated by `gender_visibility = "everyone"`. Null = hide.
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
