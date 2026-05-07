import Combine
import Foundation

/// Anonymous random-chat coordinator. Owns the lifecycle:
/// idle → queueing → matched(peer) → idle.
///
/// Messages exchanged inside an active pair live in this service's in-memory
/// `messages` array — they're ephemeral by design (the session vanishes when
/// either side leaves or after 5 minutes). They never enter `MessageStore`
/// or the persistent CoreData store, so refreshing the app or clearing the
/// random session leaves no trace.
///
/// WS events drive state transitions:
/// - `random_match` → `.matched(peer)` (both peers receive this)
/// - `random_end`   → `.idle`, message buffer cleared
@MainActor
final class RandomChatService: ObservableObject {
    static let shared = RandomChatService()

    enum State: Equatable {
        case idle
        case queueing
        case matched(RandomPeer)
        /// Last session ended — show the "the stranger has left" hint until
        /// the user dismisses it or starts a new search. Brief, transient.
        case ended(reason: String)
    }

    @Published private(set) var state: State = .idle
    /// Live messages for the current pair. Cleared on every match transition.
    @Published private(set) var messages: [Message] = []
    /// True once the user has tapped "Add as contact" in the active pair.
    /// Reset on every match transition. Lets the UI swap the CTA for a
    /// disabled "Request sent" pill so re-taps don't fire dup POSTs.
    @Published private(set) var addRequestSent: Bool = false

    var activePeer: RandomPeer? {
        if case .matched(let p) = state { return p } else { return nil }
    }

    /// Last peer the user was matched with — survives the
    /// `.matched → .ended` transition so RouletteView can keep
    /// rendering ChatView for a few seconds after the session
    /// closes (read-only, with a "session ended" banner). Without
    /// this the chat would yank to the idle screen the instant the
    /// 5-minute timer or peer-disconnect fired, which the user
    /// experiences as "I sent a photo and the chat closed on me."
    /// Cleared on the next match or on explicit dismissal.
    @Published private(set) var lastPeer: RandomPeer?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Subscribe to the WS event stream directly so AppState doesn't have
        // to thread random-chat side-effects through its switch — keeps the
        // top-level handler focused on chat/contact/group concerns.
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: - public API

    /// Reason the age-gate fired. Drives a one-shot modal in
    /// `RouletteView` — the user either has no age set or they're
    /// under 18. Server is the source of truth (returned via 403
    /// detail code on `/random/queue`); iOS just decodes + surfaces.
    enum AgeGateReason: Equatable {
        /// User profile has no `age` set. CTA: open profile, set age.
        case ageRequired
        /// User's profile age is below 18. Stranger Mode is 18+ only.
        case under18
    }

    /// Set by `startQueue` / `skip` when the server rejects with the
    /// age-gate 403. RouletteView observes this and shows a modal;
    /// `acknowledgeAgeGate()` clears it.
    @Published var ageGateBlock: AgeGateReason?

    /// Opt in to matching. Server returns immediately if somebody else is
    /// already waiting; otherwise we sit in `.queueing` until a `random_match`
    /// WS event lands.
    func startQueue() async {
        // Allow re-queueing from .idle or .ended (the user just saw the
        // "stranger left" hint and tapped Start again). Block from .queueing
        // and .matched so re-taps don't fire a second POST.
        switch state {
        case .queueing, .matched: return
        case .idle, .ended: break
        }
        state = .queueing
        do {
            let out: QueueResponse = try await APIClient.shared.request("POST", "/random/queue")
            applyQueueResponse(out)
        } catch APIError.http(403, let body) {
            // Age-gate path. Server returns 403 with detail.code =
            // "age_required" or "under_18". Roll back to idle so the
            // entry button stays usable; surface the gate reason so
            // the view can show the appropriate modal.
            state = .idle
            ageGateBlock = Self.parseAgeGate(body)
        } catch {
            state = .idle
        }
    }

