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
