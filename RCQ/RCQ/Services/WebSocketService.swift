import Combine
import Foundation

/// Real-time channel. Emits typed events for the rest of the app via the `events`
/// publisher. Reconnects with naive fixed delay (handled by AppState). Backed by
/// URLSessionWebSocketTask.
@MainActor
final class WebSocketService: ObservableObject {
    static let shared = WebSocketService()

    enum Event {
        case opened
        case closed
        case presence(uin: Int, status: UserStatus, statusMessage: String?)
        case envelope(envelope: EnvelopePacket)
        case typing(fromUIN: Int, active: Bool)
        case contactRequest(id: Int, fromUIN: Int, nickname: String)
        case contactResponse(requestID: Int, accepted: Bool, peerUIN: Int)
        case groupChanged(group: RCQGroup)
        case groupDeleted(groupID: Int)
        case randomMatch(peer: RandomPeer)
        case randomEnd(pairID: String, reason: String)
        case hoodMessage(message: HoodMessage)
        case hoodCount(bucketID: String, count: Int)
        case hoodDelete(bucketID: String, messageID: Int)
        case hoodReaction(bucketID: String, messageID: Int, reactions: [String: String])
        // Call-signalling events. SDP travels as raw text (line-broken,
        // huge-ish — couple of KB), ICE candidate as JSON. Both are carried
        // on the wire as plain strings; CallService unpacks them into
        // WebRTCManager's expected formats.
        case callOffer(fromUIN: Int, nickname: String, callID: String, media: CallMedia, sdp: String)
        case callAnswer(fromUIN: Int, callID: String, sdp: String)
        case callIce(fromUIN: Int, callID: String, candidateJSON: String)
        case callEnd(fromUIN: Int, callID: String, reason: String)
        // Mid-call audio→video upgrade. `callRenegotiate` ships the
        // caller's new offer with an extra video m-line; the callee
        // replies with `callRenegotiateAnswer` (accepted, new SDP) or
        // `callRenegotiateDecline` (rejected, caller rolls back its
        // local video track).
        case callRenegotiate(fromUIN: Int, callID: String, sdp: String)
        case callRenegotiateAnswer(fromUIN: Int, callID: String, sdp: String)
        case callRenegotiateDecline(fromUIN: Int, callID: String)
        // Audio Rooms — Discord-style persistent voice rooms. Server
        // is a dumb relay for mesh signalling (`roomOffer/Answer/Ice`)
        // plus an in-memory presence tracker that pushes roster +
        // join/leave deltas. `roomKicked` fires when the owner deletes
        // the room out from under us; `roomDeleted` is the home-screen
        // list update for that same event.
        case roomEnterRejected(roomID: Int, reason: String)
        case roomRoster(roomID: Int, members: [(uin: Int, nickname: String, equippedPet: EquippedPet?, mutedByOwner: Bool)], ownerOnlySpeaking: Bool)
        case roomMemberEntered(roomID: Int, uin: Int, nickname: String, equippedPet: EquippedPet?, mutedByOwner: Bool)
        case roomMemberLeft(roomID: Int, uin: Int)
        case roomOffer(roomID: Int, fromUIN: Int, sdp: String)
        case roomAnswer(roomID: Int, fromUIN: Int, sdp: String)
        case roomIce(roomID: Int, fromUIN: Int, candidateJSON: String)
        case roomSpeaking(roomID: Int, uin: Int, speaking: Bool)
        case roomKicked(roomID: Int, reason: String)
        case roomDeleted(roomID: Int)
        /// Owner toggled per-member mute on a room participant. Goes
        /// to every subscriber so all tiles repaint the badge; the
        /// muted user's client also honors by flipping its own mic.
        case roomMemberMuted(roomID: Int, uin: Int, mutedByOwner: Bool)
        /// Owner toggled the room into / out of "only owner can
        /// speak" mode. Non-owner clients auto-mute mic on enable,
        /// stop blocking the toolbar mic on disable.
        case roomOwnerOnlyChanged(roomID: Int, enabled: Bool)
        /// Owner-initiated kick removed THIS user from the room's
        /// subscription list (the room itself stays alive for everyone
        /// else). Triggers home-list removal — separate event from
        /// `roomDeleted` because the semantic is different ("you were
        /// kicked" vs "the room is gone").
        case roomMembershipRevoked(roomID: Int)
        /// Owner rotated the room's join key. All current subscribers
        /// receive the new key so their cached `AudioRoom.joinKey`
        /// updates without a refresh.
        case roomKeyRotated(roomID: Int, newKey: String)
        /// Owner renamed the room. Fanned to every subscriber so
        /// home-screen lists + the active room view update in
        /// lockstep without a refetch.
        case roomRenamed(roomID: Int, name: String)
        // Premium-UIN auctions. Server runs one auction at a time;
        // events fan out to every connected client so the live UI in
        // the auction surface ticks in lockstep with the bidding.
        case uinAuctionStarted(auction: UinAuction)
        case uinAuctionBid(auctionID: Int, amount: Int, bidderUIN: Int, bidderNickname: String, highBid: Int, highBidderUIN: Int, endsAt: Date, extended: Bool)
        case uinAuctionEnded(auctionID: Int, uin: Int, tier: String, winnerUIN: Int?, winningBid: Int)
        case uinAuctionOutbid(auctionID: Int, uin: Int, refund: Int, newHighBid: Int)
        // Lootbox / trade lifecycle. Items system runs over plain
        // REST for state changes; WS is only used to nudge the
        // recipient (and, on accept, both sides) so their UIs
        // refresh immediately. Offline users see the change on next
        // refreshIncoming / refreshInventory.
        case tradeReceived(trade: Trade)
        case tradeAccepted(trade: Trade)
        case tradeDeclined(tradeID: String)
        case tradeCancelled(tradeID: String)
        // Stories — fan-out nudges so a contact's freshly-posted
        // story appears in the feed without requiring a foreground
        // refresh. The server pushes these to every UIN that has the
        // poster in their contacts list.
        case storyPosted(storyID: String, ownerUIN: Int?)
        case storyDeleted(storyID: String, ownerUIN: Int?)
        /// Server side: a buyer paid for one of our marketplace
        /// listings. Carries the resolved `ListingOut` snapshot
        /// (status="sold", sold_to_uin set, resolved_at populated)
        /// so the iOS client can update "My listings" + the wallet
        /// without a follow-up refresh.
        case marketplaceListingSold(listing: MarketplaceListing)
        /// Fired to the SELLER of a UIN listing the moment a buyer
        /// completes the atomic purchase. Mirror of
        /// `marketplaceListingSold` for the parallel UIN-marketplace
        /// surface — drops the row from "My UIN listings" + credits
        /// the wallet without polling.
        case uinMarketplaceListingSold(listing: UinMarketplaceListing)
        // Crash game lifecycle. Single forever-running round-loop
        // on the server fans these out to ALL connected clients
        // (closed-beta scale; see backend's `connection_manager.broadcast_all`).
        // CrashService subscribes to this stream same as
        // RandomChatService / TradesService.
        case crashRoundBetting(roundID: String, seedHash: String, bettingSeconds: Double)
        case crashRoundRunning(roundID: String, crashInSecondsHint: Double)
        case crashRoundEnd(roundID: String, crashPoint: Double, seed: String, cashouts: [CrashCashoutEvent])
        case crashCashout(roundID: String, uin: Int, nickname: String?, multiplier: Double, payout: Int)
        case crashBetPlaced(roundID: String, uin: Int, nickname: String?, amount: Int, betsCount: Int)
        /// Server pushes this when the account this WS is
        /// authenticated as got burned — possibly from a different
        /// device. Listener is `AppState`, which mirrors the local
        /// burn flow: wipe identity + drop the WebSocket. UI
        /// naturally returns to OnboardingView via the
        /// AuthService.ownUIN binding.
        case accountBurned
    }

