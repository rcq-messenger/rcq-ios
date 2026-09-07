import Combine
import Foundation

/// Anonymous random-chat coordinator. Messages live in-memory only; never persisted.
@MainActor
final class RandomChatService: ObservableObject {
    static let shared = RandomChatService()

    enum State: Equatable {
        case idle
        case queueing
        case matched(RandomPeer)
        case ended(reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var messages: [Message] = []
    @Published private(set) var addRequestSent: Bool = false

    var activePeer: RandomPeer? {
        if case .matched(let p) = state { return p } else { return nil }
    }

    @Published private(set) var lastPeer: RandomPeer?

    /// Numbers that were random peers recently, and when the session with each
    /// ended.
    ///
    /// ⚠⚠ THIS IS A PRIVACY GATE, not bookkeeping. A random-chat message is an
    /// ordinary sealed 1:1 envelope — nothing on the wire says it came from a
    /// stranger, because sealed sender means the island cannot be told either.
    /// The only thing that made an incoming message "random" was this client
    /// knowing the sender was the peer it was talking to RIGHT NOW. So the
    /// moment a session ended, a message still in flight from that stranger
    /// arrived as an ordinary message from an unknown number, was filed into a
    /// normal thread, and the app then resolved their profile and showed their
    /// nickname. The founder walked into exactly that on 07.09: he left a random
    /// chat, a push arrived, he tapped it and was looking at a 1:1 conversation
    /// with a stranger whose number and name he was never meant to learn.
    ///
    /// It is symmetric: the same thing happened to the other person.
    ///
    /// ⚠⚠ IN THE SHARED APP GROUP, not in memory, and for two reasons that both
    /// bite.
    ///
    /// First: iOS kills a backgrounded app routinely. An in-memory set is gone
    /// by the time the queued message is drained on next launch, and it lands
    /// in an ordinary thread exactly as before — the fix would work only for
    /// somebody who never closed the app.
    ///
    /// Second: the notification extension is a SEPARATE PROCESS. It decrypts
    /// the envelope itself and titles the banner with the sender's nickname or
    /// bare number, which is the first half of what the founder saw, before the
    /// app is even opened. It can only be told through the group container.
    ///
    /// Still bounded by time, and still nothing but numbers and timestamps: a
    /// day is far longer than a message can plausibly be in flight and short
    /// enough that this never becomes a list of who you talked to.
    nonisolated private static let storeKey = "rcq.random.recentlyEnded"

    nonisolated private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.app.rcq.shared") ?? .standard
    }

    private var recentlyEnded: [Int: Date] {
        get {
            let raw = Self.sharedDefaults.dictionary(forKey: Self.storeKey) as? [String: Double] ?? [:]
            var out: [Int: Date] = [:]
            for (k, v) in raw {
                if let uin = Int(k) { out[uin] = Date(timeIntervalSince1970: v) }
            }
            return out
        }
        set {
            var raw: [String: Double] = [:]
            for (uin, at) in newValue { raw[String(uin)] = at.timeIntervalSince1970 }
            Self.sharedDefaults.set(raw, forKey: Self.storeKey)
        }
    }

    /// For the notification extension, which has no access to this class.
    /// Reads the same container and applies the same expiry.
    nonisolated static func isFinishedStrangerFromExtension(_ uin: Int) -> Bool {
        let raw = sharedDefaults.dictionary(forKey: storeKey) as? [String: Double] ?? [:]
        guard let at = raw[String(uin)] else { return false }
        return Date().timeIntervalSince1970 - at < endedGrace
    }

    /// How long after a session ends a message from that stranger is still
    /// treated as belonging to the session that is over.
    nonisolated static let endedGrace: TimeInterval = 24 * 3600

    /// Should a message from `uin` be dropped rather than filed?
    ///
    /// ⚠ `false` for anybody who is now a real contact. Two people CAN choose
    /// to swap contacts during a random chat (see `addRequestSent`), and once
    /// they have, they are not strangers any more and their messages are
    /// ordinary messages. Dropping those would break the one feature that
    /// exists to let a random chat become a real one.
    func isFinishedStranger(_ uin: Int) -> Bool {
        prune()
        guard let _ = recentlyEnded[uin] else { return false }
        if ContactService.shared.contacts.contains(where: { $0.uin == uin }) { return false }
        return true
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.endedGrace)
        recentlyEnded = recentlyEnded.filter { $0.value > cutoff }
    }

