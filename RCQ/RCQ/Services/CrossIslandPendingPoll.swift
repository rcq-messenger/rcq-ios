import Foundation

/// F1 (spec 2026-09-15): contact requests addressed to this account's GUEST
/// COPIES on the islands this device visited.
///
/// Somebody on island B who met us in a room there asks to add us the only
/// way B knows: a plain `POST /contacts/request` to our per-island uin. That
/// row sits in B's database, and until now nothing ever read it, because the
/// guest drains read the queue and the room log, never `/contacts/pending`.
/// This reads it, on the same visited islands and with the same guest token,
/// and files each row into the one cross-island request list the Requests
/// screen already shows.
///
/// Answers:
/// - Accept: the §5f accept sealed from HOME to the requester on B (the
///   existing add), then the row on B is withdrawn with
///   `DELETE /contacts/pending/{id}`. Not `/contacts/respond`: accept=true
///   would write contact edges on B that nobody asked for, and accept=false
///   would tell the requester "declined" for 180 days about an answer that
///   was in fact yes.
/// - Decline: an honest `respond(false)` on B.
/// - Block: withdraw, and the sender is blocked here.
/// - An island without `contact_pending_withdraw`: the row is hidden here
///   and left on the island. Never a decline in its place.
///
/// Visited islands only, not the backup homes (founder decision on open
/// question (e)). Nothing here runs in a decoy session, while the app is
/// locked, while a burn is under way, or for an account that is no longer the
/// active one when a request comes back.
@MainActor
enum CrossIslandPendingPoll {
    struct Row: Decodable {
        let id: Int
        let from_uin: Int
        let nickname: String
        let state: String?
    }

    /// Rows read per island per poll. A flood on one island fills a fixed
    /// number of rows, like the §5f cap.
    static let maxRowsPerHost = 20
    /// Withdraws per island per poll. The island allows 60 an hour; at one
    /// poll per five minutes this stays at 36, leaving room for the answers
    /// a person gives by hand.
    static let maxWithdrawsPerPass = 3
    /// The largest pending list read from an island. Twenty honest rows are a
    /// few kilobytes; anything past this is an island filling our storage (the
    /// rows land in the App Group suite the notification extension also
    /// loads), and the whole answer is refused rather than read in part.
    static let maxBodyBytes = 64_000
    /// A row whose name is longer than this is dropped, not shortened: no
    /// honest island serves one, so the row is not a request anybody made.
    static let maxNicknameBytes = 1_024

    private static var schedule = PendingPollSchedule()
    private static var scheduleAccount: UUID?
    private static var inFlight: Set<String> = []
    private static var withdrawByHost: [String: (value: Bool, at: Date)] = [:]

    private static func stillOurs(_ accountID: UUID?) -> Bool {
        AccountManager.shared.activeAccountID == accountID
            && !PanicPINService.shared.isDecoy
            && !PanicPINService.shared.isLocked
            && !BurnCascade.isBurning
    }

    /// The looser check for an answer a person gave on the Requests screen:
    /// the same account is still the active one, and it is not the decoy.
    /// An answer already given goes on through a lock or a burn; one that
    /// would now speak as ANOTHER account never does.
    static func sameAccount(_ accountID: UUID?) -> Bool {
        AccountManager.shared.activeAccountID == accountID && !PanicPINService.shared.isDecoy
    }

    /// The schedule is the previous account's on a switch: its hosts, its
    /// backoffs. A fresh one for whoever is signed in now.
    private static func bindSchedule(_ accountID: UUID?) {
        guard scheduleAccount != accountID else { return }
        schedule = PendingPollSchedule()
        scheduleAccount = accountID
        inFlight = []
    }

    // MARK: poll

    /// Called by the visited-island drain for each island right after its
    /// queue and room log, with the guest token that drain ended up with.
    /// Does nothing until the schedule says the island is due.
    static func pollIfDue(host: String, jwt: String) async {
        let accountID = AccountManager.shared.activeAccountID
        guard stillOurs(accountID),
              let h = Multihome.normalizeHost(host)?.lowercased(),
              !Multihome.isOwnHost(h) else { return }
        bindSchedule(accountID)
        guard schedule.due(h, now: Date()), !inFlight.contains(h) else { return }
        inFlight.insert(h)
        defer { inFlight.remove(h) }
        await poll(host: h, jwt: jwt, accountID: accountID)
    }

