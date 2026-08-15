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
        Task.detached {
            let ok = await deposit(host: host, uin: uin, payload: blob)
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
    @discardableResult
    static func deposit(host: String, uin: Int, payload: String, mintToken: Bool = false) async -> Bool {
        guard let url = URL(string: "https://\(host)/messages/sealed") else { return false }
        struct Body: Encodable {
            let to_uin: Int
            let envelope_type: String
            let payload: String
            let deposit_token: [String: String]?
        }
        let token = mintToken ? await DepositAuthStore.shared.tokenFor(host: host) : nil
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(
            Body(to_uin: uin, envelope_type: "message", payload: payload, deposit_token: token),
        )
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        guard let (_, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }
}
