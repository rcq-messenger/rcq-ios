import Foundation

/// Federation Layer B (F2) — cross-island send helpers.
///
/// Fetch a peer's open public-key card from their island, resolve their current
/// home island(s) from their signed home-island record (verified), and deposit a
/// pre-sealed blob to an arbitrary island's `/messages/sealed`. The v=1 seal
/// itself is done by the caller (`MessageService.crypto.encrypt`). Mirrors the
/// web `federation-send.ts`, verified end-to-end against a real second island.
enum CrossIslandSender {

    struct Card: Decodable {
        let identity_key: String
        let signing_key: String
        let signal_identity_key: String?
        // §5c display: the open card now carries the peer's nickname (+ optional
        // gender/status) so a cross-island contact shows a real name, not uin@host.
        let nickname: String?
        let gender: String?
        let status_message: String?
    }

    struct Home {
        let host: String
        let uin: Int
    }

    /// §5d signals that must reach an app that is not running. `call_offer`
    /// because a call that does not ring is not a call; `call_end` because a
    /// caller who hangs up during the ring must be able to take the CallKit
    /// entry back down — otherwise the callee's phone rings at a caller who
    /// left. Everything else (`call_answer`, ICE, renegotiate) only means
    /// anything to an app that is already awake and holding a socket, so it
    /// stays `"message"` and buys no disclosure.
    private static let wakingSignals: Set<String> = ["call_offer", "call_end"]

    /// §5d cross-island call signaling: wrap a call_* WS signal as an
    /// `Envelope.callSignal`, v=1-seal it to the contact's identity key and
    /// deposit it to their PRIMARY island only. No backup-home copies — backup
    /// mailboxes are polled (~30s), useless for real-time signaling, and if
    /// the primary island is down the call cannot work anyway.
    @MainActor
    static func depositCallSignal(type: String, callID: String, extras: [String: Any], contact: Contact, host: String) {
        guard let crypto = MessageService.shared.crypto else { return }
        let data = extras.compactMapValues { $0 as? String }
        let env = Envelope.callSignal(
            id: UUID(), sig: type, cid: callID,
            ts: Int(Date().timeIntervalSince1970), data: data
        )
        let bundle = PeerBundle(uin: contact.uin, identityKey: contact.identityKey, signingKey: contact.signingKey)
        guard let blob = try? crypto.encrypt(envelope: env, for: bundle) else {
            print("[CrossIslandSender] call-signal seal failed (\(type))")
            return
        }
        let uin = contact.uin
        // Stage 2: a call signal deposits as `envelope_type "message"` and the
        // two waking signals (offer/end) ask for the ring with `ring:true`
        // instead of the more telling `"call"` type, so a Stage 2 island rings
        // a socket-less peer without learning the row is a call. An older
        // island ignores the unknown `ring` and would queue the offer without
        // waking anyone, so the waking signals first ask the island whether it
        // honours `ring` (below) and fall back to `"call"` where it does not.
        // The inner envelope is untouched either way.
        let ring = wakingSignals.contains(type)
        // Signals of one call leave in the order they were asked for: each one
        // deposits from its own task, and the offer now also pays the ring
        // probe on a slow island, so an ICE batch released the instant the
        // probe settles would otherwise POST side by side with the offer it
        // belongs to. A callee drops ICE that arrives before its offer. The
        // chain is linked HERE, on the main actor in emit order, because two
        // detached tasks reach any actor in whatever order they are scheduled.
        // Android chains per call id the same way (`Session.depositCallSignal`),
        // and so does the web client.
        let prev = callTails[callID]
        let job = Task.detached {
            await prev?.value
            // A call that does not ring is not a call. An island older than
            // Stage 2 ignores `ring` and wakes a closed app only for the
            // `"call"` type, so the two waking signals first ask the peer
            // island whether it honours `ring` and pay the legible `"call"`
            // row only where nothing better works. Non-waking signals never
            // probe and never change type: they mean nothing to an app that is
            // not already awake. They do WAIT for a probe already running for
            // this host, because each signal deposits from its own task and the
            // probe delays only the offer: without the wait an ICE batch sent
            // right behind the offer lands in the callee island's queue first,
            // and a callee drops ICE that arrives before its offer.
            var envelopeType = "message"
            if ring {
                let honours = await RingSupport.shared.honoursRing(host: host)
                if !honours { envelopeType = "call" }
            } else {
                await RingSupport.shared.waitForProbe(host: host)
            }
            let ok = await deposit(host: host, uin: uin, payload: blob, envelopeType: envelopeType, ring: ring)
            if !ok { print("[CrossIslandSender] call-signal deposit failed (\(type) → \(uin)@\(host))") }
        }
        callTails[callID] = job
        Task { @MainActor in
            await job.value
            if callTails[callID] == job { callTails[callID] = nil }
        }
    }