    struct EnvelopePacket {
        let type: String        // "message" | "delete" | "system" | "read" | "reaction" | "bounce" | "visit"
        let payload: String
        let serverTime: Date
        let offline: Bool
        let groupID: Int?       // nil for 1:1, set for group fan-out
    }

    @Published private(set) var isConnected: Bool = false
    let events = PassthroughSubject<Event, Never>()

    private var task: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    private var reconnectAttempt = 0
    private var pingTimer: Timer?

    private init() {}

    func connect(uin: Int, token: String, baseURL: URL) {
        disconnect()
        var comp = URLComponents(url: baseURL.appendingPathComponent("/ws/\(uin)"), resolvingAgainstBaseURL: false)!
        if comp.scheme == "http" { comp.scheme = "ws" }
        if comp.scheme == "https" { comp.scheme = "wss" }
        comp.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comp.url else { return }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        isConnected = true
        events.send(.opened)
        startPingTimer()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
        pingTimer?.invalidate()
        pingTimer = nil
    }

    func sendTyping(to uin: Int, active: Bool) {
        send(["type": "typing", "to_uin": uin, "active": active])
    }

    /// Mark this connection as actively viewing Hood Chat for the
    /// given bucket. Server keeps a per-bucket set of subscribers
    /// (used to drive both the toolbar count badge and the fan-out
    /// recipient list for `hood_message`/`hood_delete`/
    /// `hood_reaction`), and broadcasts a `hood_count` event back
    /// to every viewer when the set changes.
    func subscribeHood(bucket: String) {
        send(["type": "hood_subscribe", "bucket": bucket])
    }