    /// Cancel queueing OR end the active pair. Server fires `random_end` at
    /// the peer so their UI can fade out cleanly.
    func leave() async {
        // Optimistic local transition — if the server call fails, we'd have
        // already shown the user we left. Background re-sync isn't worth it
        // here since stale server state is harmless (just a stale queue/pair
        // entry that will time out).
        print("[Random] leave() called → state=.idle (caller initiated)")
        let wasMatched = activePeer != nil
        state = .idle
        messages.removeAll()
        lastPeer = nil
        struct LeaveOut: Decodable { let left: Bool }
        do {
            let _: LeaveOut = try await APIClient.shared.request("POST", "/random/leave")
        } catch {
            // If we were matched and the call failed, the peer might still
            // think we're connected — they'll find out via 5-min auto-expire.
            _ = wasMatched
        }
    }

    /// Atomic 'leave + queue' — end the current pair (if any) and look for
    /// a fresh stranger. The big retention button.
    func skip() async {
        state = .queueing
        messages.removeAll()
        do {
            let out: QueueResponse = try await APIClient.shared.request("POST", "/random/skip")
            applyQueueResponse(out)
        } catch APIError.http(403, let body) {
            // Same age-gate handling as startQueue. Skip is functionally
            // a re-queue server-side; the gate fires on both endpoints.
            state = .idle
            ageGateBlock = Self.parseAgeGate(body)
        } catch {
            state = .idle
        }
    }

    /// Caller signals the age-gate modal has been dismissed.
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

    /// Append a freshly-sent or freshly-received message to the active session.
    /// No-op if we're not currently matched (envelope arrived after end).
    func append(_ message: Message) {
        guard activePeer != nil else { return }
        messages.append(message)
    }

    /// Update the local delivery state of an outbound message we just sent.
    func updateState(messageID id: UUID, to state: DeliveryState) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var msg = messages[idx]
        msg.deliveryState = state
        messages[idx] = msg
    }

    /// Drop a message by id. Used by both:
    ///   - delete-for-me (local only — caller already converted
    ///     the user action to this) so the row vanishes from the
    ///     local buffer
    ///   - delete-for-everyone (after sending the envelope) so the
    ///     sender's UI mirrors the receiver's bubble removal
    func deleteMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    /// Apply a reaction toggle from us or the peer. `asset` is the
    /// sticker name; nil clears the reactor's pick. Mirrors the
    /// `MessageStore.applyReaction` shape so the rendering code in
    /// `MessageRow` doesn't have to branch on thread type.
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

    /// Stamp a freshly-uploaded media id onto the local message after
    /// `MediaService.upload` returns. Mirrors `MessageStore.updateMediaID`
    /// for the in-memory random-chat thread. Caller passes the
    /// "<mediaID>|<key>" combined token the photo/video bubble
    /// consumes when fetching+decrypting the blob.
    func updateMediaID(messageID id: UUID, mediaID combined: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let msg = messages[idx]
        // Message has `let mediaID: String?` so we rebuild the row
        // with the combined token. Other fields are copied as-is.
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

    /// Reset all in-memory state. Called from `AppState.burnAccount` so a
    /// freshly-burned identity doesn't inherit a stale match from before.
    func wipe() {
        state = .idle
        messages.removeAll()
        addRequestSent = false
        lastPeer = nil
    }

    /// Manually dismiss the post-session chat surface and return to
    /// the entry screen. Called when the user taps "Close" in the
    /// ended-state banner.
    func clearEnded() {
        if case .ended = state {
            state = .idle
            lastPeer = nil
        }
    }

    /// Send a contact-add request to the active stranger. The server's
    /// `/contacts/request` endpoint already handles the magic case where
    /// both sides have requested each other (auto-accepts and creates the
    /// mutual Contact rows), so we don't need any session-aware logic here.
    /// The "did the peer also tap Add?" outcome surfaces via the regular
    /// `contact_response` WS event → `ContactService.refresh()`.
    func requestAddPeer() async {
        guard let peer = activePeer, !addRequestSent else { return }
        addRequestSent = true
        do {
            try await ContactService.shared.sendAddRequest(to: peer.uin)
        } catch {
            // Roll back the optimistic flag so the user can retry.
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
            // Stash the matched peer so RouletteView can keep
            // rendering the chat surface in `.ended` state. The
            // user gets a "session ended" banner over the
            // last-known messages instead of being yanked to the
            // idle screen mid-typing.
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
            // WS event will flip us to .matched when somebody else queues.
            state = .queueing
        } else {
            state = .idle
        }
    }

    // MARK: - wire types

    private struct QueueResponse: Decodable {
        let status: String  // "queued" | "matched"
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