    /// The last deposit asked for on each call id, so the next one can queue
    /// behind it (see `depositCallSignal`). Main-actor only.
    @MainActor private static var callTails: [String: Task<Void, Never>] = [:]

    /// Start the `ring` probe for `host` without waiting for it, so the memo
    /// is warm by the time the offer deposits. For the outgoing call start,
    /// where the callee's island is known seconds before the SDP is ready
    /// (the offer waits on `createOffer`, which gathers ICE). A warm hit costs
    /// the offer nothing; a miss costs it the probe it would have paid anyway.
    /// Same-island calls never come here. Nothing observes the result.
    static func warmRingSupport(host: String) {
        Task.detached { _ = await RingSupport.shared.honoursRing(host: host) }
    }

    /// Per-island memory of "does `/server/info` advertise `envelope_class`"
    /// (the flag born together with `ring`; see `ServerCapabilities`). An
    /// actor because the call path asks from a detached task while nothing
    /// stops two signals of one call (or two calls) asking at once: the
    /// in-flight task is shared so a host is probed once, not per caller.
    ///
    /// A yes is kept for an hour (an island does not forget a capability). A
    /// no is kept for ten minutes only: it is as often a slow answer or a 404
    /// on a blocked route as a genuinely old island, and an island that
    /// upgrades (is2 today, foreign self-hosts whenever they get to it) should
    /// be rung the cheap way soon after, not after the next app launch.
    actor RingSupport {
        static let shared = RingSupport()

        private struct Entry {
            let honours: Bool
            let expires: Date
        }
        private var entries: [String: Entry] = [:]
        private var inflight: [String: Task<Bool, Never>] = [:]

        private static let yesTTL: TimeInterval = 60 * 60
        private static let noTTL: TimeInterval = 10 * 60

        func honoursRing(host: String) async -> Bool {
            let key = host.lowercased()
            if let hit = entries[key], hit.expires > Date() { return hit.honours }
            if let running = inflight[key] { return await running.value }
            let probe = Task { await CrossIslandSender.probeRingSupport(host: host) }
            inflight[key] = probe
            let honours = await probe.value
            inflight[key] = nil
            entries[key] = Entry(
                honours: honours,
                expires: Date().addingTimeInterval(honours ? Self.yesTTL : Self.noTTL)
            )
            return honours
        }

        /// Block until no probe is running for `host`; never start one. For
        /// the non-waking signals, which must not overtake the offer that is
        /// waiting on this probe (see `depositCallSignal`). Returns at once
        /// when nothing is in flight, memo or no memo.
        func waitForProbe(host: String) async {
            guard let running = inflight[host.lowercased()] else { return }
            _ = await running.value
        }
    }