    /// The Requests screen opened: ask each visited island now instead of at
    /// its next turn, at most once a minute per island, and never one that is
    /// backing off after a failure or a 429.
    static func pollNow() {
        let accountID = AccountManager.shared.activeAccountID
        guard stillOurs(accountID) else { return }
        bindSchedule(accountID)
        let now = Date()
        var hosts: [String] = []
        for v in VisitedIslandsStore.shared.list() where !Multihome.isOwnHost(v.host) {
            if schedule.forceSoon(v.host, now: now) { hosts.append(v.host) }
        }
        guard !hosts.isEmpty else { return }
        Task {
            for host in hosts {
                guard stillOurs(accountID), let v = VisitedIslandsStore.shared.get(host: host) else { return }
                await pollIfDue(host: v.host, jwt: v.jwt)
            }
        }
    }

    private enum Fetch {
        case rows([Row])
        case unauthorized
        case limited(TimeInterval?)
        case failed
    }

    private static func poll(host: String, jwt: String, accountID: UUID?) async {
        var token = jwt
        var got = await fetchPending(host: host, jwt: token)
        guard stillOurs(accountID) else { return }
        if case .unauthorized = got {
            let fresh = await CrossIslandGroups.refreshGuest(host: host)
            guard stillOurs(accountID) else { return }
            guard let fresh else {
                schedule.onResult(host, ok: false, now: Date())
                return
            }
            token = fresh.jwt
            got = await fetchPending(host: host, jwt: token)
            guard stillOurs(accountID) else { return }
        }
        switch got {
        case .rows(let rows):
            schedule.onResult(host, ok: true, now: Date())
            await ingest(host: host, rows: rows, jwt: token, accountID: accountID)
        case .limited(let retryAfter):
            schedule.onResult(host, ok: false, retryAfter: retryAfter, now: Date())
        case .unauthorized, .failed:
            schedule.onResult(host, ok: false, now: Date())
        }
    }

    /// The contact this account pinned for `uin` on `host`, if it still has one.
    private static func pinnedContact(uin: Int, host: String) -> Contact? {
        CrossIslandStore.shared.all().first { $0.uin == uin && ($0.host ?? "").lowercased() == host.lowercased() }
    }

    /// File one island's answer. See `PendingRowRule` for the order the
    /// questions are asked in.
    private static func ingest(host: String, rows: [Row], jwt: String, accountID: UUID?) async {
        let store = CrossIslandRequestsStore.shared
        let guestUIN = VisitedIslandsStore.shared.get(host: host)?.uin ?? 0
        let pending = rows.filter {
            ($0.state ?? "pending") == "pending" && $0.id > 0 && $0.from_uin > 0
                && $0.nickname.utf8.count <= maxNicknameBytes
        }
        let canWithdraw = await hostWithdraws(host)
        guard stillOurs(accountID) else { return }
        var withdrawsLeft = maxWithdrawsPerPass

        for row in pending.prefix(maxRowsPerHost) {
            let existing = store.request(uin: row.from_uin, host: host)
            let tries = existing?.serverRequestID == row.id ? (existing?.srvAcceptTries ?? 0) : 0
            let action = PendingRowRule.action(
                blocked: store.isBlocked(uin: row.from_uin, host: host),
                answered: store.isAnswered(host: host, id: row.id),
                acceptTries: tries,
                isContact: pinnedContact(uin: row.from_uin, host: host) != nil,
                canWithdraw: canWithdraw
            )
            switch action {
            case .upsert:
                store.upsertServerRequest(
                    uin: row.from_uin, host: host, id: row.id, guestUIN: guestUIN, nickname: row.nickname
                )
            case .markAnswered:
                store.markAnswered(host: host, id: row.id)
            case .keep:
                break
            case .withdraw:
                guard withdrawsLeft > 0 else { continue }
                withdrawsLeft -= 1
                let out = await withdraw(host: host, id: row.id, jwt: jwt)
                guard stillOurs(accountID) else { return }
                settle(out, host: host, id: row.id)
            case .redeposit:
                // ⚠⚠ Sealed to the keys pinned when the person accepted, never
                // to a card fetched now. The island serves the card: re-fetching
                // it here would let it pass the accept-time check with the real
                // key, fail the first deposit on purpose, then put its own key
                // in front of this retry and read our home number from it.
                guard let contact = pinnedContact(uin: row.from_uin, host: host) else {
                    // The contact was deleted on this device since the accept:
                    // there is no answer left to deliver. Hidden for good; the
                    // next poll withdraws it where the island can.
                    store.markAnswered(host: host, id: row.id)
                    continue
                }
                // No await between this check and the seal: the deposit seals
                // with the active identity before its first suspension.
                guard stillOurs(accountID) else { return }
                let sent = await CrossIslandSender.depositContactReq(
                    act: "accept", uin: row.from_uin, host: host,
                    identityKey: contact.identityKey, signingKey: contact.signingKey
                )
                guard stillOurs(accountID) else { return }
                if sent {
                    await acceptLanded(uin: row.from_uin, host: host, id: row.id, contact: contact, accountID: accountID)
                    guard stillOurs(accountID) else { return }
                } else {
                    store.noteAcceptRetryFailed(uin: row.from_uin, host: host)
                }
            }
        }
        store.reconcileServerRequests(host: host, liveIDs: Set(pending.map(\.id)))
    }

