import Foundation
import CryptoKit

/// Multihoming (federation v1) — this account also lives on N BACKUP islands,
/// registered with the SAME X25519+Ed25519 keypair (identity is the key; the
/// per-island uin is just a local handle). The signed home-island record lists
/// every home, senders deposit a sealed copy into each one, and we poll every
/// backup mailbox — the envelope-uuid dedup in MessageStore collapses copies
/// the primary already delivered. A single island death is then invisible.
/// Mirrors web-chat's multihome.ts + Android's Multihome.kt, both verified
/// end-to-end against a real second island (is2.rcq.app).
///
/// v1 scope: backups are v=1-only mailboxes (no libsignal bundle there); the
/// device that added the backup polls it (linked devices keep riding the
/// primary's per-device queue + carbons); groups stay single-island.
final class MultihomeStore {
    static let shared = MultihomeStore()

    struct Home: Codable, Identifiable, Equatable {
        /// The PRIMARY-island uin this backup belongs to (multi-account safety).
        let ownUin: Int
        let host: String
        /// OUR uin on the backup island (per-island handle, ≠ the primary uin).
        var uin: Int
        /// Bearer token for that island; refreshable any time via /auth/recover.
        var jwt: String
        let addedAt: Date
        /// True when this home was picked by the catalogue auto-pick toggle
        /// (vs a manually-entered host); the toggle only adds/removes its own
        /// homes. Optional so pre-existing stored entries decode as manual.
        var auto: Bool? = nil
        var id: String { "\(ownUin)@\(host)" }
    }

    /// Resolved peer homes + freshness. A STALE entry is still served when the
    /// record can't be re-fetched — that staleness IS the send-failover path.
    struct PeerHomes {
        let homes: [RcqFederation.Home]
        let ts: Date
    }
    private struct CodableHome: Codable { let host: String; let uin: Int }

    private static let appGroup = "group.app.rcq.shared"
    private static let homesKey = "rcq.multihome.homes.v1"
    private static let peerCacheKey = "rcq.multihome.peercache.v1"

    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
    }

    func list(ownUin: Int) -> [Home] { all().filter { $0.ownUin == ownUin } }

    func save(_ home: Home) {
        var rest = all().filter { !($0.ownUin == home.ownUin && $0.host == home.host) }
        rest.append(home)
        persist(rest)
    }

    func remove(ownUin: Int, host: String) {
        persist(all().filter { !($0.ownUin == ownUin && $0.host == host) })
    }

    /// Replace the token (and per-island uin) after a /auth/recover refresh.
    func updateCreds(ownUin: Int, host: String, uin: Int, jwt: String) {
        persist(all().map { h in
            guard h.ownUin == ownUin && h.host == host else { return h }
            var u = h; u.uin = uin; u.jwt = jwt; return u
        })
    }

    /// Promote bookkeeping (§5a.5): drop the promoted host's backup entry,
    /// re-key this account's remaining entries to the NEW primary uin, and file
    /// the old primary as a manual backup home (senders keep depositing there
    /// until they re-resolve the record, so its mailbox must stay drained).
    func promoteSwap(oldOwnUin: Int, newOwnUin: Int, promotedHost: String, oldPrimary: Home) {
        var next: [Home] = all()
            .filter { !($0.ownUin == oldOwnUin && $0.host == promotedHost) }
            .map { h in
                guard h.ownUin == oldOwnUin else { return h }
                return Home(ownUin: newOwnUin, host: h.host, uin: h.uin, jwt: h.jwt,
                            addedAt: h.addedAt, auto: h.auto)
            }
        next.append(oldPrimary)
        persist(next)
    }

    private func all() -> [Home] {
        guard let data = defaults.data(forKey: Self.homesKey),
              let list = try? JSONDecoder().decode([Home].self, from: data) else { return [] }
        return list
    }

    private func persist(_ list: [Home]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.homesKey) }
    }

    // MARK: peer-homes cache (deposit-to-all + send failover)

    func cachedPeerHomes(_ peerUin: Int) -> PeerHomes? {
        guard let data = defaults.data(forKey: Self.peerCacheKey),
              let map = try? JSONDecoder().decode([String: StoredPeer].self, from: data),
              let s = map[String(peerUin)] else { return nil }
        return PeerHomes(homes: s.homes.map { RcqFederation.Home(host: $0.host, uin: $0.uin) }, ts: s.ts)
    }

    func cachePeerHomes(_ peerUin: Int, homes: [RcqFederation.Home]) {
        var map: [String: StoredPeer] = [:]
        if let data = defaults.data(forKey: Self.peerCacheKey),
           let m = try? JSONDecoder().decode([String: StoredPeer].self, from: data) {
            map = m
        }
        map[String(peerUin)] = StoredPeer(homes: homes.map { CodableHome(host: $0.host, uin: $0.uin) }, ts: Date())
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.peerCacheKey) }
    }

    private struct StoredPeer: Codable { let homes: [CodableHome]; let ts: Date }
}

