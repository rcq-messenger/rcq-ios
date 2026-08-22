import CryptoKit
import Foundation
import _CryptoExtras

/// F3 deposit-auth client — mints + caches anonymous blinded deposit tokens (RFC
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
/// POST /deposit-auth/issue, unblind -> a token. Minted a small BATCH at a time
/// (amortise the PoW) into an in-memory reserve and popped on send. Self-gating: an
/// island without deposit-auth (404 on /params) is remembered + skipped; a failure
/// just yields nil and the deposit rides the legacy per-IP path (additive).
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
    private var params: [String: Params] = [:]
    private var disabled: Set<String> = []
    private var reserve: [String: [[String: String]]] = [:]
    private let batch = 4

    /// A `deposit_token` `{epoch_id, prepared, sig}` for `host`, or nil when the
    /// island doesn't offer deposit-auth or minting failed.
    ///
    /// `masquerade` is the closed-island `X-RCQ-Auth` token when `host` is the
    /// OWN island: that one lives on `APIClient`, not in `AccessTokenStore`, so
    /// the mint would otherwise knock on a closed island's door unstamped and
    /// read the decoy as "no deposit-auth here".
    func tokenFor(host: String, masquerade: String? = nil) async -> [String: String]? {
        if disabled.contains(host) { return nil }
        if var dq = reserve[host], !dq.isEmpty {
            let t = dq.removeFirst()
            reserve[host] = dq
            return t
        }
        let minted = await mintBatch(host: host, masquerade: masquerade)
        guard let minted, !minted.isEmpty else { return nil }
        if minted.count > 1 { reserve[host] = Array(minted.dropFirst()) }
        return minted.first
    }

    /// A token the island refused (403 on spend): the epoch has rotated, or the
    /// island stopped issuing. Everything minted under the cached params is
    /// dead with them, so the reserve goes too; the next `tokenFor` re-fetches
    /// `/params` and mints afresh.
    func forget(host: String) {
        params[host] = nil
        reserve[host] = nil
    }

    /// A token the island did NOT spend (a 404: no such bundle, no such device)
    /// goes back to the front of the reserve rather than costing a fresh solve.
    func giveBack(_ token: [String: String], host: String) {
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

    /// Closed-island gate: the own island's token first (the caller holds it),
    /// else whatever `AccessTokenStore` knows about a foreign host.
    private static func stamp(_ req: inout URLRequest, masquerade: String?) {
        if let masquerade, !masquerade.isEmpty {
            req.setValue(masquerade, forHTTPHeaderField: "X-RCQ-Auth")
        }
        AccessTokenStore.stamp(&req)
    }

    private func ensureParams(host: String, masquerade: String?) async -> Params? {
        if let p = params[host] { return p }
        guard let url = URL(string: "https://\(host)/deposit-auth/params") else { return nil }
        var req = URLRequest(url: url)
        Self.stamp(&req, masquerade: masquerade)
        guard let (data, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { disabled.insert(host); return nil }   // island doesn't offer it
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

    private func mintBatch(host: String, masquerade: String?) async -> [[String: String]]? {
        guard let p = await ensureParams(host: host, masquerade: masquerade) else { return nil }
        guard let pub = try? _RSA.BlindSigning.PublicKey(
            derRepresentation: p.der, parameters: .RSABSSA_SHA384_PSS_Deterministic,
        ) else { return nil }
        var out: [[String: String]] = []
        for _ in 0..<batch {
            // Our own 64 random message bytes — we know them, so we can send them
            // as `prepared` (identity preparation wraps them unchanged).
            let msg = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            let prepared = pub.prepare(msg)
            guard let blinding = try? pub.blind(prepared) else { break }
            let blindedB64 = blinding.blindedMessage.base64EncodedString()
            let nonce = DepositPoW.solve(challenge: "\(p.epochId):\(blindedB64)", difficultyBits: p.difficulty)
            guard let blindSig = await issue(
                host: host, masquerade: masquerade, epochId: p.epochId, blindedB64: blindedB64, powNonce: nonce
            ) else { break }
            guard let sig = try? pub.finalize(
                _RSA.BlindSigning.BlindSignature(rawRepresentation: blindSig),
                for: prepared, blindingInverse: blinding.inverse,
            ) else { break }
            out.append([
                "epoch_id": p.epochId,
                "prepared": msg.base64EncodedString(),
                "sig": sig.rawRepresentation.base64EncodedString(),
            ])
        }
        return out.isEmpty ? nil : out
    }

    /// POST /deposit-auth/issue -> the blind signature bytes, or nil on failure.
    /// A 409 (epoch rotated) drops the cached params so the next mint re-fetches.
    private func issue(
        host: String, masquerade: String?, epochId: String, blindedB64: String, powNonce: String
    ) async -> Data? {
        guard let url = URL(string: "https://\(host)/deposit-auth/issue") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "epoch_id": epochId, "blinded": blindedB64, "pow_nonce": powNonce,
        ])
        Self.stamp(&req, masquerade: masquerade)
        guard let (data, resp) = try? await IslandHTTP.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 409 { params[host] = nil; return nil }
        guard (200..<300).contains(http.statusCode),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = o["blind_sig"] as? String else { return nil }
        return Data(base64Encoded: b64)
    }
}

/// SHA-256 hashcash proof-of-work — the stranger first-contact faucet, byte-
/// identical to the backend (`verify_pow`) and Android ([BlindToken]).
enum DepositPoW {
    static func solve(challenge: String, difficultyBits: Int) -> String {
        var c = 0
        while true {
            let nonce = String(c)
            if verify(challenge: challenge, nonce: nonce, difficultyBits: difficultyBits) { return nonce }
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