    /// The poll's own retry of an accept got through: the requester holds our
    /// answer now. Same ending as an accept that got through the first time.
    ///
    /// ⚠ Every step after an await asks again whether this is still the
    /// account that accepted. `sendProfile` and `sendCIAck` speak as whoever
    /// is active when they run: after a switch they would hand the new
    /// account's name and face to the old account's contact, and file the old
    /// account's contact on the new account's other devices, which links the
    /// two accounts for anyone watching.
    private static func acceptLanded(uin: Int, host: String, id: Int, contact: Contact, accountID: UUID?) async {
        CrossIslandRequestsStore.shared.clear(uin: uin, host: host)
        await settleAnswered(host: host, id: id)
        guard stillOurs(accountID) else { return }
        await CrossIslandSender.sendProfile(to: contact)
        guard stillOurs(accountID) else { return }
        await MessageService.shared.sendCIAck(
            uin: uin, host: host, act: "accept",
            card: CICard(nick: contact.nickname, ik: contact.identityKey, sk: contact.signingKey,
                         sik: contact.signalIdentityKey, gender: contact.gender, status: contact.statusMessage),
            srv: CISrv(host: host, id: id)
        )
    }

    // MARK: answers given on the Requests screen

    /// An answer to the pending row `id` on `host` was given (accepted and
    /// delivered, or blocked): hide it for good, then withdraw it from the
    /// island when the island can. A withdraw that does not land now is asked
    /// again by the next poll, which still sees the row.
    static func settleAnswered(host: String, id: Int) async {
        guard let h = Multihome.normalizeHost(host)?.lowercased(), id > 0 else { return }
        CrossIslandRequestsStore.shared.markAnswered(host: h, id: id)
        let accountID = AccountManager.shared.activeAccountID
        guard stillOurs(accountID) else { return }
        let capable = await hostWithdraws(h)
        guard capable, stillOurs(accountID), let v = VisitedIslandsStore.shared.get(host: h) else { return }
        let out = await withdraw(host: h, id: id, jwt: v.jwt)
        guard stillOurs(accountID) else { return }
        settle(out, host: h, id: id)
    }

    /// The ack to this account's other devices after an accept given on the
    /// Requests screen, carrying the card this device pinned. Sent only while
    /// `accountID` is still the active account: the ack is sealed to whoever
    /// is active, and the card in it would otherwise be filed into another
    /// account.
    static func sendAcceptAck(accountID: UUID?, uin: Int, host: String, srvID: Int?) async {
        guard sameAccount(accountID),
              let c = CrossIslandStore.shared.all().first(where: { $0.uin == uin && $0.host == host }) else { return }
        await MessageService.shared.sendCIAck(
            uin: uin, host: host, act: "accept",
            card: CICard(nick: c.nickname, ik: c.identityKey, sk: c.signingKey,
                         sik: c.signalIdentityKey, gender: c.gender, status: c.statusMessage),
            srv: srvID.map { CISrv(host: host, id: $0) }
        )
    }

