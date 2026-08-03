import Combine
import Foundation

/// Real-time channel emitting typed events. Reconnect handled by AppState.
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
        case contactRemoved(peerUIN: Int)
        case groupChanged(group: RCQGroup)
        case groupDeleted(groupID: Int)
        case randomMatch(peer: RandomPeer)
        case randomEnd(pairID: String, reason: String)
        case callOffer(fromUIN: Int, nickname: String, callID: String, media: CallMedia, sdp: String)
        case callAnswer(fromUIN: Int, callID: String, sdp: String)
        case callIce(fromUIN: Int, callID: String, candidateJSON: String)
        case callEnd(fromUIN: Int, callID: String, reason: String)
        case callRenegotiate(fromUIN: Int, callID: String, sdp: String)
        case callRenegotiateAnswer(fromUIN: Int, callID: String, sdp: String)
        case callRenegotiateDecline(fromUIN: Int, callID: String)
        case callIceRestart(fromUIN: Int, callID: String, sdp: String)
        case callIceRestartAnswer(fromUIN: Int, callID: String, sdp: String)
        case roomEnterRejected(roomID: Int, reason: String)
        case roomRoster(roomID: Int, members: [(uin: Int, nickname: String, mutedByOwner: Bool)], ownerOnlySpeaking: Bool)
        case roomMemberEntered(roomID: Int, uin: Int, nickname: String, mutedByOwner: Bool)
        case roomMemberLeft(roomID: Int, uin: Int)
        case roomOffer(roomID: Int, fromUIN: Int, sdp: String)
        case roomAnswer(roomID: Int, fromUIN: Int, sdp: String)
        case roomIce(roomID: Int, fromUIN: Int, candidateJSON: String)
        case roomSpeaking(roomID: Int, uin: Int, speaking: Bool)
        case roomKicked(roomID: Int, reason: String)
        case roomDeleted(roomID: Int)
        case roomMemberMuted(roomID: Int, uin: Int, mutedByOwner: Bool)
        case roomOwnerOnlyChanged(roomID: Int, enabled: Bool)
        case roomMembershipRevoked(roomID: Int)
        case roomKeyRotated(roomID: Int, newKey: String)
        case roomRenamed(roomID: Int, name: String)
        case storyPosted(storyID: String, ownerUIN: Int?)
        case storyDeleted(storyID: String, ownerUIN: Int?)
        case hoodMessage(message: HoodMessage)
        case hoodCount(bucketID: String, count: Int)
        case hoodDelete(bucketID: String, messageID: Int)
        case hoodReaction(bucketID: String, messageID: Int, reactions: [String: String])
        case accountBurned
    }

    struct EnvelopePacket {
        let type: String
        let payload: String
        let serverTime: Date
        let offline: Bool
        let groupID: Int?
    }

    @Published private(set) var isConnected: Bool = false

    /// True only while we have CONFIRMED end-to-end evidence the server is
    /// on the other side of this socket: set on every inbound frame,
    /// cleared on connect (until the first frame arrives) and on any
    /// disconnect. `isConnected` is optimistic — it flips true at
    /// `task.resume()`, before the upgrade handshake even completes —
    /// which suits the internal send/reconnect gating but must not drive
    /// UI: the identity-flower dot would show green while we're dialing a
    /// server that is unreachable (VPN pulled, route blocked). UI reads this.
    @Published private(set) var linkUp: Bool = false

    /// Wall-clock time of the most recent inbound frame (any kind —
    /// pong, presence, envelope...). Drives the staleness watchdog:
    /// if more than `staleThreshold` seconds pass with the socket
    /// notionally "open" but nothing coming in, we treat it as silently
    /// dead and force-reconnect. iOS occasionally suspends a
    /// `URLSessionWebSocketTask` without firing the failure callback —
    /// classic symptom is "messages I send go nowhere, no error".
    ///
    /// Threshold tuning: ping every 25s + 90s threshold = 3 missed
    /// pong rounds before we declare the socket dead. The previous
    /// 50s threshold was too tight — a single slow round-trip (cell
    /// network handoff, brief NAT pause) flapped the watchdog and
    /// disconnected healthy sockets, which downstream propagated as
    /// audio-room participant flicker and contact-presence flicker.
    private var lastFrameAt: Date = .distantPast
    private var staleWatchdog: Timer?
    private static let staleThreshold: TimeInterval = 90
    private static let pingInterval: TimeInterval = 25
    let events = PassthroughSubject<Event, Never>()

    private var task: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    /// Whether the current task rides the local sing-box proxy. A write
    /// through the proxy only proves the loopback hop to sing-box, not the
    /// tunnel behind it, so the watchdog must not count send-success as
    /// liveness there (see `sendPing`).
    private var viaProxy = false
    private var reconnectAttempt = 0
    private var pingTimer: Timer?
    private var pendingReconnect: DispatchWorkItem?
    private var shouldStayConnected: Bool = false
    private var lastUIN: Int?
    private var lastToken: String?
    private var lastBaseURL: URL?
    private var lastServerToken: String?

    private init() {}

    private static func makeSession(proxy: [String: Any]?) -> URLSession {
        guard let proxy else { return .shared }
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = proxy
        return URLSession(configuration: cfg)
    }

    func connect(uin: Int, token: String, baseURL: URL, serverToken: String? = nil) {
        shouldStayConnected = true
        lastUIN = uin
        lastToken = token
        lastBaseURL = baseURL
        lastServerToken = serverToken
        pendingReconnect?.cancel()
        pendingReconnect = nil

        // Tear down any existing task without flipping shouldStayConnected.
        task?.cancel(with: .normalClosure, reason: nil)
        pingTimer?.invalidate()
        pingTimer = nil

        var comp = URLComponents(url: baseURL.appendingPathComponent("/ws/\(uin)"), resolvingAgainstBaseURL: false)!
        if comp.scheme == "http" { comp.scheme = "ws" }
        if comp.scheme == "https" { comp.scheme = "wss" }
        comp.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comp.url else { return }

        let proxy = SingBoxTransport.proxyDictionary()
        viaProxy = proxy != nil
        session = Self.makeSession(proxy: proxy)

        // URLRequest-based handshake (vs `webSocketTask(with: url)`) so
        // we can attach the optional masquerade header. When the active
        // account has `serverToken` set, the Caddy frontend gates the
        // upgrade on `X-RCQ-Auth` exactly like every HTTP request —
        // missing/wrong header serves the decoy site and the upgrade
        // fails, exactly what we want against passive scanners.
        var req = URLRequest(url: url)
        if let serverToken {
            req.setValue(serverToken, forHTTPHeaderField: "X-RCQ-Auth")
        }
        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()
        isConnected = true
        linkUp = false
        reconnectAttempt = 0
        lastFrameAt = Date()
        events.send(.opened)
        startPingTimer()
        startStaleWatchdog()
        receiveLoop()
        // Immediate ping: the server's pong is the first inbound frame and
        // confirms the link (flips `linkUp`) within one round-trip instead
        // of waiting a full ping interval. On a dead route the queued send
        // errors out and fails this attempt fast.
        sendPing()
    }

    func disconnect() {
        shouldStayConnected = false
        pendingReconnect?.cancel()
        pendingReconnect = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
        linkUp = false
        pingTimer?.invalidate()
        pingTimer = nil
        staleWatchdog?.invalidate()
        staleWatchdog = nil
    }

    /// Force an immediate reconnect using the last connect parameters — e.g.
    /// after the obfuscation transport is toggled, so the socket re-opens
    /// through (or without) the new proxy instead of waiting for a failure.
    /// No-op if we've never connected.
    func reconnectNow() {
        // Never resurrect a deliberately torn-down socket (logout, panic
        // lock) — only redial while we're supposed to be connected.
        guard shouldStayConnected else { return }
        pendingReconnect?.cancel()
        guard let uin = lastUIN, let token = lastToken, let base = lastBaseURL else { return }
        connect(uin: uin, token: token, baseURL: base, serverToken: lastServerToken)
    }

    func pingNow() {
        sendPing()
    }

    /// Ping with liveness-aware completion. A successful outbound write
    /// is decent evidence the socket is alive, so we refresh the
    /// watchdog stamp on send-success — not just on inbound frames.
    ///
    /// Why this matters: for a quiet user the ONLY inbound traffic is
    /// the server's pong replies, and those ride the cross-worker Redis
    /// fanout (connection_manager `ws:fanout`). A dropped/raced pong
    /// leaves `lastFrameAt` stale even though the socket is perfectly
    /// healthy, and the 90s watchdog tears it down → reconnect storm
    /// (observed: a one-contact user reconnecting every ~100s for
    /// hours). Trusting our own successful send kills that false
    /// positive.
    ///
    /// Trade-off: a half-open socket (writes succeed, inbound dead)
    /// would be masked here. That's rare and mostly happens across an
    /// OS background-suspend, which the foreground-resume forced
    /// reconnect now handles independently. A genuinely dead write side
    /// still errors → handleDisconnect below.
    ///
    /// Exception: through the local sing-box proxy a "successful" write
    /// only reached the loopback hop — the tunnel behind it may be dead
    /// (VPN pulled, relay blocked) — so via-proxy sockets count inbound
    /// frames only. A dead tunnel then gets reaped by the watchdog
    /// instead of staying masked as healthy forever.
    private func sendPing() {
        guard let task else { return }
        let issuedTask = task
        task.send(.string("{\"type\":\"ping\"}")) { [weak self] error in
            Task { @MainActor in
                guard let self, self.task === issuedTask else { return }
                if error != nil {
                    self.handleDisconnect()
                } else if !self.viaProxy {
                    self.lastFrameAt = Date()
                }
            }
        }
    }

    private func scheduleReconnect() {
        pendingReconnect?.cancel()
        reconnectAttempt += 1
        // Auto-engage stealth after the WS has failed enough times in
        // a row that the network is clearly hostile to our WSS upgrade
        // — typical for carriers whose DPI lets the plain /health probe
        // through but kills long-lived TLS sockets. The boot-time
        // auto-engage path (in AppState.boot) only checks HTTP reach,
        // so this branch catches the cases where direct HTTP looks
        // fine but the WS layer is blocked. User opt-out
        // (`rcq.singbox.autoDisabled`) still wins.
        if reconnectAttempt == 4
            && !SingBoxTransport.shared.isActive
            && !UserDefaults.standard.bool(forKey: "rcq.singbox.autoDisabled") {
            Task { @MainActor in
                do {
                    try await SingBoxTransport.shared.start()
                    await APIClient.shared.applyTransportProxy()
                    // Trigger an immediate reconnect rather than wait
                    // for the backoff tick — the user has already been
                    // staring at "connecting…" for ~15 s by this point.
                    self.pendingReconnect?.cancel()
                    if let uin = self.lastUIN,
                       let token = self.lastToken,
                       let base = self.lastBaseURL {
                        self.connect(uin: uin, token: token, baseURL: base, serverToken: self.lastServerToken)
                    }
                } catch {
                    // Stealth start failed too — fall through to the
                    // regular backoff. Persisted error surfaces in
                    // ConnectionDiagnostics for the user to see.
                }
            }
        }
        // Exponential backoff capped at 30s: 1, 2, 4, 8, 16, 30, 30, ...
        let exponent = min(reconnectAttempt - 1, 5)
        let delay = min(30.0, pow(2.0, Double(exponent)))
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.shouldStayConnected else { return }
                guard let uin = self.lastUIN,
                      let token = self.lastToken,
                      let baseURL = self.lastBaseURL else { return }
                self.connect(uin: uin, token: token, baseURL: baseURL, serverToken: self.lastServerToken)
            }
        }
        pendingReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func sendTyping(to uin: Int, active: Bool) {
        send(["type": "typing", "to_uin": uin, "active": active])
    }

    func subscribeHood(bucket: String) {
        send(["type": "hood_subscribe", "bucket": bucket])
    }

    func unsubscribeHood() {
        send(["type": "hood_unsubscribe"])
    }

    func sendCallSignal(type: String, toUIN: Int, callID: String, extras: [String: Any] = [:]) {
        // §5d: a signal to a CROSS-ISLAND peer can't ride this socket (their
        // island never sees our WS) — wrap it as Envelope.callSignal, v=1-seal
        // and deposit it to their island instead. Same-island stays WS.
        if let ci = CrossIslandStore.shared.find(uin: toUIN), let host = ci.host {
            // §5d v1-limit fix — BATCH ICE: each trickle candidate was its own
            // sealed deposit = its own NSE banner (~12/call). Micro-batch a
            // burst into ONE `call_ice` envelope (`candidates` JSON-array
            // string). Other signal types flush any pending ICE first so none
            // are stranded behind them. Cross-island only; same-island WS below
            // is untouched.
            if type == "call_ice", let cand = extras["candidate"] as? String {
                ciIceBuffer[callID, default: []].append(cand)
                ciIceFlushWork[callID]?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.flushCrossIslandIce(callID: callID, contact: ci, host: host) }
                ciIceFlushWork[callID] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.ciIceDebounce, execute: work)
                return
            }
            flushCrossIslandIce(callID: callID, contact: ci, host: host)
            CrossIslandSender.depositCallSignal(type: type, callID: callID, extras: extras, contact: ci, host: host)
            return
        }
        var payload: [String: Any] = ["type": type, "to_uin": toUIN, "call_id": callID]
        for (k, v) in extras { payload[k] = v }
        send(payload)
    }

    // Cross-island ICE micro-batch state (keyed by call id), main-actor only.
    private var ciIceBuffer: [String: [String]] = [:]
    private var ciIceFlushWork: [String: DispatchWorkItem] = [:]
    private static let ciIceDebounce: TimeInterval = 0.35

    /// Deposit all buffered cross-island ICE candidates for `callID` as one
    /// sealed `call_ice` envelope (`candidates` = JSON array). No-op when empty.
    private func flushCrossIslandIce(callID: String, contact: Contact, host: String) {
        ciIceFlushWork.removeValue(forKey: callID)?.cancel()
        guard let cands = ciIceBuffer.removeValue(forKey: callID), !cands.isEmpty else { return }
        let arr = (try? JSONSerialization.data(withJSONObject: cands)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        CrossIslandSender.depositCallSignal(type: "call_ice", callID: callID, extras: ["candidates": arr], contact: contact, host: host)
    }

    func sendRoomEnter(roomID: Int) {
        send(["type": "room_enter", "room_id": roomID])
    }
    func sendRoomLeave(roomID: Int) {
        send(["type": "room_leave", "room_id": roomID])
    }
    func sendRoomSignal(type: String, roomID: Int, toUIN: Int, extras: [String: Any] = [:]) {
        var payload: [String: Any] = ["type": type, "room_id": roomID, "to_uin": toUIN]
        for (k, v) in extras { payload[k] = v }
        send(payload)
    }
    func sendRoomSpeaking(roomID: Int, speaking: Bool) {
        send(["type": "room_speaking", "room_id": roomID, "speaking": speaking])
    }

    private func send(_ obj: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        let issuedTask = task
        task.send(.string(str)) { [weak self] error in
            guard error != nil else { return }
            // Ignore send-failures from a task we've since rotated away
            // from. Without this guard, calling connect() while another
            // send was in flight would fire handleDisconnect on the new
            // (healthy) task — the old reconnect storm origin.
            Task { @MainActor in
                guard let self, self.task === issuedTask else { return }
                self.handleDisconnect()
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            // Timer's RunLoop callback is nonisolated; `sendPing` is main-isolated.
            Task { @MainActor in self?.sendPing() }
        }
    }

    /// Watchdog timer that watches `lastFrameAt`. If no inbound frame
    /// (incl. pongs) has arrived for `staleThreshold` seconds we
    /// assume the socket is dead in a way iOS hasn't told us about,
    /// and we tear down + reconnect. Server pings every ~25s, so a
    /// 50s threshold tolerates one missed round.
    private func startStaleWatchdog() {
        staleWatchdog?.invalidate()
        // Check at half the ping interval so we don't sit on a stale
        // socket for nearly a full ping cycle.
        staleWatchdog = Timer.scheduledTimer(
            withTimeInterval: Self.pingInterval / 2,
            repeats: true,
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isConnected else { return }
                let elapsed = Date().timeIntervalSince(self.lastFrameAt)
                if elapsed > Self.staleThreshold {
                    self.handleDisconnect()
                }
            }
        }
    }

    private func receiveLoop() {
        guard let task else { return }
        let issuedTask = task
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                // Ignore the cancellation echo of a task we've since
                // rotated away from. Without this, a connect() rotation
                // mid-flight would have the cancelled task's receive
                // failure call handleDisconnect on the new healthy task.
                guard self.task === issuedTask else { return }
                switch result {
                case .failure:
                    // 4000 = the server superseded this socket: another
                    // connection claimed the same account+device. Redialling
                    // on the normal backoff turns that into a ping-pong when
                    // two installs share a device id — each redial evicts the
                    // other, forever. Wait a while, with jitter so two evicted
                    // peers do not come back in step.
                    self.handleDisconnect(superseded: issuedTask.closeCode.rawValue == 4000)
                case .success(let msg):
                    self.handle(msg)
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        // Any inbound frame proves the socket is alive — refresh the
        // watchdog's "last seen" stamp before we even look at the
        // payload. Pong frames especially: they're the only inbound
        // traffic during a quiet stretch.
        lastFrameAt = Date()
        linkUp = true
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

        case "contact_removed":
            guard let peer = dict["peer_uin"] as? Int else { return }
            events.send(.contactRemoved(peerUIN: peer))

        case "contact_request_cancelled":
            // A request we received was revoked by its sender — refresh so
            // it drops out of our pending list (the row is gone server-side).
            Task { @MainActor in await ContactService.shared.refresh() }

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

        case "call_offer":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let media = CallMedia(rawValue: (dict["media"] as? String) ?? "video") ?? .video
            let sdp = (dict["sdp"] as? String) ?? ""
            // Caller nickname not on the wire; CallService swaps via local Contact.
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

        case "call_ice_restart":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let sdp = (dict["sdp"] as? String) ?? ""
            events.send(.callIceRestart(fromUIN: from, callID: callID, sdp: sdp))

        case "call_ice_restart_answer":
            guard let from = dict["from_uin"] as? Int,
                  let callID = dict["call_id"] as? String else { return }
            let sdp = (dict["sdp"] as? String) ?? ""
            events.send(.callIceRestartAnswer(fromUIN: from, callID: callID, sdp: sdp))

        case "room_enter_rejected":
            guard let roomID = dict["room_id"] as? Int else { return }
            let reason = (dict["reason"] as? String) ?? "rejected"
            events.send(.roomEnterRejected(roomID: roomID, reason: reason))

        case "room_roster":
            guard let roomID = dict["room_id"] as? Int,
                  let raw = dict["members"] as? [[String: Any]] else { return }
            let members: [(uin: Int, nickname: String, mutedByOwner: Bool)] = raw.compactMap { d in
                guard let u = d["uin"] as? Int else { return nil }
                let nick = (d["nickname"] as? String) ?? String(u)
                let muted = (d["muted_by_owner"] as? Bool) ?? false
                return (uin: u, nickname: nick, mutedByOwner: muted)
            }
            let ownerOnly = (dict["owner_only_speaking"] as? Bool) ?? false
            events.send(.roomRoster(roomID: roomID, members: members, ownerOnlySpeaking: ownerOnly))

        case "room_member_entered":
            guard let roomID = dict["room_id"] as? Int,
                  let m = dict["member"] as? [String: Any],
                  let uin = m["uin"] as? Int else { return }
            let nick = (m["nickname"] as? String) ?? String(uin)
            let muted = (m["muted_by_owner"] as? Bool) ?? false
            events.send(.roomMemberEntered(roomID: roomID, uin: uin, nickname: nick, mutedByOwner: muted))

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

        case "story_posted":
            guard let id = dict["story_id"] as? String else { return }
            let owner = dict["owner_uin"] as? Int
            events.send(.storyPosted(storyID: id, ownerUIN: owner))

        case "story_deleted":
            guard let id = dict["story_id"] as? String else { return }
            let owner = dict["owner_uin"] as? Int
            events.send(.storyDeleted(storyID: id, ownerUIN: owner))

        case "hood_message":
            // Payload nests the full HoodMessageOut under `message`; the
            // bucket_count piggyback is decoded as a synthetic hoodCount
            // event so HoodChatService can update the badge without a
            // separate fanout.
            guard let msgDict = dict["message"] as? [String: Any],
                  let msgData = try? JSONSerialization.data(withJSONObject: msgDict),
                  let parsed = try? Self.dateLenientDecoder.decode(HoodMessage.self, from: msgData)
            else { return }
            events.send(.hoodMessage(message: parsed))
            if let count = dict["bucket_count"] as? Int {
                events.send(.hoodCount(bucketID: parsed.bucketID, count: count))
            }

        case "hood_count":
            guard let bucket = dict["bucket_id"] as? String,
                  let count = dict["count"] as? Int else { return }
            events.send(.hoodCount(bucketID: bucket, count: count))

        case "hood_delete":
            guard let bucket = dict["bucket_id"] as? String,
                  let msgID = dict["message_id"] as? Int else { return }
            events.send(.hoodDelete(bucketID: bucket, messageID: msgID))

        case "hood_reaction":
            guard let bucket = dict["bucket_id"] as? String,
                  let msgID = dict["message_id"] as? Int,
                  let reactions = dict["reactions"] as? [String: String] else { return }
            events.send(.hoodReaction(bucketID: bucket, messageID: msgID, reactions: reactions))

        case "pong":
            break

        // Every event name here carries a sealed envelope in `payload`. The
        // server echoes back whatever `envelope_type` the sender declared, so
        // this list has to cover every type any client sends, not just the ones
        // that draw a bubble. It previously stopped at "edit"/"gmsg", which
        // silently dropped the rest on the live socket: a sender-key
        // distribution ("skdm") arriving while the app was open was ignored,
        // so the following group message could not be decrypted until the next
        // reconnect drained the offline queue — and we send skdm ourselves
        // (MessageService), so the gap was self-inflicted. Same for a carbon of
        // your own message from another device, a screenshot notice, a shared
        // relay and a gossiped island record.
        case "message", "delete", "system", "read", "reaction", "bounce", "visit", "edit", "gmsg",
             "skdm", "sknack", "carbon", "secscreen", "relay_share", "homerec":
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

    /// Accepts both fractional-second and plain Internet-time ISO-8601.
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
        // Lenient parser: pydantic v2 `created_at` carries microseconds.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(APIClient.parseDateForExternal)
        return try? decoder.decode(RCQGroup.self, from: data)
    }

    private func handleDisconnect(superseded: Bool = false) {
        // Idempotent — repeated calls from the multiple disconnect
        // signal sources (receive failure, send failure, watchdog)
        // shouldn't queue multiple reconnects.
        guard isConnected || task != nil else { return }
        isConnected = false
        linkUp = false
        events.send(.closed)
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        pingTimer?.invalidate()
        pingTimer = nil
        staleWatchdog?.invalidate()
        staleWatchdog = nil
        if shouldStayConnected {
            if superseded {
                scheduleSupersededReconnect()
            } else {
                scheduleReconnect()
            }
        }
    }

    /// A superseded close means somebody else is holding this account+device
    /// right now, so coming back in a second only takes the socket off them
    /// and invites them to take it back. Wait 30-60s (jittered) instead. The
    /// app still recovers if the winner goes away for good — this is a pause,
    /// not a surrender. Android does the same since v0.82.
    private func scheduleSupersededReconnect() {
        pendingReconnect?.cancel()
        let delay = Double.random(in: 30...60)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reconnectNow() }
        }
        pendingReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