    func unsubscribeHood() {
        send(["type": "hood_unsubscribe"])
    }

    /// Send a call-signalling message (offer / answer / ICE / end) to the
    /// peer. Backend acts as a dumb relay — it stamps `from_uin` and forwards.
    /// `extras` carries SDP / ICE candidate / media kind / hangup reason as
    /// applicable; unknown keys are dropped server-side.
    func sendCallSignal(type: String, toUIN: Int, callID: String, extras: [String: Any] = [:]) {
        var payload: [String: Any] = ["type": type, "to_uin": toUIN, "call_id": callID]
        for (k, v) in extras { payload[k] = v }
        send(payload)
    }

    /// Audio Rooms — entry / exit. Server moves us in/out of the in-memory
    /// roster and fans out `room_member_entered` / `room_member_left` so
    /// the rest of the room can mint mesh peer connections to us (or tear
    /// theirs down on exit).
    func sendRoomEnter(roomID: Int) {
        send(["type": "room_enter", "room_id": roomID])
    }
    func sendRoomLeave(roomID: Int) {
        send(["type": "room_leave", "room_id": roomID])
    }
    /// Mesh signalling. `to_uin` must be another current member of the
    /// room or the server drops the message silently — both endpoints
    /// are validated as co-tenants before relay.
    func sendRoomSignal(type: String, roomID: Int, toUIN: Int, extras: [String: Any] = [:]) {
        var payload: [String: Any] = ["type": type, "room_id": roomID, "to_uin": toUIN]
        for (k, v) in extras { payload[k] = v }
        send(payload)
    }
    /// VAD-driven "I am talking now / I stopped" indicator. Pure UX —
    /// drives the speaking ring on remote avatars in the room view.
    func sendRoomSpeaking(roomID: Int, speaking: Bool) {
        send(["type": "room_speaking", "room_id": roomID, "speaking": speaking])
    }