    /// One `/server/info` round trip to a peer island, answering only "does it
    /// honour `ring`". Anything short of a decoded `envelope_class: true`
    /// (non-200, no answer, unparseable body, the flag absent or false) is a
    /// no: the legacy form it triggers rings on every island, so the cost of
    /// a wrong no is one legible row, while the cost of a wrong yes is a
    /// silent call.
    ///
    /// Goes through `IslandHTTP` like the deposit itself, not a bare session
    /// (`ServerInfoService.fetch(host:)` is for the join confirm and is fine
    /// direct): on a censored network a blocked-but-tunnelled island would
    /// otherwise look "old" merely because the direct fetch failed, and we
    /// would then send it a `"call"` row for nothing.
    ///
    /// The offer sits on the press-to-ringback path, so the answer is bounded
    /// at 5 s rather than the session's 20. The bound is a RACE against a
    /// sleep, not a request timeout: `IslandHTTP` reads a thrown error on the
    /// direct attempt as "this route is blocked", engages the tunnel and marks
    /// the host blocked for the life of the process, and a 5 s timeout would
    /// throw exactly that way on an island that is merely slow. The deposit
    /// itself runs with the session's own ceilings and keeps that fallback; a
    /// probe that loses the race only says "cannot tell quickly", which is a
    /// no. The losing request is cancelled, and `IslandHTTP.run` lets a
    /// cancellation through without a verdict on the route.
    private static func probeRingSupport(host: String) async -> Bool {
        guard let url = URL(string: "https://\(host)/server/info") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let request = req   // immutable copy: the child closure is Sendable
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                guard let (data, resp) = try? await IslandHTTP.data(for: request),
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let info = try? JSONDecoder().decode(ServerInfoResponse.self, from: data) else { return false }
                return info.capabilities.envelopeClass
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// §5f cross-island contact request: wrap `act` (request/accept/decline) as
    /// an `Envelope.contactRequest`, v=1-seal it to the peer's identity key from
    /// their open card and deposit it to their PRIMARY island only — the same
    /// path §5d uses for call signalling, zero server changes.
    ///
    /// Without this, "add" across islands was a local row and nothing else: the
    /// peer was never told, so §5d's "both sides accepted" precondition could
    /// never be reached through the ordinary flow.
    ///
    /// The keys come from the caller (the add path already holds the card), so
    /// this never re-fetches and never touches the pinned identity/signing keys.
    /// Returns true when the peer's island took the deposit.
    @MainActor
    @discardableResult
    static func depositContactReq(
        act: String, uin: Int, host: String,
        identityKey: String, signingKey: String, note: String? = nil
    ) async -> Bool {
        guard let crypto = MessageService.shared.crypto else { return false }
        let nick = AuthService.shared.nickname
        let env = Envelope.contactRequest(
            id: UUID(), act: act,
            ts: Int(Date().timeIntervalSince1970),
            nickname: nick, note: note
        )
        let bundle = PeerBundle(uin: uin, identityKey: identityKey, signingKey: signingKey)
        guard let blob = try? crypto.encrypt(envelope: env, for: bundle) else {
            print("[CrossIslandSender] contactreq seal failed (\(act) → \(uin)@\(host))")
            return false
        }
        // F3 token: a contact request is exactly the permissionless-spam shape
        // the anonymous deposit token exists for, and it isn't latency-critical.
        let ok = await deposit(host: host, uin: uin, payload: blob, mintToken: true)
        if !ok { print("[CrossIslandSender] contactreq deposit failed (\(act) → \(uin)@\(host))") }
        return ok
    }

    /// Same as above for callers that don't already hold the peer's card
    /// (declining a received request — no local contact row is written, so
    /// there are no pinned keys to read).
    @MainActor
    @discardableResult
    static func depositContactReq(act: String, uin: Int, host: String, note: String? = nil) async -> Bool {
        guard let card = await fetchCard(host: host, uin: uin) else { return false }
        return await depositContactReq(
            act: act, uin: uin, host: host,
            identityKey: card.identity_key, signingKey: card.signing_key, note: note
        )
    }

    /// §5e cross-island profile refresh: seal the sender's CURRENT display name
    /// and picture reference to one accepted cross-island contact and deposit it
    /// to their PRIMARY island — the §5f transport, the §5f gates, one sibling
    /// envelope. Display fields only; the pinned keys are read from the local
    /// row (to seal) and never travel.
    ///
    /// `avatarMediaID`/`avatarMediaKey` are passed in already deposited: the
    /// caller PUTs the encrypted blob to the recipient's island FIRST (§5b), so
    /// the reference resolves against the island the recipient actually reads.
    @MainActor
    @discardableResult
    static func depositProfile(
        to contact: Contact,
        nickname: String,
        avatarMediaID: String?,
        avatarMediaKey: String?
    ) async -> Bool {
        guard let host = contact.host, !Multihome.isOwnHost(host) else { return false }
        guard let crypto = MessageService.shared.crypto else { return false }
        let env = Envelope.profile(
            id: UUID(), ts: Int(Date().timeIntervalSince1970),
            nickname: nickname,
            avatarMediaID: avatarMediaID, avatarMediaKey: avatarMediaKey
        )
        let bundle = PeerBundle(uin: contact.uin, identityKey: contact.identityKey, signingKey: contact.signingKey)
        guard let blob = try? crypto.encrypt(envelope: env, for: bundle) else {
            print("[CrossIslandSender] profile seal failed (→ \(contact.uin)@\(host))")
            return false
        }
        // Same F3 posture as the contactreq: cosmetic, not latency-critical.
        let ok = await deposit(host: host, uin: contact.uin, payload: blob, mintToken: true)
        if !ok { print("[CrossIslandSender] profile deposit failed (→ \(contact.uin)@\(host))") }
        return ok
    }

    /// §5e: push the current profile to EVERY accepted cross-island contact.
    /// Called after a successful nickname or picture save, so a contact added as
    /// "nick1" stops reading "nick1" forever.
    ///
    /// The picture is DEPOSITED, not pulled: the encrypted blob is fetched once
    /// from our own island and PUT to each recipient island under the same
    /// client-chosen id before any envelope goes out.
    ///
    /// ⚠ When we HAVE a picture and its blob does not land on a recipient's
    /// island, that recipient is SKIPPED entirely rather than being sent the
    /// name alone. The envelope is a SNAPSHOT of our whole display state, so a
    /// missing picture reads on the far side as "I removed mine" and deletes our
    /// face (web, Android and now iOS all clear on absence). Deleting a face
    /// because of a transient media hiccup is far worse than a name that
    /// refreshes on our next change.
    @MainActor
    static func broadcastProfile() async {
        // The decoy identity must never speak for the real one.
        if PanicPINService.shared.isDecoy { return }
        // Someone we blocked does not get handed our current name and face.
        // Same filter web applies to this broadcast.
        let peers = CrossIslandStore.shared.all().filter { c in
            guard let h = c.host else { return false }
            return !CrossIslandRequestsStore.shared.isBlocked(uin: c.uin, host: h)
        }
        guard !peers.isEmpty else { return }
        let nickname = AuthService.shared.nickname
        let avatarID = PresenceService.shared.ownAvatarID
        let avatarKey = PresenceService.shared.ownAvatarKey
        let havePicture = (avatarID?.isEmpty == false) && (avatarKey?.isEmpty == false)

        // One host string per island (rows carry the host as it was typed).
        var hosts: [String: String] = [:]   // lowercased → as-stored
        for p in peers { if let h = p.host { hosts[h.lowercased()] = h } }

        var hostsWithAvatar: Set<String> = []
        if havePicture, let avatarID, let avatarKey, !avatarKey.isEmpty,
           let blob = try? await MediaService.fetchBlob(mediaID: avatarID) {
            for (lower, host) in hosts {
                if await MediaService.putBlob(host: host, mediaID: avatarID, data: blob) {
                    hostsWithAvatar.insert(lower)
                }
            }
        }
        for p in peers {
            guard let host = p.host else { continue }
            let carriesAvatar = hostsWithAvatar.contains(host.lowercased())
            // Have a picture, could not hand it over → say nothing at all.
            if havePicture && !carriesAvatar {
                print("[CrossIslandSender] profile SKIPPED (avatar not deposited on \(host))")
                continue
            }
            await depositProfile(
                to: p, nickname: nickname,
                avatarMediaID: carriesAvatar ? avatarID : nil,
                avatarMediaKey: carriesAvatar ? avatarKey : nil
            )
        }
    }

    /// §5e first-contact push: one accepted contact, same work as the broadcast
    /// but for a single island, so a brand-new cross-island contact starts with a
    /// current name and picture instead of the card snapshot.
    @MainActor
    static func sendProfile(to contact: Contact) async {
        if PanicPINService.shared.isDecoy { return }
        guard let host = contact.host else { return }
        if CrossIslandRequestsStore.shared.isBlocked(uin: contact.uin, host: host) { return }
        let avatarID = PresenceService.shared.ownAvatarID
        let avatarKey = PresenceService.shared.ownAvatarKey
        let havePicture = (avatarID?.isEmpty == false) && (avatarKey?.isEmpty == false)
        var carriesAvatar = false
        if havePicture, let avatarID, let blob = try? await MediaService.fetchBlob(mediaID: avatarID) {
            carriesAvatar = await MediaService.putBlob(host: host, mediaID: avatarID, data: blob)
        }
        // Snapshot semantics: an envelope with no picture means "I have none".
        // Rather than tell a brand-new contact we are faceless because their
        // island refused the blob, send nothing and let the next change carry it.
        if havePicture && !carriesAvatar {
            print("[CrossIslandSender] first-contact profile SKIPPED (avatar not deposited on \(host))")
            return
        }
        await depositProfile(
            to: contact, nickname: AuthService.shared.nickname,
            avatarMediaID: carriesAvatar ? avatarID : nil,
            avatarMediaKey: carriesAvatar ? avatarKey : nil
        )
    }

    /// Fetch a peer's open public-key card from their island (no auth).
    static func fetchCard(host: String, uin: Int) async -> Card? {
        guard let url = URL(string: "https://\(host)/federation/keys/\(uin)") else { return nil }
        var cardReq = URLRequest(url: url)
        AccessTokenStore.stamp(&cardReq)   // closed-island gate (foreign host)
        guard let (data, resp) = try? await IslandHTTP.data(for: cardReq),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(Card.self, from: data)
    }

    /// Resolve the peer's verified home islands (spec §4). Falls back to the
    /// single home `[(host, uin)]` when no record is published or it doesn't verify.
    static func resolveHomes(host: String, uin: Int) async -> [Home] {
        let fallback = [Home(host: host, uin: uin)]
        guard let card = await fetchCard(host: host, uin: uin) else { return fallback }
        guard let url = URL(string: "https://\(host)/federation/island-record/\(uin)") else { return fallback }
        var recReq = URLRequest(url: url)
        AccessTokenStore.stamp(&recReq)   // closed-island gate (foreign host)
        guard let (data, resp) = try? await IslandHTTP.data(for: recReq),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fallback }
        let result = RcqFederation.verifyRecord(doc, opts: .init(expectedIk: card.signal_identity_key, expectedSk: card.signing_key))
        guard case .success(let rec) = result, let homes = rec["homes"] as? [[String: Any]] else { return fallback }
        let parsed = homes.compactMap { h -> Home? in
            guard let hh = h["host"] as? String, let uu = h["uin"] as? Int else { return nil }
            return Home(host: hh, uin: uu)
        }
        return parsed.isEmpty ? fallback : parsed
    }