    /// Remember the peer of the session that is ending. Call BEFORE the state
    /// is cleared, while there is still a peer to remember.
    private func rememberEnded() {
        if let p = activePeer { recentlyEnded[p.uin] = Date() }
        if let p = lastPeer { recentlyEnded[p.uin] = Date() }
        prune()
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: - public API

    enum AgeGateReason: Equatable {
        case ageRequired
        case under18
    }

    @Published var ageGateBlock: AgeGateReason?

    func startQueue() async {
        switch state {
        case .queueing, .matched: return
        case .idle, .ended: break
        }
        state = .queueing
        do {
            let out: QueueResponse = try await APIClient.shared.request("POST", "/random/queue")
            applyQueueResponse(out)
        } catch APIError.http(403, let body) {
            state = .idle
            ageGateBlock = Self.parseAgeGate(body)
        } catch {
            state = .idle
        }
    }

    func leave() async {
        print("[Random] leave() called → state=.idle (caller initiated)")
        let wasMatched = activePeer != nil
        rememberEnded()
        state = .idle
        messages.removeAll()
        lastPeer = nil
        struct LeaveOut: Decodable { let left: Bool }
        do {
            let _: LeaveOut = try await APIClient.shared.request("POST", "/random/leave")
        } catch {
            _ = wasMatched
        }
    }

    func skip() async {
        rememberEnded()
        state = .queueing
        messages.removeAll()
        do {
            let out: QueueResponse = try await APIClient.shared.request("POST", "/random/skip")
            applyQueueResponse(out)
        } catch APIError.http(403, let body) {
            state = .idle
            ageGateBlock = Self.parseAgeGate(body)
        } catch {
            state = .idle
        }
    }

    func acknowledgeAgeGate() { ageGateBlock = nil }

    private static func parseAgeGate(_ body: String?) -> AgeGateReason? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any],
              let code = detail["code"] as? String else {
            return nil
        }
        switch code {
        case "age_required": return .ageRequired
        case "under_18":     return .under18
        default:             return nil
        }
    }

    func append(_ message: Message) {
        guard activePeer != nil else { return }
        // The buffer is in memory only, so nothing else dedups it. One redelivered
        // envelope used to become a second identical bubble (and a second tone).
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
    }

    func updateState(messageID id: UUID, to state: DeliveryState) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var msg = messages[idx]
        msg.deliveryState = state
        messages[idx] = msg
    }

    func deleteMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    func applyReaction(targetID: UUID, uin: Int, asset: String?) {
        guard let idx = messages.firstIndex(where: { $0.id == targetID }) else { return }
        var msg = messages[idx]
        var reactions = msg.reactions
        if let asset {
            reactions[uin] = asset
        } else {
            reactions.removeValue(forKey: uin)
        }
        msg.reactions = reactions
        messages[idx] = msg
    }

    func updateMediaID(messageID id: UUID, mediaID combined: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let msg = messages[idx]
        // `mediaID` is a let; rebuild the row with the combined "<mediaID>|<key>" token.
        let updated = Message(
            id: msg.id, thread: msg.thread, senderUIN: msg.senderUIN,
            isFromMe: msg.isFromMe, kind: msg.kind, text: msg.text,
            mediaID: combined, sentAt: msg.sentAt,
            deliveryState: msg.deliveryState, receivedWhileAway: msg.receivedWhileAway,
            deletedForEveryone: msg.deletedForEveryone, reactions: msg.reactions,
            thumbnailB64: msg.thumbnailB64, durationSec: msg.durationSec,
            ttlSeconds: msg.ttlSeconds, forwardedFromName: msg.forwardedFromName
        )
        messages[idx] = updated
    }

    func wipe() {
        rememberEnded()
        state = .idle
        messages.removeAll()
        addRequestSent = false
        lastPeer = nil
    }

    func clearEnded() {
        if case .ended = state {
            state = .idle
            lastPeer = nil
        }
    }

    func requestAddPeer() async {
        guard let peer = activePeer, !addRequestSent else { return }
        addRequestSent = true
        do {
            try await ContactService.shared.sendAddRequest(to: peer.uin)
        } catch {
            addRequestSent = false
        }
    }

    // MARK: - WS event plumbing

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .randomMatch(let peer):
            print("[Random] randomMatch peer=\(peer.uin) → state=.matched")
            messages.removeAll()
            addRequestSent = false
            lastPeer = nil
            state = .matched(peer)
        case .randomEnd(_, let reason):
            print("[Random] randomEnd reason=\(reason) prev_state=\(stateLabel(state)) lastPeer=\(lastPeer?.uin.description ?? "nil")")
            if case .matched(let p) = state {
                lastPeer = p
            }
            // The session is over from here, whoever ended it, so anything
            // still in flight from that stranger must not become an ordinary
            // conversation. See `recentlyEnded`.
            rememberEnded()
            state = .ended(reason: reason)
            print("[Random] state now .ended, lastPeer=\(lastPeer?.uin.description ?? "nil")")
        default:
            break
        }
    }

    private func stateLabel(_ s: State) -> String {
        switch s {
        case .idle: return "idle"
        case .queueing: return "queueing"
        case .matched(let p): return "matched(\(p.uin))"
        case .ended(let r): return "ended(\(r))"
        }
    }

    private func applyQueueResponse(_ out: QueueResponse) {
        if out.status == "matched", let pairID = out.pair_id, let peer = out.peer, let exp = out.expires_at {
            let p = RandomPeer(
                pairID: pairID,
                uin: peer.uin,
                nickname: peer.nickname,
                identityKey: peer.identity_key,
                signingKey: peer.signing_key,
                expiresAt: exp
            )
            messages.removeAll()
            addRequestSent = false
            state = .matched(p)
        } else if out.status == "queued" {
            state = .queueing
        } else {
            state = .idle
        }
    }

    // MARK: - wire types

    private struct QueueResponse: Decodable {
        let status: String
        let pair_id: String?
        let peer: PeerInfo?
        let expires_at: Date?

        struct PeerInfo: Decodable {
            let uin: Int
            let nickname: String
            let identity_key: String
            let signing_key: String
        }
    }
}
