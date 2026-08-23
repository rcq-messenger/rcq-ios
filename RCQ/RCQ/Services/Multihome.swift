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
    /// `recTs` is the signed record's OWN ts (Unix seconds, 0 if unknown), the
    /// anti-rollback floor for a self-pushed record (gossip B1).
    struct PeerHomes {
        let homes: [RcqFederation.Home]
        let ts: Date
        var recTs: Int = 0
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
        return PeerHomes(homes: s.homes.map { RcqFederation.Home(host: $0.host, uin: $0.uin) }, ts: s.ts, recTs: s.recTs ?? 0)
    }

    func cachePeerHomes(_ peerUin: Int, homes: [RcqFederation.Home], recTs: Int = 0) {
        var map: [String: StoredPeer] = [:]
        if let data = defaults.data(forKey: Self.peerCacheKey),
           let m = try? JSONDecoder().decode([String: StoredPeer].self, from: data) {
            map = m
        }
        map[String(peerUin)] = StoredPeer(homes: homes.map { CodableHome(host: $0.host, uin: $0.uin) }, ts: Date(), recTs: recTs)
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.peerCacheKey) }
    }

    private struct StoredPeer: Codable { let homes: [CodableHome]; let ts: Date; let recTs: Int? }
}

enum Multihome {

    /// How long a resolved peer-homes entry stays fresh; stale entries still
    /// serve as the failover route when the primary island is unreachable.
    private static let peerCacheTTL: TimeInterval = 10 * 60

    enum AddError: Error { case invalidHost, primaryIsland, alreadyAdded, noIsland, network(String) }

    struct Credentials: Decodable { let uin: Int; let token: String }

    /// This account's ISLAND IDENTITY — the host that belongs in a share link
    /// and that peers stamp into their envelopes.
    ///
    /// ⚠ This used to read `APIClient.shared.baseURL.host`, which is the
    /// TRANSPORT, not the identity. When the direct probe fails the transport
    /// silently becomes the Cloudflare front (`cdn.rcq.app`), and every
    /// same-island peer then looked foreign: their messages were quarantined as
    /// cross-island "message requests", accepting one filed them under a second
    /// identity in `CrossIslandStore`, and they showed up twice — once in the
    /// roster, once under "other islands". The share links and QR codes minted
    /// while the front was active carried `…@cdn.rcq.app` for the same reason.
    /// Android hit this first and fixed it on its side (`ownHosts` in
    /// Session.kt); this is the iOS half.
    ///
    /// `activeDirectBase()` is the island the user actually targets (a custom
    /// island if one is selected, else the flagship) and never the front.
    static func ownHost() -> String {
        normalizeHost(APIClient.activeDirectBase())
            ?? APIClient.shared.baseURL.host
            ?? RcqFederation.flagshipHost
    }

