import CryptoKit
import Foundation
import _CryptoExtras

/// F3 deposit-auth client: mints + caches anonymous blinded deposit tokens (RFC
/// 9474 RSABSSA via swift-crypto `_CryptoExtras`) to attach to cross-island sealed
/// deposits, so the recipient island can rate-limit us WITHOUT learning who we are.
/// See `RCQ/docs/deposit-auth-design.md` + `rcq-server-ref app/routers/deposit_auth.py`.
///
/// Stage 3 of the metadata plan spends the same token on the OWN island: a bundle
/// fetch that carries one in `X-Deposit-Token` (see `headerValue`) takes a one-time
/// prekey without a session token, so the island never learns whose keys this
/// account was reading. Same store, same mint; `host` is simply our own island then.
///
/// Per island host: GET /deposit-auth/params (epoch pubkey SPKI + PoW difficulty);
/// blind a random message, solve the SHA-256 hashcash bound to the blinded value,
/// POST /deposit-auth/issue, unblind -> a token. Minted into an in-memory reserve
/// by ONE refill task per host, one token at a time, the hashcash off the actor:
/// a caller that finds the reserve empty gets the first token the moment it is
/// finalised, and the reserve fills up to `batch` behind it, so the send never
/// waits on a whole batch and concurrent callers never solve a batch each. Self-
/// gating: an island without deposit-auth (404 on /params) is rested for ten
/// minutes and skipped; a failure just yields nil and the deposit rides the
/// legacy per-IP path (additive).
///
/// We use the DETERMINISTIC (identity-preparation) RFC 9474 variant and supply our
/// OWN random message bytes, so we know the `prepared` bytes to send the server
/// (swift-crypto keeps the randomized variant's prefix internal). The server's PSS
/// verify is preparation-agnostic, and the wire is the same standard RSA-PSS proven
/// to interoperate Python<->Android (BlindTokenTest).
actor DepositAuthStore {
    static let shared = DepositAuthStore()
    private init() {}

    private struct Params { let epochId: String; let der: Data; let difficulty: Int }
    /// Where and how to mint for a host: the origin `/deposit-auth/*` hangs off
    /// (scheme, host, optional path prefix) and the closed-island gate token.
    /// Remembered per host because the refill runs on after the caller that
    /// started it has left.
    private struct Route { let base: String; let masquerade: String? }
    private var params: [String: Params] = [:]
    private var routes: [String: Route] = [:]
    /// Hosts whose `/params` answered 404, and when to ask them again. A rest,
    /// not a verdict: a deploy window, a front that does not forward the path
    /// or a 404 page behind a manual proxy base all look exactly like "no
    /// deposit-auth here", and for the OWN island that used to pin every
    /// bundle fetch to the session token until the next launch.
    private var rested: [String: Date] = [:]
    private var reserve: [String: [[String: String]]] = [:]
    /// The one refill per host (single-flight). Callers that find the reserve
    /// empty while it runs queue up as `waiters` for its next token rather
    /// than each solving a batch of their own and overwriting each other's.
    private var refills: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [CheckedContinuation<[String: String]?, Never>]] = [:]
    private let batch = 4
    private static let restFor: TimeInterval = 10 * 60

    /// A `deposit_token` `{epoch_id, prepared, sig}` for `host`, or nil when the
    /// island doesn't offer deposit-auth or minting failed.
    ///
    /// `masquerade` is the closed-island `X-RCQ-Auth` token when `host` is the
    /// OWN island: that one lives on `APIClient`, not in `AccessTokenStore`, so
    /// the mint would otherwise knock on a closed island's door unstamped and
    /// read the decoy as "no deposit-auth here". `base` is the origin to mint
    /// at when it is not plain `https://host`: the own island's active base
    /// URL, so a proxy base with a path prefix mints through the same route
    /// the API calls take.
    ///
    /// Returns as soon as a token exists: from the reserve, or the next one the
    /// refill finalises. The refill keeps going in the background until the
    /// reserve holds `batch` again.
    func tokenFor(host: String, masquerade: String? = nil, base: String? = nil) async -> [String: String]? {
        routes[host] = Route(base: base ?? "https://\(host)", masquerade: masquerade)
        if resting(host) { return nil }
        if let t = pop(host: host) {
            topUp(host: host)
            return t
        }
        return await withCheckedContinuation { c in
            waiters[host, default: []].append(c)
            topUp(host: host)
        }
    }

    /// Fill the reserve for `host` ahead of the first fetch. Stage 3 calls it
    /// as soon as the island's capabilities say it serves key lookups against
    /// these tokens, so the first message to a new peer does not sit on a
    /// proof of work. One background batch, nothing if one is already there.
    func prewarm(host: String, masquerade: String? = nil, base: String? = nil) {
        routes[host] = Route(base: base ?? "https://\(host)", masquerade: masquerade)
        if resting(host) { return }
        topUp(host: host)
    }

    /// A token the island refused (403 on spend): the epoch has rotated, or the
    /// island stopped issuing. Everything minted under the same epoch is dead
    /// with it, so the cached params and those tokens go; the next `tokenFor`
    /// re-fetches `/params` and mints afresh.
    ///
    /// Epoch-aware: only if the cached params still name `epoch`. A refusal of
    /// a token from an epoch that has already been replaced says nothing about
    /// the fresh batch, and dropping that batch would cost every caller that
    /// ran into the same rotation a re-mint of its own. Also ends a rest: a
    /// refusal came from a live `/deposit-auth`, so the island does issue.
    func forget(host: String, epoch: String) {
        rested[host] = nil
        rotate(host: host, epoch: epoch)
    }

    /// A token the island did NOT verify (a 404: no such bundle or device; a
    /// 429 or a transport failure: never looked at) goes back to the front of
    /// the reserve rather than costing a fresh solve. Only while the cached
    /// params still name its epoch: after a rotation it would be popped next
    /// and refused, and the refusal would throw the fresh reserve away.
    func giveBack(_ token: [String: String], host: String) {
        guard live(token, host: host) else { return }
        reserve[host, default: []].insert(token, at: 0)
    }

    /// The token as the `X-Deposit-Token` header carries it: base64url without
    /// padding of the same `{epoch_id, prepared, sig}` JSON a sealed deposit
    /// sends in its body. Nil only if the dictionary cannot be serialised,
    /// which the mint above never produces.
    static func headerValue(_ token: [String: String]) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: token) else { return nil }
        return json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - reserve

    /// Whether `host` is resting after a 404 on `/params`. An expired rest is
    /// cleared on the way out, so the next mint asks the island again.
    private func resting(_ host: String) -> Bool {
        guard let until = rested[host] else { return false }
        if Date() < until { return true }
        rested[host] = nil
        return false
    }

    /// Whether a token was minted under the epoch the cached params name now.
    /// No params at all means nothing is known to be live.
    private func live(_ token: [String: String], host: String) -> Bool {
        guard let p = params[host] else { return false }
        return token["epoch_id"] == p.epochId
    }

    /// How many tokens of `host` the reserve holds that the island would still
    /// take; the target the refill fills up to.
    private func liveCount(host: String) -> Int {
        (reserve[host] ?? []).filter { live($0, host: host) }.count
    }

    /// The next live token of `host`, shedding any minted under an epoch the
    /// cached params no longer name.
    private func pop(host: String) -> [String: String]? {
        guard var dq = reserve[host] else { return nil }
        defer { reserve[host] = dq }
        while !dq.isEmpty {
            let t = dq.removeFirst()
            if live(t, host: host) { return t }
        }
        return nil
    }

    /// The cached params and every reserve token of `epoch` are dead: the
    /// island said so (a 403 on spend, a 409 on issue).
    private func rotate(host: String, epoch: String) {
        if params[host]?.epochId == epoch { params[host] = nil }
        reserve[host]?.removeAll { $0["epoch_id"] == epoch }
    }

    /// Start the refill for `host` unless one is already running: one task per
    /// host, however many callers arrive while it mints.
    private func topUp(host: String) {
        guard refills[host] == nil else { return }
        guard !(waiters[host] ?? []).isEmpty || liveCount(host: host) < batch else { return }
        refills[host] = Task { await self.refill(host: host) }
    }

    /// Mint for `host` until the reserve holds `batch` live tokens and nobody
    /// is waiting, handing each token to the oldest waiter first. Two failures
    /// in a row end it (the island is unreachable, or stopped issuing), and
    /// whoever is still waiting then gets nil and falls back.
    private func refill(host: String) async {
        defer {
            refills[host] = nil
            for c in waiters[host] ?? [] { c.resume(returning: nil) }
            waiters[host] = nil
        }
        var strikes = 0
        while strikes < 2 {
            guard let route = routes[host],
                  let p = await ensureParams(host: host, route: route) else { return }
            if (waiters[host] ?? []).isEmpty, liveCount(host: host) >= batch { return }
            guard let t = await mintOne(host: host, route: route, params: p) else {
                strikes += 1
                continue
            }
            strikes = 0
            deliver(t, host: host)
        }
    }

    /// A freshly finalised token: to the oldest waiter if there is one, else
    /// into the reserve. One minted under params that rotated while its proof
    /// of work was being solved is dropped, the island would only refuse it.
    private func deliver(_ token: [String: String], host: String) {
        guard live(token, host: host) else { return }
        if var ws = waiters[host], !ws.isEmpty {
            let c = ws.removeFirst()
            waiters[host] = ws
            c.resume(returning: token)
        } else {
            reserve[host, default: []].append(token)
        }
    }

    // MARK: - mint

    /// Closed-island gate: the own island's token first (the caller holds it),
    /// else whatever `AccessTokenStore` knows about a foreign host.
    private static func stamp(_ req: inout URLRequest, masquerade: String?) {
        if let masquerade, !masquerade.isEmpty {
            req.setValue(masquerade, forHTTPHeaderField: "X-RCQ-Auth")
        }
        AccessTokenStore.stamp(&req)
    }

    private func ensureParams(host: String, route: Route) async -> Params? {
        if let p = params[host] { return p }
        guard let url = URL(string: "\(route.base)/deposit-auth/params") else { return nil }
        var req = URLRequest(url: url)
        Self.stamp(&req, masquerade: route.masquerade)
        guard let (data, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 {
            // No deposit-auth here, as far as this one answer goes. A rest,
            // not a verdict: see `rested`.
            rested[host] = Date().addingTimeInterval(Self.restFor)
            return nil
        }
        guard (200..<300).contains(http.statusCode),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let epoch = o["epoch_id"] as? String,
              let pk = o["pubkey"] as? [String: Any],
              let spki = pk["spki"] as? String, let der = Data(base64Encoded: spki),
              let pow = o["pow"] as? [String: Any], let diff = pow["difficulty"] as? Int else { return nil }
        let p = Params(epochId: epoch, der: der, difficulty: diff)
        params[host] = p
        return p
    }

    /// One token under `p`: blind, solve, issue, unblind. Nil on any failure
    /// (the refill counts those).
    private func mintOne(host: String, route: Route, params p: Params) async -> [String: String]? {
        guard let pub = try? _RSA.BlindSigning.PublicKey(
            derRepresentation: p.der, parameters: .RSABSSA_SHA384_PSS_Deterministic,
        ) else { return nil }
        // Our own 64 random message bytes: we know them, so we can send them
        // as `prepared` (identity preparation wraps them unchanged).
        let msg = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let prepared = pub.prepare(msg)
        guard let blinding = try? pub.blind(prepared) else { return nil }
        let blindedB64 = blinding.blindedMessage.base64EncodedString()
        // The hashcash runs OFF the actor: a second or more of SHA-256 on the
        // actor's executor would hold every other host's `tokenFor`, and
        // every `giveBack` and `forget`, behind it.
        let challenge = "\(p.epochId):\(blindedB64)"
        let difficulty = p.difficulty
        let solve = Task.detached(priority: .utility) {
            DepositPoW.solve(challenge: challenge, difficultyBits: difficulty)
        }
        guard let nonce = await solve.value else { return nil }
        guard let blindSig = await issue(
            host: host, route: route, epochId: p.epochId, blindedB64: blindedB64, powNonce: nonce
        ) else { return nil }
        guard let sig = try? pub.finalize(
            _RSA.BlindSigning.BlindSignature(rawRepresentation: blindSig),
            for: prepared, blindingInverse: blinding.inverse,
        ) else { return nil }
        return [
            "epoch_id": p.epochId,
            "prepared": msg.base64EncodedString(),
            "sig": sig.rawRepresentation.base64EncodedString(),
        ]
    }

    /// POST /deposit-auth/issue -> the blind signature bytes, or nil on failure.
    /// A 409 (epoch rotated) drops the cached params so the next mint re-fetches.
    private func issue(
        host: String, route: Route, epochId: String, blindedB64: String, powNonce: String
    ) async -> Data? {
        guard let url = URL(string: "\(route.base)/deposit-auth/issue") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "epoch_id": epochId, "blinded": blindedB64, "pow_nonce": powNonce,
        ])
        Self.stamp(&req, masquerade: route.masquerade)
        guard let (data, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 409 { rotate(host: host, epoch: epochId); return nil }
        guard (200..<300).contains(http.statusCode),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = o["blind_sig"] as? String else { return nil }
        return Data(base64Encoded: b64)
    }
}