enum Multihome {

    /// How long a resolved peer-homes entry stays fresh; stale entries still
    /// serve as the failover route when the primary island is unreachable.
    private static let peerCacheTTL: TimeInterval = 10 * 60

    enum AddError: Error { case invalidHost, primaryIsland, alreadyAdded, noIsland, network(String) }

    struct Credentials: Decodable { let uin: Int; let token: String }

    static func ownHost() -> String {
        APIClient.shared.baseURL.host ?? RcqFederation.flagshipHost
    }

    /// `is2.rcq.app`, `https://is2.rcq.app/x` → `is2.rcq.app`.
    static func normalizeHost(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        let withScheme = t.contains("://") ? t : "https://\(t)"
        guard let host = URL(string: withScheme)?.host, !host.isEmpty else { return nil }
        return host
    }

    /// Re-authenticate on `host` by proving possession of the Ed25519 signing
    /// key (the seed-phrase recovery handshake). Returns nil when this identity
    /// never registered there (404); throws on other failures.
    static func recoverOn(host: String, signingPriv: Curve25519.Signing.PrivateKey) async throws -> Credentials? {
        struct ChallengeOut: Decodable { let challenge: String }
        let sk = signingPriv.publicKey.rawRepresentation.base64EncodedString()
        let challenge: ChallengeOut = try await post(
            "https://\(host)/auth/recover/challenge", json: ["signing_key": sk]
        )
        let signature = try RecoveryPhrase.signChallenge(signingPrivate: signingPriv, challenge: challenge.challenge)
        do {
            return try await post(
                "https://\(host)/auth/recover",
                json: ["signing_key": sk, "challenge": challenge.challenge, "signature": signature]
            )
        } catch HttpError.status(404, _) {
            return nil
        }
    }