    private func send(_ obj: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { _ in }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            // Hop to the main actor — `send` is main-isolated (the
            // class is `@MainActor`); the Timer's underlying RunLoop
            // callback is nonisolated, so the direct call from inside
            // the closure tripped the strict-concurrency warning even
            // though we always end up on main at runtime.
            Task { @MainActor in self?.send(["type": "ping"]) }
        }
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.handleDisconnect()
                case .success(let msg):
                    self.handle(msg)
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data
        switch msg {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = dict["type"] as? String
        else { return }

        switch type {
        case "account_burned":
            // Backend fanned this out before the row delete, so the
            // current WS will close right after with code 4401/4403
            // (token now invalid). AppState handles the cleanup so
            // the UI swaps to onboarding without waiting for the
            // disconnect itself.
            events.send(.accountBurned)

        case "presence":
            guard let uin = dict["uin"] as? Int,
                  let statusStr = dict["status"] as? String,
                  let status = UserStatus(rawValue: statusStr) else { return }
            events.send(.presence(uin: uin, status: status, statusMessage: dict["status_message"] as? String))

        case "typing":
            guard let from = dict["from_uin"] as? Int else { return }
            events.send(.typing(fromUIN: from, active: dict["active"] as? Bool ?? true))

        case "contact_request":
            guard let id = dict["request_id"] as? Int,
                  let from = dict["from_uin"] as? Int,
                  let nick = dict["from_nickname"] as? String else { return }
            events.send(.contactRequest(id: id, fromUIN: from, nickname: nick))

        case "contact_response":
            guard let id = dict["request_id"] as? Int,
                  let accepted = dict["accepted"] as? Bool,
                  let peer = dict["to_uin"] as? Int else { return }
            events.send(.contactResponse(requestID: id, accepted: accepted, peerUIN: peer))

        case "group_created", "group_membership_changed":
            guard let groupDict = dict["group"] as? [String: Any],
                  let groupData = try? JSONSerialization.data(withJSONObject: groupDict),
                  let group = decodeGroup(groupData) else { return }
            events.send(.groupChanged(group: group))

        case "group_deleted":
            guard let id = dict["group_id"] as? Int else { return }
            events.send(.groupDeleted(groupID: id))

        case "random_match":
            guard let pairID = dict["pair_id"] as? String,
                  let peer = dict["peer"] as? [String: Any],
                  let uin = peer["uin"] as? Int,
                  let nickname = peer["nickname"] as? String,
                  let identityKey = peer["identity_key"] as? String,
                  let signingKey = peer["signing_key"] as? String,
                  let expStr = dict["expires_at"] as? String,
                  let expiresAt = parseISO(expStr) else { return }
            events.send(.randomMatch(peer: RandomPeer(
                pairID: pairID, uin: uin, nickname: nickname,
                identityKey: identityKey, signingKey: signingKey, expiresAt: expiresAt
            )))

        case "random_end":
            guard let pairID = dict["pair_id"] as? String else { return }
            let reason = (dict["reason"] as? String) ?? "ended"
            events.send(.randomEnd(pairID: pairID, reason: reason))

        case "hood_message":
            // Anonymous Hood Chat fan-out. Server pushes the same
            // payload to every checked-in UIN in the bucket; the
            // sender's own client picks it up the same way the
            // recipients do, so HoodChatService doesn't have to
            // optimistic-append.
            guard let msgDict = dict["message"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: msgDict),
                  let parsed = decodeHoodMessage(data) else { return }
            events.send(.hoodMessage(message: parsed))
            if let count = dict["bucket_count"] as? Int {
                events.send(.hoodCount(bucketID: parsed.bucketID, count: count))
            }

        case "hood_delete":
            guard let bucketID = dict["bucket_id"] as? String,
                  let messageID = dict["message_id"] as? Int else { return }
            events.send(.hoodDelete(bucketID: bucketID, messageID: messageID))

        case "hood_reaction":
            guard let bucketID = dict["bucket_id"] as? String,
                  let messageID = dict["message_id"] as? Int,
                  let reactions = dict["reactions"] as? [String: String] else { return }
            events.send(.hoodReaction(bucketID: bucketID, messageID: messageID, reactions: reactions))

        case "call_offer":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let media = CallMedia(rawValue: (dict["media"] as? String) ?? "video") ?? .video
            let sdp = (dict["sdp"] as? String) ?? ""
            // The caller's nickname doesn't ride on the wire — fall back to UIN
            // string and let CallService swap it with our local Contact name.
            events.send(.callOffer(
                fromUIN: from, nickname: String(from), callID: callID, media: media, sdp: sdp
            ))

        case "call_answer":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let sdp = (dict["sdp"] as? String) ?? ""
            events.send(.callAnswer(fromUIN: from, callID: callID, sdp: sdp))

        case "call_ice":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            // The candidate ships as a JSON string in `candidate`; we keep it
            // opaque at this layer and hand it to WebRTC verbatim later.
            let cand = (dict["candidate"] as? String) ?? ""
            events.send(.callIce(fromUIN: from, callID: callID, candidateJSON: cand))

        case "call_end":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let reason = (dict["reason"] as? String) ?? "ended"
            events.send(.callEnd(fromUIN: from, callID: callID, reason: reason))

        case "call_renegotiate":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let sdp = (dict["sdp"] as? String) ?? ""
            events.send(.callRenegotiate(fromUIN: from, callID: callID, sdp: sdp))

        case "call_renegotiate_answer":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let sdp = (dict["sdp"] as? String) ?? ""
            events.send(.callRenegotiateAnswer(fromUIN: from, callID: callID, sdp: sdp))

        case "call_renegotiate_decline":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            events.send(.callRenegotiateDecline(fromUIN: from, callID: callID))

        case "room_enter_rejected":
            guard let roomID = dict["room_id"] as? Int else { return }
            let reason = (dict["reason"] as? String) ?? "rejected"
            events.send(.roomEnterRejected(roomID: roomID, reason: reason))

        case "room_roster":
            guard let roomID = dict["room_id"] as? Int,
                  let raw = dict["members"] as? [[String: Any]] else { return }
            let members: [(uin: Int, nickname: String, equippedPet: EquippedPet?, mutedByOwner: Bool)] = raw.compactMap { d in
                guard let u = d["uin"] as? Int else { return nil }
                let nick = (d["nickname"] as? String) ?? String(u)
                let pet = Self.decodeEquippedPet(d["equipped_pet"])
                let muted = (d["muted_by_owner"] as? Bool) ?? false
                return (uin: u, nickname: nick, equippedPet: pet, mutedByOwner: muted)
            }
            let ownerOnly = (dict["owner_only_speaking"] as? Bool) ?? false
            events.send(.roomRoster(roomID: roomID, members: members, ownerOnlySpeaking: ownerOnly))

        case "room_member_entered":
            guard let roomID = dict["room_id"] as? Int,
                  let m = dict["member"] as? [String: Any],
                  let uin = m["uin"] as? Int else { return }
            let nick = (m["nickname"] as? String) ?? String(uin)
            let pet = Self.decodeEquippedPet(m["equipped_pet"])
            let muted = (m["muted_by_owner"] as? Bool) ?? false
            events.send(.roomMemberEntered(roomID: roomID, uin: uin, nickname: nick, equippedPet: pet, mutedByOwner: muted))

        case "room_member_left":
            guard let roomID = dict["room_id"] as? Int,
                  let uin = dict["uin"] as? Int else { return }
            events.send(.roomMemberLeft(roomID: roomID, uin: uin))

        case "room_offer":
            guard let roomID = dict["room_id"] as? Int,
                  let from = dict["from_uin"] as? Int else { return }
            let sdp = (dict["sdp"] as? String) ?? ""
            events.send(.roomOffer(roomID: roomID, fromUIN: from, sdp: sdp))

        case "room_answer":
            guard let roomID = dict["room_id"] as? Int,
                  let from = dict["from_uin"] as? Int else { return }
            let sdp = (dict["sdp"] as? String) ?? ""
            events.send(.roomAnswer(roomID: roomID, fromUIN: from, sdp: sdp))

        case "room_ice":
            guard let roomID = dict["room_id"] as? Int,
                  let from = dict["from_uin"] as? Int else { return }
            let cand = (dict["candidate"] as? String) ?? ""
            events.send(.roomIce(roomID: roomID, fromUIN: from, candidateJSON: cand))

        case "room_speaking":
            guard let roomID = dict["room_id"] as? Int,
                  let uin = dict["uin"] as? Int else { return }
            events.send(.roomSpeaking(roomID: roomID, uin: uin, speaking: (dict["speaking"] as? Bool) ?? false))

        case "audio_room_kicked":
            guard let roomID = dict["room_id"] as? Int else { return }
            events.send(.roomKicked(roomID: roomID, reason: (dict["reason"] as? String) ?? "deleted"))

        case "audio_room_deleted":
            guard let roomID = dict["room_id"] as? Int else { return }
            events.send(.roomDeleted(roomID: roomID))

        case "audio_room_membership_revoked":
            guard let roomID = dict["room_id"] as? Int else { return }
            events.send(.roomMembershipRevoked(roomID: roomID))

        case "audio_room_key_rotated":
            guard let roomID = dict["room_id"] as? Int,
                  let key = dict["new_key"] as? String else { return }
            events.send(.roomKeyRotated(roomID: roomID, newKey: key))

        case "audio_room_member_muted":
            guard let roomID = dict["room_id"] as? Int,
                  let uin = dict["uin"] as? Int else { return }
            let muted = (dict["muted_by_owner"] as? Bool) ?? false
            events.send(.roomMemberMuted(roomID: roomID, uin: uin, mutedByOwner: muted))

        case "audio_room_owner_only_changed":
            guard let roomID = dict["room_id"] as? Int else { return }
            let enabled = (dict["enabled"] as? Bool) ?? false
            events.send(.roomOwnerOnlyChanged(roomID: roomID, enabled: enabled))

        case "audio_room_renamed":
            guard let roomID = dict["room_id"] as? Int,
                  let name = dict["name"] as? String else { return }
            events.send(.roomRenamed(roomID: roomID, name: name))

        case "uin_auction_started":
            guard let raw = dict["auction"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let auction = try? Self.dateLenientDecoder.decode(UinAuction.self, from: data)
            else { return }
            events.send(.uinAuctionStarted(auction: auction))

        case "uin_auction_bid":
            guard let auctionID = dict["auction_id"] as? Int,
                  let amount = dict["amount"] as? Int,
                  let bidderUIN = dict["bidder_uin"] as? Int,
                  let highBid = dict["high_bid"] as? Int,
                  let highBidderUIN = dict["high_bidder_uin"] as? Int,
                  let endsAtStr = dict["ends_at"] as? String,
                  let endsAt = parseISO(endsAtStr) else { return }
            let nick = (dict["bidder_nickname"] as? String) ?? String(bidderUIN)
            let extended = (dict["extended"] as? Bool) ?? false
            events.send(.uinAuctionBid(
                auctionID: auctionID, amount: amount, bidderUIN: bidderUIN,
                bidderNickname: nick, highBid: highBid, highBidderUIN: highBidderUIN,
                endsAt: endsAt, extended: extended,
            ))

        case "uin_auction_ended":
            guard let auctionID = dict["auction_id"] as? Int,
                  let uin = dict["uin"] as? Int,
                  let tier = dict["tier"] as? String else { return }
            let winner = dict["winner_uin"] as? Int
            let winningBid = (dict["winning_bid"] as? Int) ?? 0
            events.send(.uinAuctionEnded(
                auctionID: auctionID, uin: uin, tier: tier,
                winnerUIN: winner, winningBid: winningBid,
            ))

        case "uin_auction_outbid":
            guard let auctionID = dict["auction_id"] as? Int,
                  let uin = dict["uin"] as? Int,
                  let refund = dict["refund"] as? Int,
                  let newHigh = dict["new_high_bid"] as? Int else { return }
            events.send(.uinAuctionOutbid(
                auctionID: auctionID, uin: uin, refund: refund, newHighBid: newHigh,
            ))

        case "trade_received", "trade_accepted":
            // Server pushes the full trade payload (after `_hydrate`)
            // so we can update the local list without a follow-up
            // GET. The trade decoder uses the project-wide lenient
            // date parser via APIClient.
            guard let tradeDict = dict["trade"] as? [String: Any],
                  let raw = try? JSONSerialization.data(withJSONObject: tradeDict),
                  let trade = decodeTrade(raw)
            else { return }
            if type == "trade_received" {
                events.send(.tradeReceived(trade: trade))
            } else {
                events.send(.tradeAccepted(trade: trade))
            }

        case "story_posted":
            guard let id = dict["story_id"] as? String else { return }
            let owner = dict["owner_uin"] as? Int
            events.send(.storyPosted(storyID: id, ownerUIN: owner))

        case "story_deleted":
            guard let id = dict["story_id"] as? String else { return }
            let owner = dict["owner_uin"] as? Int
            events.send(.storyDeleted(storyID: id, ownerUIN: owner))

        case "marketplace_listing_sold":
            // Server stuffs the full ListingOut payload under "listing".
            // We re-encode → decode to reuse the model's CodingKeys
            // mapping (snake_case → Swift) without hand-rolling each
            // field here.
            guard let raw = dict["listing"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: raw) else {
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let listing = try? decoder.decode(MarketplaceListing.self, from: data) else {
                return
            }
            events.send(.marketplaceListingSold(listing: listing))

        case "uin_marketplace_listing_sold":
            // Same shape as item-listing-sold: a `listing` dict carrying
            // the full UinListingOut snapshot. Re-encode → decode for
            // CodingKeys reuse.
            guard let raw = dict["listing"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: raw) else {
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let listing = try? decoder.decode(UinMarketplaceListing.self, from: data) else {
                return
            }
            events.send(.uinMarketplaceListingSold(listing: listing))

        case "trade_declined":
            guard let id = dict["trade_id"] as? String else { return }
            events.send(.tradeDeclined(tradeID: id))

        case "trade_cancelled":
            guard let id = dict["trade_id"] as? String else { return }
            events.send(.tradeCancelled(tradeID: id))

        case "crash_round_betting":
            guard let roundID = dict["round_id"] as? String,
                  let seedHash = dict["seed_hash"] as? String else { return }
            let bettingSeconds = (dict["betting_seconds"] as? Double) ?? 8.0
            events.send(.crashRoundBetting(roundID: roundID, seedHash: seedHash, bettingSeconds: bettingSeconds))

        case "crash_round_running":
            guard let roundID = dict["round_id"] as? String else { return }
            let hint = (dict["crash_in_seconds_hint"] as? Double) ?? 0.0
            events.send(.crashRoundRunning(roundID: roundID, crashInSecondsHint: hint))

        case "crash_round_end":
            guard let roundID = dict["round_id"] as? String,
                  let crashPoint = dict["crash_point"] as? Double,
                  let seed = dict["seed"] as? String else { return }
            let raw = (dict["cashouts"] as? [[String: Any]]) ?? []
            let parsed: [CrashCashoutEvent] = raw.compactMap { entry in
                guard let uin = entry["uin"] as? Int,
                      let mult = entry["multiplier"] as? Double,
                      let payout = entry["payout"] as? Int else { return nil }
                let nick = entry["nickname"] as? String
                return CrashCashoutEvent(uin: uin, nickname: nick, multiplier: mult, payout: payout)
            }
            events.send(.crashRoundEnd(roundID: roundID, crashPoint: crashPoint, seed: seed, cashouts: parsed))

        case "crash_cashout":
            guard let roundID = dict["round_id"] as? String,
                  let uin = dict["uin"] as? Int,
                  let mult = dict["multiplier"] as? Double,
                  let payout = dict["payout"] as? Int else { return }
            let nick = dict["nickname"] as? String
            events.send(.crashCashout(roundID: roundID, uin: uin, nickname: nick, multiplier: mult, payout: payout))

        case "crash_bet_placed":
            guard let roundID = dict["round_id"] as? String,
                  let uin = dict["uin"] as? Int,
                  let amount = dict["amount"] as? Int else { return }
            let count = (dict["bets_count"] as? Int) ?? 0
            let nick = dict["nickname"] as? String
            events.send(.crashBetPlaced(roundID: roundID, uin: uin, nickname: nick, amount: amount, betsCount: count))

        case "pong":
            break

        case "message", "delete", "system", "read", "reaction", "bounce", "visit", "edit":
            guard let payload = dict["payload"] as? String else { return }
            let serverTime = (dict["server_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            let offline = dict["offline"] as? Bool ?? false
            let groupID = dict["group_id"] as? Int
            events.send(.envelope(envelope: EnvelopePacket(
                type: type, payload: payload, serverTime: serverTime, offline: offline, groupID: groupID
            )))

        default:
            break
        }
    }

    /// Lenient ISO-8601 parser used for `random_match.expires_at`. Reuses the
    /// project-wide multi-format date logic so microsecond-precision timestamps
    /// from FastAPI/Pydantic don't get rejected.
    /// JSON decoder used to parse embedded auction snapshots inside
    /// WS payloads. Same lenient ISO-8601 strategy the APIClient uses
    /// — accepts both with-fractional-seconds and plain Internet-time.
    private static let dateLenientDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFrac.date(from: s) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "bad ISO-8601 date: \(s)"
            )
        }
        return d
    }()

    private func parseISO(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        return nil
    }

    private func decodeGroup(_ data: Data) -> RCQGroup? {
        // Reuse APIClient's lenient date parser — `created_at` from pydantic v2
        // carries microsecond precision, which the strict ISO8601 strategy
        // rejects. That's exactly what was silently swallowing inbound group
        // events, so the second user never saw they'd been added.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(APIClient.parseDateForExternal)
        return try? decoder.decode(RCQGroup.self, from: data)
    }

    private func decodeHoodMessage(_ data: Data) -> HoodMessage? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(APIClient.parseDateForExternal)
        return try? decoder.decode(HoodMessage.self, from: data)
    }

    private func decodeTrade(_ data: Data) -> Trade? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(APIClient.parseDateForExternal)
        return try? decoder.decode(Trade.self, from: data)
    }

    /// Decode the loose `equipped_pet` dict that comes inline on
    /// roster / member-entered events. Returns nil for missing /
    /// malformed / explicit-null values — callers treat that as
    /// "no pet equipped" without complaint.
    fileprivate static func decodeEquippedPet(_ raw: Any?) -> EquippedPet? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(EquippedPet.self, from: data)
    }

    private func handleDisconnect() {
        isConnected = false
        events.send(.closed)
        task = nil
        pingTimer?.invalidate()
    }
}