    /// Deposit a pre-sealed blob to `host`'s `/messages/sealed` (no auth — sealed
    /// sender). Returns true on a 2xx. When `mintToken` is set, attach an F3
    /// anonymous blinded deposit token if the island offers one, so the deposit
    /// isn't throttled by the blunt per-IP cap (and survives a future
    /// require-token flip). Best-effort — no token = the legacy path. Off for
    /// real-time call signaling (latency-sensitive).
    ///
    /// `envelopeType` is `"message"` for everything sent here, with one
    /// exception below. Stage 2: `cls` mirrors the island's own `_cls_for`
    /// derivation so a peer classifies the row from the sender rather than
    /// guessing, and `ring` (the §5d wake) asks a socket-less peer's island to
    /// ring instead of queueing a banner. Both are additive: an older peer
    /// island ignores the fields it does not know. The exception is the waking
    /// call signal to such an older island, which `depositCallSignal` sends as
    /// `"call"` (plus `ring`, harmless on both) because that is the only type
    /// it wakes a closed app for.
    @discardableResult
    static func deposit(
        host: String, uin: Int, payload: String,
        mintToken: Bool = false, envelopeType: String = "message", ring: Bool = false
    ) async -> Bool {
        guard let url = URL(string: "https://\(host)/messages/sealed") else { return false }
        struct Body: Encodable {
            let to_uin: Int
            let envelope_type: String
            let cls: Int
            let payload: String
            let deposit_token: [String: String]?
            let ring: Bool?
        }
        let token = mintToken ? await DepositAuthStore.shared.tokenFor(host: host) : nil
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(
            Body(to_uin: uin, envelope_type: envelopeType, cls: rcqMessageClass(envelopeType),
                 payload: payload, deposit_token: token, ring: ring ? true : nil),
        )
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        guard let (_, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }
}