    /// Decline the pending row `id` on `host`: the island answers the
    /// requester "declined", which is what a decline is. Hidden here first,
    /// so a failed request does not bring the row back.
    static func declineOnIsland(host: String, id: Int) async {
        guard let h = Multihome.normalizeHost(host)?.lowercased(), id > 0 else { return }
        CrossIslandRequestsStore.shared.markAnswered(host: h, id: id)
        let accountID = AccountManager.shared.activeAccountID
        guard stillOurs(accountID), let v = VisitedIslandsStore.shared.get(host: h) else { return }
        var code = await respond(host: h, id: id, accept: false, jwt: v.jwt)
        guard stillOurs(accountID) else { return }
        if code == 401 {
            let fresh = await CrossIslandGroups.refreshGuest(host: h)
            guard stillOurs(accountID), let fresh else { return }
            code = await respond(host: h, id: id, accept: false, jwt: fresh.jwt)
        }
        _ = code
    }

    // MARK: key and room context for a row

    /// The line under a server row naming the room we share with the sender
    /// on that island, from the rosters this device already holds. No fetch:
    /// a roster fetch per row would tell the island which requests we looked
    /// at. Nil when no roster there is cached, because "not in your groups"
    /// would then be a guess.
    static func roomLine(uin: Int, host: String) -> String? {
        let h = host.lowercased()
        let withRoster = GroupService.shared.groups.filter {
            ($0.host ?? "").lowercased() == h && !$0.members.isEmpty
        }
        guard !withRoster.isEmpty else { return nil }
        let shared = withRoster.filter { g in g.members.contains { $0.uin == uin } }.map(\.name)
        guard let first = shared.first else { return "ci.server.not_in_groups".localized }
        return shared.count == 1
            ? String(format: "ci.server.via_group".localized, first)
            : String(format: "ci.server.via_group_more".localized, first, shared.count - 1)
    }

    enum CardCheck {
        /// The island did not hand over a card: nothing could be checked, and
        /// nothing may be accepted on it.
        case unavailable
        /// The card, and whether it differs from a key this device saw for the
        /// same person in a room there.
        case card(CrossIslandSender.Card, differs: Bool)
    }

    /// Fetch the card `host` serves for `uin` ONCE, and compare it with the
    /// keys this device saw for the same person there BEFORE the request: a
    /// member of a cached room roster, or the signer of a sender-key chain in
    /// a room on that island.
    ///
    /// ⚠⚠ The accept must pin and seal to THIS card (see
    /// `ContactService.addCrossIslandContact(uin:host:card:announce:)`). A
    /// second fetch would let the island show the honest key to the check and
    /// its own key to the add a moment later.
    ///
    /// ⚠ The honest limit (spec F1, critic 6): island B asserts both the row
    /// and the card, so a malicious operator can put its own key in front of
    /// the accept and read who we are at home. This catches the case where
    /// the device already holds an earlier, independently delivered key for
    /// that person; without one there is nothing to compare, and the accept
    /// hint says whose word the row rests on.
    static func checkCard(uin: Int, host: String) async -> CardCheck {
        let h = host.lowercased()
        guard let card = await CrossIslandSender.fetchCard(host: h, uin: uin) else { return .unavailable }
        let rooms = GroupService.shared.groups.filter { ($0.host ?? "").lowercased() == h }
        var prior = rooms.flatMap(\.members).filter { $0.uin == uin && !$0.signingKey.isEmpty }.map(\.signingKey)
        let ownUIN = MessageService.shared.ownUIN
        if ownUIN != 0 {
            let gids = PriorKeyRooms.gids(roomIDs: rooms.map(\.id), host: h) { alias in
                VisitedIslandsStore.shared.refByAlias(alias).map { ($0.host, $0.remoteId) }
            }
            prior += GroupSenderKeyStore.shared.inboundSigners(ownUin: ownUIN, senderUIN: uin, gids: gids)
        }
        guard !prior.isEmpty else { return .card(card, differs: false) }
        return .card(card, differs: !prior.allSatisfy { sameKey($0, card.signing_key) })
    }

    /// Two base64 keys compared as bytes, so a url-safe or unpadded spelling of
    /// the same key is the same key.
    static func sameKey(_ a: String, _ b: String) -> Bool {
        guard let x = keyBytes(a), let y = keyBytes(b) else { return a == b }
        return x == y
    }