    /// Is `host` one of the names for OUR island? True for the identity above,
    /// for whatever transport is in use right now, and for the Cloudflare
    /// fronts — a peer on an older build stamps the host it was connected
    /// through, and it is not their fault we have several names.
    ///
    /// Use this for every "same island or not" decision. Plain `== ownHost()`
    /// is only right when minting a link.
    static func isOwnHost(_ host: String?) -> Bool {
        guard let host = normalizeHost(host ?? "") else { return true }  // nil host = local
        var names: Set<String> = [ownHost().lowercased()]
        if let transport = APIClient.shared.baseURL.host { names.insert(transport.lowercased()) }
        if let front = RelayConfigStore.frontHost, let n = normalizeHost(front) { names.insert(n) }
        if let builtIn = normalizeHost(APIClient.builtInProxyURL) { names.insert(builtIn) }
        return names.contains(host)
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
        // isOwnHost, not == ownHost(): the Cloudflare front is the flagship by
        // another road, and "adding" it registers a second mailbox on the
        // island this account already lives on. Same refusal as the primary,
        // because that is what it is.
        guard !isOwnHost(host) else { throw AddError.primaryIsland }
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
                let sk = signingPriv.publicKey.rawRepresentation.base64EncodedString()
                // ⚠ The number is only handed out under proof of the signing
                // key now. Without the signature the island still registers us,
                // but on a fresh number, and "one number everywhere" quietly
                // stops being true. An island too old to know the endpoint
                // 404s and we register the way we always did.
                struct ChallengeOut: Decodable { let challenge: String }
                var extra: [String: Any] = ["desired_uin": ownUin]
                if let chal: ChallengeOut = try? await post(
                    "https://\(host)/auth/register/challenge", json: ["signing_key": sk]
                ), let sig = try? RecoveryPhrase.signChallenge(
                    signingPrivate: signingPriv, challenge: chal.challenge
                ) {
                    extra["challenge"] = chal.challenge
                    extra["signature"] = sig
                }
                creds = try await post(
                    "https://\(host)/auth/register",
                    json: [
                        "nickname": nickname,
                        "identity_key": identityPriv.publicKey.rawRepresentation.base64EncodedString(),
                        "signing_key": sk,
                    ],
                    extra: extra
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
    // Verified against the ISLAND_LIST role in `SigningKeys` — its own role,
    // because steering a backup mailbox and steering a tunnel are different
    // powers and should not stay welded to one key.

    /// Pick a backup island from the SIGNED island list, minus our own island +
    /// already-added hosts; the FIRST healthy one in list order wins (the order
    /// is the project's preference). Returns nil when the list is unreachable,
    /// the signature fails, or no island responds (fail-safe: never
    /// auto-register on an unverified island).
    static func autoPickHost(ownUin: Int) async -> String? {
        guard let islands = await fetchSignedAutoIslands() else { return nil }
        let existing = Set(MultihomeStore.shared.list(ownUin: ownUin).map(\.host))
        for url in islands {
            // isOwnHost also skips the Cloudflare fronts: a front in the
            // catalogue would auto-register a "backup" on our own island.
            guard let host = normalizeHost(url), !isOwnHost(host), !existing.contains(host) else { continue }
            if await healthy(host) { return host }
        }
        return nil
    }

    /// Fetch the signed list + signature and verify Ed25519 over the EXACT
    /// bytes against the pinned maintainer key. Returns nil on any failure.
    private static func fetchSignedAutoIslands() async -> [String]? {
        var jreq = URLRequest(url: autoIslandsURL); jreq.cachePolicy = .reloadIgnoringLocalCacheData
        var sreq = URLRequest(url: autoIslandsSigURL); sreq.cachePolicy = .reloadIgnoringLocalCacheData
        // GitHub, not an island: ride an already-running tunnel, but never
        // turn one ON because a third party is unreachable.
        guard let (data, r1) = try? await IslandHTTP.data(for: jreq, allowTunnelFallback: false),
              let (sigData, r2) = try? await IslandHTTP.data(for: sreq, allowTunnelFallback: false),
              (r1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              (r2 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let sigStr = String(data: sigData, encoding: .utf8),
              SigningKeys.verify(.islandList, message: data,
                                 signatureB64: sigStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        struct Doc: Decodable { let islands: [String] }
        return (try? JSONDecoder().decode(Doc.self, from: data))?.islands
    }

    private static func healthy(_ host: String) async -> Bool {
        guard let url = URL(string: "https://\(host)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (_, resp) = try? await IslandHTTP.data(for: req),
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

    /// Drop every stored backup home that is a front alias or the primary
    /// island itself — phantoms adopted before `isOwnHost` guarded the paths
    /// above. Returns true when anything was removed, so the caller knows the
    /// record it publishes just changed. ⚠ Run BEFORE the publish reads the
    /// stored homes: the island rejects a record naming its own front (server
    /// 2026.08.21.2), so one phantom row would cost the whole publish — and
    /// the phantom's queue drain must end in THIS session, not the next one.
    @discardableResult
    static func scrubFrontAliasHomes(ownUin: Int) -> Bool {
        var removed = false
        for h in MultihomeStore.shared.list(ownUin: ownUin) where isOwnHost(h.host) {
            MultihomeStore.shared.remove(ownUin: ownUin, host: h.host)
            removed = true
        }
        return removed
    }

    /// PUT the signed record to every backup home (the primary PUT rides the
    /// authed APIClient). Best-effort per island; a 401 refreshes the token via
    /// recover once; 409 (stale ts) means an equal-or-newer record is there.
    static func publishToBackups(ownUin: Int, recordBody: Data) async {
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes) else { return }
        for home in MultihomeStore.shared.list(ownUin: ownUin) {
            if isOwnHost(home.host) { continue }  // a phantom row PUTs to our own island
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
            // Stage 2: served alongside the legacy fields; optional so an older
            // backup island still decodes, and read only for future ordering. A
            // backup mailbox drains on the server's fetch cursor, not on `seq`.
            let cls: Int?
            let seq: Int?
        }
        for home in MultihomeStore.shared.list(ownUin: ownUin) {
            // ⚠ A phantom front home is OUR OWN island: draining it hits the
            // account's real queue through the front with an unnamed recover
            // token — the "primary" device cursor — and this legacy fetch
            // advances that cursor with no ack. Rows it takes never reach the
            // ack-protected main drain. Never drain through a front.
            if isOwnHost(home.host) { continue }
            var jwt = home.jwt
            var rows: [Row]? = try? await getQueue(host: home.host, jwt: jwt)
            if rows == nil {
                // Token may have expired: refresh via recover and retry once.
                guard let fresh = try? await recoverOn(host: home.host, signingPriv: signingPriv) else { continue }
                MultihomeStore.shared.updateCreds(ownUin: ownUin, host: home.host, uin: fresh.uin, jwt: fresh.token)
                jwt = fresh.token
                rows = try? await getQueue(host: home.host, jwt: jwt)
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
            // Stage 5: the rooms this island hosts for us live in its log
            // once it keeps one, the same as on a visited island, and once
            // any client of this account has read that log the backup
            // mailbox carries no room rows at all. Same per-host question,
            // same drain, same alias, with the token the queue read ended
            // up with. An island without the flag sees neither call.
            if await CrossIslandGroups.hostKeepsGroupLog(home.host) {
                await CrossIslandGroups.drainGroupLog(host: home.host, jwt: jwt)
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
        // isOwnHost, not != ownHost(): a front in a PEER's record is our own
        // island by another road — an "extra" copy deposited there just
        // doubles the rows in the queue the primary send already reached.
        let extra = await resolvePeerHomesCached(peerUin: peerUin, peerSigningKey: peerSigningKey)
            .filter { !isOwnHost($0.host) }
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
        _ = try? await IslandHTTP.data(for: req)
    }

    /// Fetch a peer's mirrored record by its Ed25519 signing key from `host`'s
    /// gossip store. Returns the decoded doc, or nil (404 / unreachable).
    static func fetchGossipRecord(host: String, signingKey: String) async -> [String: Any]? {
        guard let sk = signingKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://\(host)/federation/gossip-record?sk=\(sk)"),
              let (data, resp) = try? await IslandHTTP.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func homesOf(_ rec: [String: Any]) -> [RcqFederation.Home] {
        (rec["homes"] as? [[String: Any]] ?? []).compactMap { h in
            guard let host = h["host"] as? String, let uin = h["uin"] as? Int else { return nil }
            return RcqFederation.Home(host: host, uin: uin)
        }
    }

    private static func tsOf(_ rec: [String: Any]) -> Int { rec["ts"] as? Int ?? 0 }

    /// The homes OUR OWN published record already lists, verified against our
    /// own signing key. Empty when there is no record yet, when it does not
    /// verify, or when the island cannot be reached.
    ///
    /// ⚠⚠ The homes list is an ACCOUNT-wide fact, and this install only ever
    /// knew its own local half of it: a backup island switched on in the web,
    /// or on another phone, is not in `MultihomeStore` here. Republishing that
    /// half alone PUT a record without it under a fresh `ts`, and the island
    /// rejects only an OLDER ts — so this device quietly unpublished the other
    /// one's backup and senders stopped being told the mailbox exists. Reading
    /// before publishing is what keeps one device from undoing another's work.
    static func ownPublishedHomes(ownUin: Int, ownSigningKey: String) async -> [RcqFederation.Home] {
        guard let url = URL(string: "https://\(ownHost())/federation/island-record/\(ownUin)"),
              let (data, resp) = try? await IslandHTTP.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              case .success(let rec) = RcqFederation.verifyRecord(doc, opts: .init(expectedIk: nil, expectedSk: ownSigningKey))
        else { return [] }
        return homesOf(rec)
    }

    /// Apply a contact's SELF-PUSHED home-island record (gossip B1): verify it
    /// is signed by `senderSigningKey` (the same Ed25519 key that signed the
    /// envelope it arrived in — binds the record to its real sender), reject a
    /// ts rollback against what we've cached, and cache the homes for future
    /// sends. Returns true when the cache was updated. Never throws.
    @discardableResult
    static func applyPushedRecord(senderUIN: Int, senderSigningKey: String, rec: Envelope.IslandRecordWire) -> Bool {
        guard let data = try? JSONEncoder().encode(rec),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let prevTs = MultihomeStore.shared.cachedPeerHomes(senderUIN)?.recTs ?? 0
        let opts = RcqFederation.VerifyOpts(expectedSk: senderSigningKey, minTs: prevTs > 0 ? prevTs : nil)
        guard case .success(let v) = RcqFederation.verifyRecord(doc, opts: opts) else { return false }
        MultihomeStore.shared.cachePeerHomes(senderUIN, homes: homesOf(v), recTs: tsOf(v))
        return true
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
           let (data, resp) = try? await IslandHTTP.data(from: url),
           let http = resp as? HTTPURLResponse {
            if http.statusCode == 404 {
                // Clean miss; still try gossip below before caching empty.
            } else if (200..<300).contains(http.statusCode),
                      let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      case .success(let rec) = RcqFederation.verifyRecord(doc, opts: .init(expectedIk: nil, expectedSk: peerSigningKey)) {
                await mirrorRecord(host: own, body: data)  // seed gossip for other islands
                let homes = homesOf(rec)
                MultihomeStore.shared.cachePeerHomes(peerUin, homes: homes, recTs: tsOf(rec))
                return homes
            }
        }
        // (2) gossip mirror by sk on our island.
        if let rec = await fetchGossipRecord(host: own, signingKey: peerSigningKey),
           case .success(let v) = RcqFederation.verifyRecord(rec, opts: .init(expectedIk: nil, expectedSk: peerSigningKey)) {
            let homes = homesOf(v)
            MultihomeStore.shared.cachePeerHomes(peerUin, homes: homes, recTs: tsOf(v))
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
           let (data, resp) = try? await IslandHTTP.data(from: url),
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
        let (data, resp) = try await IslandHTTP.data(for: req)
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
        let (data, resp) = try await IslandHTTP.data(for: req)
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
        let (data, resp) = try await IslandHTTP.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HttpError.status((resp as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Persistent sender-key chain state (group encrypt-once). Outbound chains
/// (one per group I post to) + inbound chains (one per kid handed via SKDM).
/// Mirrors the web sender-key-store.ts and Android GroupSenderKeyStore. App-group
/// UserDefaults like MultihomeStore; chain keys are base64 on disk. The NSE
/// never writes here (it can't advance the ratchet out-of-process); only the
/// app mutates this. Scoped by `ownUin` so a multi-account device never mixes
/// an outbound chain across accounts.
final class GroupSenderKeyStore {
    static let shared = GroupSenderKeyStore()

    private struct OutChain: Codable {
        let kid: String
        let epoch: Int
        var index: Int
        var ck: String
        var distributed: [Int]
    }
    private struct InChain: Codable {
        let gid: Int
        let senderUin: Int
        var spub: String
        let epoch: Int
        var index: Int
        var ck: String
        var skipped: [Int: String]
    }

    private static let appGroup = "group.app.rcq.shared"
    private static let outKey = "rcq.senderkeys.out.v1"   // [ "<ownUin>:<gid>" : OutChain ]
    /// ⚠⚠ Keyed "<ownUin>:<kid>", NOT bare kid, and v2 because v1 was the bare
    /// kid and its contents cannot be attributed to an account after the fact.
    ///
    /// A device with two accounts receives the SAME kid twice — once addressed
    /// to each — and each copy has to be ratcheted separately. Sharing one
    /// chain meant whichever account read the group first advanced it and ate
    /// the skipped keys, and the other account then hit `index < c.index` and
    /// could open NOTHING from that point on. Worse, `acceptSkdm` answered
    /// "accepted" for the second account's distribution (the chain was already
    /// at or past that index), so the client acked the key and then failed on
    /// the very message the key was for.
    ///
    /// The founder's second account lost nine days of a group this way, and it
    /// looked like the group simply stopped on a date (2026-08-13).
    private static let inKey = "rcq.senderkeys.in.v2"     // [ "<ownUin>:<kid>" : InChain ]
    /// ⚠⚠ Same lesson as `inKey`, learned a third time (web senderkeys v3,
    /// 2026-08-21): v1 held the bare kid, shared across accounts. With two
    /// accounts on one device, account B matched account A's broadcast against
    /// this list, took it for its own echo and silently dropped it, so B never
    /// saw a single group message A posted. Entries are account-scoped now.
    private static let ownedKey = "rcq.senderkeys.owned.v2" // [ "<ownUin>:<kid>" ] rolling
    private static let legacyOwnedKey = "rcq.senderkeys.owned.v1"
    private static let ownedCap = 64

    private let defaults: UserDefaults
    private let lock = NSLock()
    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        migrateOwnSideIfNeeded()
    }

    /// One-time reset of the OWN side when the unscoped v1 owned-kid list is
    /// found. Its bare kids cannot be attributed to an account after the fact,
    /// so they are dropped rather than migrated, and the outbound chains go
    /// with them: a chain whose kid sits in no owned list would make us NACK
    /// the group over our own next echoed broadcast. The next post per group
    /// simply rotates to a fresh kid and redistributes an SKDM, which
    /// recipients take in stride. Inbound chains are preserved on purpose:
    /// wiping them would blind us to every known sender until a NACK
    /// round-trip per chain (a NACK storm).
    private func migrateOwnSideIfNeeded() {
        guard defaults.object(forKey: Self.ownedKey) == nil,
              defaults.object(forKey: Self.legacyOwnedKey) != nil else { return }
        defaults.removeObject(forKey: Self.outKey)
        defaults.removeObject(forKey: Self.legacyOwnedKey)
        defaults.set([String](), forKey: Self.ownedKey)
    }

    // The decoded maps, kept in memory after the first read.
    //
    // Every load used to JSON-decode the WHOLE map and every save re-encode
    // it, and opening one group broadcast does up to two loads and one save
    // (`ownsKid`, `deriveInbound`, and `knowsKid` when the chain is unknown).
    // Draining a room's backlog paid that per message.
    //
    // Safe to cache because this process is the only writer: the store lives
    // in the App Group container, but `Multihome.swift` is not in the
    // notification-extension target (the NSE opens sealed 1:1 envelopes, never
    // `gmsg`), so nothing outside this class can move a chain under it.
    //
    // ⚠ CACHE, NOT BUFFER. Every save still writes through to UserDefaults on
    // the spot. A chain is ratchet state: holding writes back to batch them
    // would mean a kill between the derive and the flush leaves the chain
    // behind where the messages it opened already are.
    //
    // Guarded by `lock`, which every reader and writer below now takes.
    private var outCache: [String: OutChain]?
    private var inCache: [String: InChain]?
    private var ownedCache: [String]?

    private func loadOut() -> [String: OutChain] {
        if let outCache { return outCache }
        guard let d = defaults.data(forKey: Self.outKey),
              let m = try? JSONDecoder().decode([String: OutChain].self, from: d) else {
            outCache = [:]
            return [:]
        }
        outCache = m
        return m
    }
    private func saveOut(_ m: [String: OutChain]) {
        outCache = m
        if let d = try? JSONEncoder().encode(m) { defaults.set(d, forKey: Self.outKey) }
    }
    private func loadIn() -> [String: InChain] {
        if let inCache { return inCache }
        guard let d = defaults.data(forKey: Self.inKey),
              let m = try? JSONDecoder().decode([String: InChain].self, from: d) else {
            inCache = [:]
            return [:]
        }
        inCache = m
        return m
    }
    private func saveIn(_ m: [String: InChain]) {
        inCache = m
        if let d = try? JSONEncoder().encode(m) { defaults.set(d, forKey: Self.inKey) }
    }
    private func loadOwned() -> [String] {
        if let ownedCache { return ownedCache }
        let l = (defaults.array(forKey: Self.ownedKey) as? [String]) ?? []
        ownedCache = l
        return l
    }
    private func saveOwned(_ l: [String]) {
        ownedCache = l
        defaults.set(l, forKey: Self.ownedKey)
    }

    private func outK(_ ownUin: Int, _ gid: Int) -> String { "\(ownUin):\(gid)" }
    private func inK(_ ownUin: Int, _ kid: String) -> String { "\(ownUin):\(kid)" }
    private func ownedK(_ ownUin: Int, _ kid: String) -> String { "\(ownUin):\(kid)" }

    struct OwnSendStep {
        let kid: String
        let epoch: Int
        let index: Int
        let mk: Data
        let needDistribution: [Int]
        let ckAtI: String
    }

    /// Resolve the outbound chain for a group send. Rotates (fresh kid, e+1,
    /// i=0) when a previously-distributed member is gone (forward secrecy).
    /// Caller MUST call `advanceOwn` after the broadcast lands.
    func prepareOwnSend(ownUin: Int, gid: Int, capableUins: [Int]) -> OwnSendStep {
        lock.lock(); defer { lock.unlock() }
        var out = loadOut()
        let k = outK(ownUin, gid)
        let capable = Set(capableUins)
        var c = out[k]
        let rotate = c == nil || c!.distributed.contains { !capable.contains($0) }
        if rotate {
            let kid = SenderKeys.newKid()
            c = OutChain(kid: kid, epoch: (c?.epoch ?? -1) + 1, index: 0,
                         ck: SenderKeys.randomChainKey().base64EncodedString(), distributed: [])
            let entry = ownedK(ownUin, kid)
            var owned = loadOwned().filter { $0 != entry }
            owned.insert(entry, at: 0)
            saveOwned(Array(owned.prefix(Self.ownedCap)))
        }
        out[k] = c!
        saveOut(out)
        let ckData = Data(base64Encoded: c!.ck) ?? Data()
        let mk = SenderKeys.deriveMessageKey(ckData)
        let need = capableUins.filter { !c!.distributed.contains($0) }
        return OwnSendStep(kid: c!.kid, epoch: c!.epoch, index: c!.index, mk: mk, needDistribution: need, ckAtI: c!.ck)
    }

    func markDistributed(ownUin: Int, gid: Int, uins: [Int]) {
        lock.lock(); defer { lock.unlock() }
        var out = loadOut()
        guard var c = out[outK(ownUin, gid)] else { return }
        var set = Set(c.distributed); uins.forEach { set.insert($0) }
        c.distributed = Array(set)
        out[outK(ownUin, gid)] = c
        saveOut(out)
    }

    func advanceOwn(ownUin: Int, gid: Int) {
        lock.lock(); defer { lock.unlock() }
        var out = loadOut()
        guard var c = out[outK(ownUin, gid)], let ck = Data(base64Encoded: c.ck) else { return }
        c.ck = SenderKeys.nextChainKey(ck).base64EncodedString()
        c.index += 1
        out[outK(ownUin, gid)] = c
        saveOut(out)
    }

    /// Store / refresh an inbound chain from an SKDM, bound to its
    /// authenticated sender. Returns false if a known kid is claimed by a
    /// DIFFERENT sender (rejected).
    @discardableResult
    func acceptSkdm(ownUin: Int, kid: String, gid: Int, senderUIN: Int, spub: String, epoch: Int, index: Int, ck: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = inK(ownUin, kid)
        var inn = loadIn()
        if let ex = inn[k], ex.senderUin != senderUIN { return false }
        if var ex = inn[k], ex.epoch == epoch, ex.index >= index {
            ex.spub = spub; inn[k] = ex; saveIn(inn); return true
        }
        inn[k] = InChain(gid: gid, senderUin: senderUIN, spub: spub, epoch: epoch, index: index, ck: ck, skipped: [:])
        saveIn(inn)
        return true
    }

    struct InboundKey { let mk: Data; let spub: String; let senderUin: Int }

    /// Derive the message key for (kid, epoch, index), ratcheting forward and
    /// caching skipped keys. nil when the kid is unknown (caller should NACK),
    /// the epoch mismatches, the index is in the past with no cached key
    /// (replay), or it's beyond MAX_SKIP.
    func deriveInbound(ownUin: Int, kid: String, epoch: Int, index: Int) -> InboundKey? {
        lock.lock(); defer { lock.unlock() }
        let k = inK(ownUin, kid)
        var inn = loadIn()
        guard var c = inn[k], c.epoch == epoch else { return nil }
        if let cached = c.skipped[index], let mk = Data(base64Encoded: cached) {
            c.skipped[index] = nil; inn[k] = c; saveIn(inn)
            return InboundKey(mk: mk, spub: c.spub, senderUin: c.senderUin)
        }
        if index < c.index { return nil }
        if index - c.index > SenderKeys.MAX_SKIP { return nil }
        guard var ck = Data(base64Encoded: c.ck) else { return nil }
        var idx = c.index
        while idx < index {
            c.skipped[idx] = SenderKeys.deriveMessageKey(ck).base64EncodedString()
            ck = SenderKeys.nextChainKey(ck)
            idx += 1
        }
        let mk = SenderKeys.deriveMessageKey(ck)
        c.ck = SenderKeys.nextChainKey(ck).base64EncodedString()
        c.index = index + 1
        inn[k] = c
        saveIn(inn)
        return InboundKey(mk: mk, spub: c.spub, senderUin: c.senderUin)
    }

    // These four were lock-free while every read went straight to UserDefaults.
    // The maps live in memory now, so they take the lock like everybody else.
    // None of them calls another method that takes it.
    func knowsKid(ownUin: Int, _ kid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadIn()[inK(ownUin, kid)] != nil
    }
    /// Only THIS account's kids count as own: another local account's
    /// broadcast must be decoded like anybody else's, not eaten as an echo.
    func ownsKid(ownUin: Int, _ kid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadOwned().contains(ownedK(ownUin, kid))
    }
    func ownKidForGroup(ownUin: Int, gid: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadOut()[outK(ownUin, gid)]?.kid
    }

    struct OwnSnapshot { let kid: String; let epoch: Int; let index: Int; let ck: String }
    func ownChainSnapshot(ownUin: Int, gid: Int) -> OwnSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let c = loadOut()[outK(ownUin, gid)] else { return nil }
        return OwnSnapshot(kid: c.kid, epoch: c.epoch, index: c.index, ck: c.ck)
    }

    // MARK: held broadcasts (Stage 5 room log)

    /// One `gmsg` the room log served before the SKDM carrying its sender
    /// key did. Kept exactly as it came off the wire, so the replay goes
    /// through the normal decode; `epoch`/`index` only serve the dedup.
    /// Mirrors web held-gmsg.ts and Android heldGmsg, on disk rather than in
    /// memory because the row is ACKED once held: the island's cursor has
    /// moved past it, and a relaunch before the key lands would otherwise
    /// lose the message for good.
    struct HeldGmsg: Codable {
        let gid: Int
        let kid: String
        let epoch: Int
        let index: Int
        let payload: String
        let serverTime: Date
        /// When this install parked it, for the age limit; `serverTime` is
        /// when the island took the post, which a long-offline device can
        /// meet weeks later. Optional so an entry written before the field
        /// existed still decodes (it then ages by `serverTime`).
        var heldAt: Date?
    }

    private static let heldKey = "rcq.senderkeys.held.v1"   // [ "<ownUin>" : [HeldGmsg] ]
    /// Entries past this are evicted, oldest first from the kid that holds
    /// the most. Fifty unreadable broadcasts on one account is already a
    /// broken room, and the bound keeps a flood of un-openable rows cheap.
    private static let heldCap = 50
    /// A hold older than this is dead. A NACK for the kid goes out every
    /// ten minutes while rows keep failing, and an owner who has not
    /// answered in a week is not going to: that is what a broadcast from
    /// another install of OUR OWN account looks like (it never sends us its
    /// SKDM; the carbon carries the message instead), and without the age
    /// limit every such post stays here for good and crowds out rows that
    /// are genuinely waiting on a key.
    private static let heldMaxAge: TimeInterval = 7 * 24 * 3600

    private func loadHeld() -> [String: [HeldGmsg]] {
        guard let d = defaults.data(forKey: Self.heldKey),
              let m = try? JSONDecoder().decode([String: [HeldGmsg]].self, from: d) else { return [:] }
        return m
    }
    private func saveHeld(_ m: [String: [HeldGmsg]]) {
        if let d = try? JSONEncoder().encode(m) { defaults.set(d, forKey: Self.heldKey) }
    }

    /// Park one broadcast whose kid is unknown here. Deduped by chain
    /// position (kid, epoch, index): the same row can be served by the log
    /// and arrive live while the key is still missing, and only one copy can
    /// ever derive a message key.
    func holdGmsg(ownUin: Int, _ entry: HeldGmsg) {
        lock.lock(); defer { lock.unlock() }
        var all = loadHeld()
        let cutoff = Date().addingTimeInterval(-Self.heldMaxAge)
        var list = (all[String(ownUin)] ?? []).filter { ($0.heldAt ?? $0.serverTime) > cutoff }
        if list.contains(where: { $0.kid == entry.kid && $0.epoch == entry.epoch && $0.index == entry.index }) { return }
        var stamped = entry
        stamped.heldAt = Date()
        list.append(stamped)
        // Over the cap, the kid with the most rows gives up its oldest: one
        // kid nobody will ever answer for must not evict the others.
        while list.count > Self.heldCap {
            var perKid: [String: Int] = [:]
            for h in list { perKid[h.kid, default: 0] += 1 }
            guard let worst = perKid.max(by: { $0.value < $1.value })?.key,
                  let idx = list.firstIndex(where: { $0.kid == worst }) else { break }
            list.remove(at: idx)
        }
        all[String(ownUin)] = list
        saveHeld(all)
    }

    /// Remove and return every broadcast held under `kid`, in arrival order.
    /// Entries held for other kids stay put.
    func takeHeldGmsg(ownUin: Int, kid: String) -> [HeldGmsg] {
        lock.lock(); defer { lock.unlock() }
        var all = loadHeld()
        guard let list = all[String(ownUin)], !list.isEmpty else { return [] }
        let taken = list.filter { $0.kid == kid }
        if taken.isEmpty { return [] }
        let rest = list.filter { $0.kid != kid }
        all[String(ownUin)] = rest.isEmpty ? nil : rest
        saveHeld(all)
        return taken
    }
}