    /// Register (or recover) this identity on `hostInput` as a backup home,
    /// persist it, and return it. The caller republishes the home-island record.
    static func addBackupIsland(ownUin: Int, hostInput: String, nickname: String, auto: Bool = false) async throws -> MultihomeStore.Home {
        guard let host = normalizeHost(hostInput) else { throw AddError.invalidHost }
        guard host != ownHost() else { throw AddError.primaryIsland }
        guard !MultihomeStore.shared.list(ownUin: ownUin).contains(where: { $0.host == host }) else {
            throw AddError.alreadyAdded
        }
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes),
              let idBytes = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let identityPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: idBytes) else {
            throw AddError.network("no keys")
        }
        do {
            // Recover-first: registering twice would mint a SECOND uin for the
            // same key on that island (no server-side uniqueness on keys).
            let creds: Credentials
            if let recovered = try await recoverOn(host: host, signingPriv: signingPriv) {
                creds = recovered
            } else {
                creds = try await post(
                    "https://\(host)/auth/register",
                    json: [
                        "nickname": nickname,
                        "identity_key": identityPriv.publicKey.rawRepresentation.base64EncodedString(),
                        "signing_key": signingPriv.publicKey.rawRepresentation.base64EncodedString(),
                    ],
                    // Ask to keep our primary number on this backup island
                    // (best-effort; server mints a fresh uin if it's taken).
                    extra: ["desired_uin": ownUin]
                )
            }
            let home = MultihomeStore.Home(
                ownUin: ownUin, host: host, uin: creds.uin, jwt: creds.token,
                addedAt: Date(), auto: auto ? true : nil
            )
            MultihomeStore.shared.save(home)
            return home
        } catch let e as AddError {
            throw e
        } catch {
            throw AddError.network(String(describing: error))
        }
    }

    // MARK: auto-pick — one toggle instead of typing a host

    // The auto-pick list is a SEPARATE, Ed25519-signed file (not servers.json):
    // the toggle silently registers a backup mailbox on whatever it picks, so a
    // tampered catalogue must not steer that. We verify the signature over the
    // EXACT bytes GitHub served, against the maintainer key already pinned for
    // relay-config. servers.json stays a display-only directory.
    private static let autoIslandsURL = URL(
        string: "https://raw.githubusercontent.com/rcq-messenger/rcq-servers/main/auto-islands.json"
    )!
    private static let autoIslandsSigURL = URL(
        string: "https://raw.githubusercontent.com/rcq-messenger/rcq-servers/main/auto-islands.json.sig"
    )!
    private static let autoIslandsPubKeyB64 = "TY834OFcBvtUqHcnVw/QrPBOaEAZo7a1GAmABMhjkT8="

    /// Pick a backup island from the SIGNED island list, minus our own island +
    /// already-added hosts; the FIRST healthy one in list order wins (the order
    /// is the project's preference). Returns nil when the list is unreachable,
    /// the signature fails, or no island responds (fail-safe: never
    /// auto-register on an unverified island).
    static func autoPickHost(ownUin: Int) async -> String? {
        guard let islands = await fetchSignedAutoIslands() else { return nil }
        let own = ownHost()
        let existing = Set(MultihomeStore.shared.list(ownUin: ownUin).map(\.host))
        for url in islands {
            guard let host = normalizeHost(url), host != own, !existing.contains(host) else { continue }
            if await healthy(host) { return host }
        }
        return nil
    }

    /// Fetch the signed list + signature and verify Ed25519 over the EXACT
    /// bytes against the pinned maintainer key. Returns nil on any failure.
    private static func fetchSignedAutoIslands() async -> [String]? {
        var jreq = URLRequest(url: autoIslandsURL); jreq.cachePolicy = .reloadIgnoringLocalCacheData
        var sreq = URLRequest(url: autoIslandsSigURL); sreq.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, r1) = try? await URLSession.shared.data(for: jreq),
              let (sigData, r2) = try? await URLSession.shared.data(for: sreq),
              (r1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              (r2 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let pubRaw = Data(base64Encoded: autoIslandsPubKeyB64),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw),
              let sigStr = String(data: sigData, encoding: .utf8),
              let sig = Data(base64Encoded: sigStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              pub.isValidSignature(sig, for: data)
        else { return nil }
        struct Doc: Decodable { let islands: [String] }
        return (try? JSONDecoder().decode(Doc.self, from: data))?.islands
    }

    private static func healthy(_ host: String) async -> Bool {
        guard let url = URL(string: "https://\(host)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// The toggle's ON action: pick a healthy catalogue island and register
    /// there (recover-first, same keys). Returns the chosen host; throws
    /// `AddError.noIsland` when nothing is reachable. The caller republishes
    /// the home-island record.
    static func enableAutoBackup(ownUin: Int, nickname: String) async throws -> String {
        guard let host = await autoPickHost(ownUin: ownUin) else { throw AddError.noIsland }
        _ = try await addBackupIsland(ownUin: ownUin, hostInput: host, nickname: nickname, auto: true)
        return host
    }

    /// The toggle's OFF action: forget every auto-picked home (manually-added
    /// islands stay). The caller republishes the record.
    static func disableAutoBackup(ownUin: Int) {
        for h in MultihomeStore.shared.list(ownUin: ownUin) where h.auto == true {
            MultihomeStore.shared.remove(ownUin: ownUin, host: h.host)
        }
    }

    /// PUT the signed record to every backup home (the primary PUT rides the
    /// authed APIClient). Best-effort per island; a 401 refreshes the token via
    /// recover once; 409 (stale ts) means an equal-or-newer record is there.
    static func publishToBackups(ownUin: Int, recordBody: Data) async {
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes) else { return }
        for home in MultihomeStore.shared.list(ownUin: ownUin) {
            do {
                try await putRecord(host: home.host, jwt: home.jwt, body: recordBody)
            } catch HttpError.status(401, _) {
                guard let fresh = try? await recoverOn(host: home.host, signingPriv: signingPriv) else { continue }
                MultihomeStore.shared.updateCreds(ownUin: ownUin, host: home.host, uin: fresh.uin, jwt: fresh.token)
                try? await putRecord(host: home.host, jwt: fresh.token, body: recordBody)
            } catch { /* island unreachable — next publish retries */ }
        }
    }

    // MARK: receive — poll the backup mailboxes

    private static var pollTask: Task<Void, Never>?
    private static var pollingFor: Int = 0

    /// Idempotently start the 30s backup poll. Deliberately independent of the
    /// primary socket: when the primary island is down, this loop IS the
    /// delivery path. An account switch restarts the loop for the new uin.
    static func startPolling(ownUin: Int) {
        if pollTask != nil && pollingFor == ownUin { return }
        pollTask?.cancel()
        pollingFor = ownUin
        pollTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await drainBackupQueues(ownUin: ownUin)
                // §5c: also drain the guest mailbox on every visited island
                // (cross-island groups spool their fan-out there).
                await CrossIslandGroups.drainVisitedQueues()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// Drain every backup mailbox into the normal ingest path (legacy fetch —
    /// the server advances the cursor on fetch; copies of primary-delivered
    /// messages are collapsed by the envelope-uuid dedup in MessageStore).
    /// MainActor because ingest + the unread/badge services are actor-isolated;
    /// the network awaits suspend rather than block.
    @MainActor
    static func drainBackupQueues(ownUin: Int) async {
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes) else { return }
        struct Row: Decodable {
            let envelope_type: String
            let payload: String
            let group_id: Int?
        }
        for home in MultihomeStore.shared.list(ownUin: ownUin) {
            var rows: [Row]? = try? await getQueue(host: home.host, jwt: home.jwt)
            if rows == nil {
                // Token may have expired — refresh via recover and retry once.
                guard let fresh = try? await recoverOn(host: home.host, signingPriv: signingPriv) else { continue }
                MultihomeStore.shared.updateCreds(ownUin: ownUin, host: home.host, uin: fresh.uin, jwt: fresh.token)
                rows = try? await getQueue(host: home.host, jwt: fresh.token)
            }
            guard let rows else { continue }
            for r in rows {
                // §5c: a group row in a BACKUP mailbox = that island also hosts
                // a group we joined (same identity = same mailbox) — file it
                // under the local alias, not the raw remote id.
                let gid = r.group_id.map { VisitedIslandsStore.shared.aliasFor(host: home.host, remoteId: $0) }
                let packet = WebSocketService.EnvelopePacket(
                    type: r.envelope_type,
                    payload: r.payload,
                    serverTime: Date(),
                    offline: true,
                    groupID: gid
                )
                guard let outcome = MessageService.shared.ingest(envelope: packet),
                      outcome.isNewContent else { continue }
                if case .peer(let uin) = outcome.thread {
                    let viewing = MessageBannerService.shared.isViewing(outcome.thread)
                    if !viewing {
                        ContactService.shared.incrementUnread(for: uin)
                        BadgeCounter.increment(threadKey: BadgeCounter.threadKey(peerUIN: uin))
                        BadgeCounter.syncIcon()
                    }
                }
            }
        }
    }

    // MARK: send — deposit a copy to the peer's OTHER homes

    /// Deposit a pre-sealed v=1 blob into each of the peer's homes other than
    /// our own island (their record, resolved from OUR island's open endpoint
    /// and verified against the contact's pinned signing key). Returns how many
    /// homes accepted; 0 for single-homed peers (today's universal case — the
    /// flagship send path stays byte-identical). Never throws.
    static func depositToExtraHomes(peerUin: Int, peerSigningKey: String, sealedV1: String) async -> Int {
        guard !peerSigningKey.isEmpty else { return 0 }
        let own = ownHost()
        let extra = await resolvePeerHomesCached(peerUin: peerUin, peerSigningKey: peerSigningKey)
            .filter { $0.host != own }
        guard !extra.isEmpty else { return 0 }
        var delivered = 0
        for h in extra {
            if await CrossIslandSender.deposit(host: h.host, uin: h.uin, payload: sealedV1) { delivered += 1 }
        }
        return delivered
    }

    // MARK: gossip mirror (address-mobility B1)
    // A peer's self-signed record is mirrorable by global identity (sk) so it
    // can be served from any honest island a contact uses. The server
    // re-verifies the signature on write; this client re-verifies on read —
    // gossip adds redundancy, not trust.

    /// Best-effort mirror a verified record's RAW bytes onto `host`'s gossip
    /// store. Never throws.
    static func mirrorRecord(host: String, body: Data) async {
        guard let url = URL(string: "https://\(host)/federation/gossip-record") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Fetch a peer's mirrored record by its Ed25519 signing key from `host`'s
    /// gossip store. Returns the decoded doc, or nil (404 / unreachable).
    static func fetchGossipRecord(host: String, signingKey: String) async -> [String: Any]? {
        guard let sk = signingKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://\(host)/federation/gossip-record?sk=\(sk)"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func homesOf(_ rec: [String: Any]) -> [RcqFederation.Home] {
        (rec["homes"] as? [[String: Any]] ?? []).compactMap { h in
            guard let host = h["host"] as? String, let uin = h["uin"] as? Int else { return nil }
            return RcqFederation.Home(host: host, uin: uin)
        }
    }

    /// Resolve a peer's home list. Sources, in order: (1) OUR island's by-uin
    /// owner record (peer is on / multi-homed onto us), seeded into our gossip
    /// store on success; (2) OUR island's GOSSIP mirror by sk (survives the
    /// peer's own island being blocked/gone). Verified against the peer's
    /// locally-pinned signing key. TTL cached; a total miss serves the stale cache.
    private static func resolvePeerHomesCached(peerUin: Int, peerSigningKey: String) async -> [RcqFederation.Home] {
        if let cached = MultihomeStore.shared.cachedPeerHomes(peerUin),
           Date().timeIntervalSince(cached.ts) < peerCacheTTL {
            return cached.homes
        }
        let own = ownHost()
        // (1) by-uin owner record on our island.
        if let url = URL(string: "https://\(own)/federation/island-record/\(peerUin)"),
           let (data, resp) = try? await URLSession.shared.data(from: url),
           let http = resp as? HTTPURLResponse {
            if http.statusCode == 404 {
                // Clean miss; still try gossip below before caching empty.
            } else if (200..<300).contains(http.statusCode),
                      let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      case .success(let rec) = RcqFederation.verifyRecord(doc, opts: .init(expectedIk: nil, expectedSk: peerSigningKey)) {
                await mirrorRecord(host: own, body: data)  // seed gossip for other islands
                let homes = homesOf(rec)
                MultihomeStore.shared.cachePeerHomes(peerUin, homes: homes)
                return homes
            }
        }
        // (2) gossip mirror by sk on our island.
        if let rec = await fetchGossipRecord(host: own, signingKey: peerSigningKey),
           case .success(let v) = RcqFederation.verifyRecord(rec, opts: .init(expectedIk: nil, expectedSk: peerSigningKey)) {
            let homes = homesOf(v)
            MultihomeStore.shared.cachePeerHomes(peerUin, homes: homes)
            return homes
        }
        // Nothing reachable: serve stale cache, else cache empty (single-homed).
        if let stale = MultihomeStore.shared.cachedPeerHomes(peerUin)?.homes { return stale }
        MultihomeStore.shared.cachePeerHomes(peerUin, homes: [])
        return []
    }

    /// Resolve a peer's homes from THEIR OWN island, mirror the verified record
    /// onto our island's gossip store, and fall back to our gossip mirror if
    /// their island is unreachable. The cross-island entry point.
    static func resolveAndMirrorHomes(peerHost: String, peerUin: Int, peerSigningKey: String) async -> [RcqFederation.Home] {
        let own = ownHost()
        if let url = URL(string: "https://\(peerHost)/federation/island-record/\(peerUin)"),
           let (data, resp) = try? await URLSession.shared.data(from: url),
           let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           case .success(let rec) = RcqFederation.verifyRecord(doc, opts: .init(expectedIk: nil, expectedSk: peerSigningKey)) {
            await mirrorRecord(host: own, body: data)
            return homesOf(rec)
        }
        if let rec = await fetchGossipRecord(host: own, signingKey: peerSigningKey),
           case .success(let v) = RcqFederation.verifyRecord(rec, opts: .init(expectedIk: nil, expectedSk: peerSigningKey)) {
            return homesOf(v)
        }
        return []
    }

    // MARK: raw HTTP helpers (arbitrary hosts — APIClient is pinned to the primary)

    enum HttpError: Error { case status(Int, String) }

    private static func post<T: Decodable>(_ urlString: String, json: [String: String?], extra: [String: Any] = [:]) async throws -> T {
        guard let url = URL(string: urlString) else { throw HttpError.status(0, "bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `extra` carries non-string fields (e.g. desired_uin: Int) so they
        // serialize as real JSON numbers, not quoted strings.
        var obj = json.compactMapValues { $0 } as [String: Any]
        for (k, v) in extra { obj[k] = v }
        req.httpBody = try JSONSerialization.data(withJSONObject: obj)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HttpError.status(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw HttpError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func putRecord(host: String, jwt: String, body: Data) async throws {
        guard let url = URL(string: "https://\(host)/federation/island-record") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HttpError.status(0, "no response") }
        // 409 = an equal-or-newer record is already there; fine.
        guard (200..<300).contains(http.statusCode) || http.statusCode == 409 else {
            throw HttpError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func getQueue<T: Decodable>(host: String, jwt: String) async throws -> T {
        guard let url = URL(string: "https://\(host)/messages/queue") else { throw HttpError.status(0, "bad url") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HttpError.status((resp as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
