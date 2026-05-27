import Combine
import Foundation

/// Anonymous bucket-local public chat. Joined alongside a People Nearby
/// check-in. Server fans out every event to every UIN in the bucket
/// (sender included), so all state flows through WS — no optimistic append.
///
/// Messages are NOT end-to-end encrypted. Senders are pseudonymous via
/// the nickname chosen at check-in (anonymous-mode mints one; otherwise
/// the user's real nickname is sent). The view surfaces a permanent
/// "unencrypted" banner up top.
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
            bucketCount = resp.bucketCount
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
        // Pick the visible label: anonymous mode uses NearbyService's
        // pseudonym; non-anonymous uses the user's real nickname.
        let nearby = NearbyService.shared
        let isAnonymous = nearby.anonymous
        let nickname: String = {
            if isAnonymous { return nearby.displayName }
            let nick = AuthService.shared.nickname
            return nick.isEmpty ? String(AuthService.shared.ownUIN ?? 0) : nick
        }()
        struct Body: Encodable {
            let body: String
            let nickname: String
            let anonymous: Bool
            let reply_to_id: Int?
            let reply_to_nickname: String?
            let reply_to_body: String?
        }
        let payload = Body(
            body: trimmed,
            nickname: nickname,
            anonymous: isAnonymous,
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
                    lastError = "hood.error.slow_down".localized
                } else if let body, !body.isEmpty {
                    lastError = body
                } else {
                    lastError = String(format: "hood.error.send_failed_code".localized, code)
                }
            } else {
                lastError = "hood.error.send_failed".localized
            }
        }
    }

    /// Server enforces "only the author" — local UI just hides the menu row.
    /// `hood_delete` WS event applies the soft-delete uniformly via `handle`.
    func delete(messageID: Int) async {
        let _: EmptyResponse? = try? await APIClient.shared.request(
            "DELETE", "/hood/messages/\(messageID)"
        )
    }

    /// Toggle a reaction. Passing the same emoji twice clears it.
    func toggleReaction(messageID: Int, emoji: String) async {
        struct Body: Encodable { let emoji: String }
        // Optimistic local apply against the comma-list wire format.
        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            var m = messages[idx]
            var reactions = m.reactions
            let myKey = String(AuthService.shared.ownUIN ?? -1)
            let existing = reactions[emoji] ?? ""
            var uins = Set(existing.split(separator: ",").map(String.init).filter { !$0.isEmpty })
            if uins.contains(myKey) {
                uins.remove(myKey)
            } else {
                uins.insert(myKey)
            }
            if uins.isEmpty {
                reactions.removeValue(forKey: emoji)
            } else {
                reactions[emoji] = uins.sorted().joined(separator: ",")
            }
            m.reactions = reactions
            messages[idx] = m
        }
        let _: EmptyResponse? = try? await APIClient.shared.request(
            "POST", "/hood/messages/\(messageID)/react",
            body: Body(emoji: emoji)
        )
        // Next hood_reaction broadcast reconciles us — don't un-flip.
    }

    func wipe() {
        leave()
    }

    static func snippet(for message: HoodMessage) -> String {
        if message.deleted { return "hood.deleted".localized }
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