    private static func keyBytes(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: capability

    /// Per-host answer to "can a pending row be withdrawn here", read off the
    /// island's /server/info. Same keeping rule as the room-log flag: a yes
    /// for the life of the process, a no asked again after an hour. A 404 on
    /// the withdraw that is not the endpoint's own code drops the cached yes
    /// (the island may have been downgraded, or a proxy answered).
    static func hostWithdraws(_ host: String) async -> Bool {
        let key = host.lowercased()
        if let known = withdrawByHost[key], known.value || Date().timeIntervalSince(known.at) < 3600 {
            return known.value
        }
        var value = false
        if let url = URL(string: "https://\(key)/server/info") {
            var req = URLRequest(url: url)
            AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
            if let (data, resp) = try? await IslandHTTP.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let info = try? JSONDecoder().decode(ServerInfoResponse.self, from: data) {
                value = info.capabilities.contactPendingWithdraw
            }
        }
        withdrawByHost[key] = (value, Date())
        return value
    }

    // MARK: HTTP

    enum WithdrawOutcome {
        /// 204, or 404 with `no_such_request`: the row is not pending there.
        case done
        /// A 404 without the endpoint's code: not proof of anything.
        case notThere
        case limited(TimeInterval?)
        case failed
    }

    private static func settle(_ out: WithdrawOutcome, host: String, id: Int) {
        switch out {
        case .done:
            CrossIslandRequestsStore.shared.markAnswered(host: host, id: id)
        case .notThere:
            // Kept answered (hidden) and asked again once the capability has
            // been read afresh.
            CrossIslandRequestsStore.shared.markAnswered(host: host, id: id)
            withdrawByHost[host.lowercased()] = nil
        case .limited(let retryAfter):
            schedule.onResult(host, ok: false, retryAfter: retryAfter, now: Date())
        case .failed:
            break
        }
    }

    /// `DELETE /contacts/pending/{id}` with the guest token, re-minted once
    /// through the recover handshake on a 401.
    private static func withdraw(host: String, id: Int, jwt: String) async -> WithdrawOutcome {
        var (code, body, retryAfter) = await send("DELETE", host: host, path: "/contacts/pending/\(id)", json: nil, jwt: jwt)
        if code == 401 {
            guard let fresh = await CrossIslandGroups.refreshGuest(host: host) else { return .failed }
            (code, body, retryAfter) = await send("DELETE", host: host, path: "/contacts/pending/\(id)", json: nil, jwt: fresh.jwt)
        }
        switch code {
        case .some(200..<300):
            return .done
        case .some(404):
            let detail = Multihome.authErrorDetail(String(data: body, encoding: .utf8) ?? "")
            return detail.code == "no_such_request" ? .done : .notThere
        case .some(429):
            return .limited(retryAfter)
        default:
            return .failed
        }
    }

    private static func respond(host: String, id: Int, accept: Bool, jwt: String) async -> Int {
        let (code, _, _) = await send(
            "POST", host: host, path: "/contacts/respond",
            json: ["request_id": id, "accept": accept], jwt: jwt
        )
        return code ?? 0
    }

    private static func fetchPending(host: String, jwt: String) async -> Fetch {
        let (code, body, retryAfter) = await send("GET", host: host, path: "/contacts/pending", json: nil, jwt: jwt)
        switch code {
        case .some(200..<300):
            // Counted as a failure, so the island backs off like any other
            // that answers badly.
            guard body.count <= maxBodyBytes,
                  let rows = try? JSONDecoder().decode([Row].self, from: body) else { return .failed }
            return .rows(rows)
        case .some(401):
            return .unauthorized
        case .some(429):
            return .limited(retryAfter)
        default:
            return .failed
        }
    }

    /// One request to `host` with the guest token. Status nil when nothing
    /// answered; Retry-After in seconds when the island sent one.
    private static func send(
        _ method: String, host: String, path: String, json: [String: Any]?, jwt: String
    ) async -> (Int?, Data, TimeInterval?) {
        guard let url = URL(string: "https://\(host)\(path)") else { return (nil, Data(), nil) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        if let json, let body = try? JSONSerialization.data(withJSONObject: json) {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        guard let (data, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse else { return (nil, Data(), nil) }
        let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { TimeInterval($0) }
        return (http.statusCode, data, retryAfter)
    }
}
