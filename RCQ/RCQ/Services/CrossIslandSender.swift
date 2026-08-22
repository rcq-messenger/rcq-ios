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
        // Stage 2: every call signal deposits as `envelope_type "message"`; the
        // two waking signals (offer/end) ask for the ring with `ring:true` instead
        // of the more telling `"call"` type. A Stage 2 island rings a socket-less
        // peer without learning the row is a call; an older island ignores the
        // unknown `ring`, still routes and queues the row, and the call degrades
        // to no-wake rather than breaking. The inner envelope is untouched.
        let ring = wakingSignals.contains(type)
        Task.detached {
            let ok = await deposit(host: host, uin: uin, payload: blob, ring: ring)
            if !ok { print("[CrossIslandSender] call-signal deposit failed (\(type) → \(uin)@\(host))") }
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
    /// `envelopeType` is `"message"` for everything sent here. Stage 2: `cls`
    /// mirrors the island's own `_cls_for` derivation so a peer classifies the
    /// row from the sender rather than guessing, and `ring` (the §5d wake) asks a
    /// socket-less peer's island to ring instead of queueing a banner. Both are
    /// additive: an older peer island ignores the fields it does not know.
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