/// SHA-256 hashcash proof-of-work: the stranger first-contact faucet, byte-
/// identical to the backend (`verify_pow`) and Android ([BlindToken]).
enum DepositPoW {
    /// The decimal nonce that puts `difficultyBits` leading zero bits on
    /// `SHA-256("{challenge}:{nonce}")`, or nil if the task was cancelled
    /// first (checked every few thousand hashes, so a solve nobody needs any
    /// more stops burning the battery).
    static func solve(challenge: String, difficultyBits: Int) -> String? {
        let prefix = Data("\(challenge):".utf8)
        var c = 0
        while true {
            if c & 0xFFF == 0, Task.isCancelled { return nil }
            let nonce = String(c)
            var h = SHA256()
            h.update(data: prefix)
            h.update(data: Data(nonce.utf8))
            if leadingZeroBits(Data(h.finalize())) >= difficultyBits { return nonce }
            c += 1
        }
    }

    static func verify(challenge: String, nonce: String, difficultyBits: Int) -> Bool {
        let digest = SHA256.hash(data: Data("\(challenge):\(nonce)".utf8))
        return leadingZeroBits(Data(digest)) >= difficultyBits
    }

    private static func leadingZeroBits(_ d: Data) -> Int {
        var bits = 0
        for b in d {
            if b == 0 { bits += 8; continue }
            bits += Int(b.leadingZeroBitCount)
            break
        }
        return bits
    }
}
