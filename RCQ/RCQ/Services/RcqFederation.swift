import Foundation
import CryptoKit

/// RCQ Federation Layer B (F1) — addressing + the self-signed home-island record.
///
/// Pure value types and functions. NOTHING here is wired into a live
/// send/receive path yet; this mirrors `web-chat/src/lib/federation.ts` and
/// `docs/federation-protocol.md` byte-for-byte (the canonical JSON, the Ed25519
/// signature, and the wire shapes are cross-platform identical — verified).
///
/// Trust model (spec §2.4): the record is Ed25519-signed by the account's
/// `signing_key` (the v=1 sealed-sender signer, the one primitive every client
/// already has — here `Curve25519.Signing`). It carries both that signing key
/// (`sk`) and the libsignal identity key (`ik`, the safety-number key). A
/// verifier checks the signature AND cross-checks `sk`/`ik` against keys it
/// anchored independently (the peer's bundle + safety number). A mailbox or
/// mirror can withhold or serve a stale-but-valid record; it can never forge one.
enum RcqFederation {

    static let flagshipHost = "api.rcq.app"

    // MARK: - Addressing (spec §1)

    struct Address: Equatable {
        let uin: Int
        let host: String
    }

    enum FedError: Error, Equatable {
        case invalidAddress(String)
        case noHomes
        case badRecord(String)
    }

    private static func isAllDigits(_ s: String) -> Bool {
        return !s.isEmpty && s.allSatisfy { $0.isNumber && $0.isASCII }
    }

    private static func isValidHost(_ s: String) -> Bool {
        if s.isEmpty { return false }
        // reg-name + optional :port; no spaces, no scheme, no path.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Parse "777" -> flagship handle, "777@host" -> cross-island handle.
    /// Total and strict: anything else throws (never silently mis-route).
    static func parseAddress(_ input: String) throws -> Address {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = s.firstIndex(of: "@") {
            let uinPart = String(s[s.startIndex..<at])
            let host = String(s[s.index(after: at)...])
            guard isAllDigits(uinPart), let uin = Int(uinPart) else {
                throw FedError.invalidAddress("bad uin")
            }
            guard isValidHost(host) else { throw FedError.invalidAddress("bad host") }
            return Address(uin: uin, host: host.lowercased())
        }
        guard isAllDigits(s), let uin = Int(s) else {
            throw FedError.invalidAddress("not a uin")
        }
        return Address(uin: uin, host: flagshipHost)
    }

    /// Display/storage form. The `@api.rcq.app` suffix is hidden by default.
    static func formatAddress(_ a: Address, showFlagship: Bool = false) -> String {
        if a.host == flagshipHost && !showFlagship { return String(a.uin) }
        return "\(a.uin)@\(a.host)"
    }

    static func isFlagship(_ host: String) -> Bool {
        return host.lowercased() == flagshipHost
    }

    // MARK: - Canonical JSON (spec §2.2)
    // Byte-identical to the relay-config scheme already in RelayConfigStore:
    // sorted keys (recursively), compact, slashes + non-ASCII unescaped, UTF-8.

    static func canonicalData(_ obj: [String: Any]) throws -> Data {
        return try JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Home-island record (spec §2)

    struct Home: Equatable {
        let host: String
        let uin: Int
    }

    /// The exact subset that gets signed, reconstructed explicitly (never
    /// "doc minus sig") so injected fields can't enter the signed bytes.
    private static func signedPart(ik: String, sk: String, homes: [Home], ts: Int) -> [String: Any] {
        return [
            "v": 1,
            "ik": ik,
            "sk": sk,
            "homes": homes.map { ["host": $0.host, "uin": $0.uin] as [String: Any] },
            "ts": ts,
        ]
    }

    /// Build and Ed25519-sign a record. `signingPriv` is the account's
    /// `Curve25519.Signing.PrivateKey` (the v=1 signing key); `sk` must be its
    /// public `rawRepresentation` base64; `ik` is base64 of signal_identity_key.
    static func buildRecord(
        ik: String,
        sk: String,
        signingPriv: Curve25519.Signing.PrivateKey,
        homes: [Home],
        ts: Int
    ) throws -> [String: Any] {
        guard !homes.isEmpty else { throw FedError.noHomes }
        let part = signedPart(ik: ik, sk: sk, homes: homes, ts: ts)
        let canon = try canonicalData(part)
        let sig = try signingPriv.signature(for: canon)
        var doc = part
        doc["sig"] = sig.base64EncodedString()
        return doc
    }

    struct VerifyOpts {
        var expectedIk: String?
        var expectedSk: String?
        var minTs: Int?
        init(expectedIk: String? = nil, expectedSk: String? = nil, minTs: Int? = nil) {
            self.expectedIk = expectedIk
            self.expectedSk = expectedSk
            self.minTs = minTs
        }
    }

    /// Verify a record per spec §2.4. The signature check alone proves only
    /// internal consistency; pass expectedSk/expectedIk (anchored from the
    /// peer's bundle + safety number) to bind it to the real peer, and minTs to
    /// reject a rollback to a stale island list.
    static func verifyRecord(_ doc: [String: Any], opts: VerifyOpts = VerifyOpts()) -> Result<[String: Any], FedError> {
        guard (doc["v"] as? Int) == 1 else { return .failure(.badRecord("unsupported version")) }
        guard let ik = doc["ik"] as? String,
              let sk = doc["sk"] as? String,
              let sigB64 = doc["sig"] as? String else {
            return .failure(.badRecord("missing ik/sk/sig"))
        }
        guard let ts = doc["ts"] as? Int, ts > 0 else { return .failure(.badRecord("invalid ts")) }
        guard let rawHomes = doc["homes"] as? [[String: Any]], !rawHomes.isEmpty else {
            return .failure(.badRecord("missing homes"))
        }
        var homes: [Home] = []
        for h in rawHomes {
            guard let host = h["host"] as? String, let uin = h["uin"] as? Int else {
                return .failure(.badRecord("malformed home entry"))
            }
            homes.append(Home(host: host, uin: uin))
        }
        guard let skBytes = Data(base64Encoded: sk),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: skBytes),
              let sigBytes = Data(base64Encoded: sigB64) else {
            return .failure(.badRecord("bad sk/sig encoding"))
        }
        guard let canon = try? canonicalData(signedPart(ik: ik, sk: sk, homes: homes, ts: ts)) else {
            return .failure(.badRecord("canonicalization failed"))
        }
        guard pub.isValidSignature(sigBytes, for: canon) else {
            return .failure(.badRecord("bad signature"))
        }
        if let exp = opts.expectedSk, sk != exp { return .failure(.badRecord("sk not anchored")) }
        if let exp = opts.expectedIk, ik != exp { return .failure(.badRecord("ik not anchored")) }
        if let floor = opts.minTs, ts < floor { return .failure(.badRecord("stale ts")) }
        return .success(doc)
    }

    // MARK: - Contact link / QR (spec §5)
    // Backward compatible: path stays a bare flagship UIN (old clients add the
    // flagship handle); federation data rides in ignored query params
    //   h = host, k = base64url Ed25519 signing_key (sk), i = base64url ik.

    private static func b64ToUrl(_ b64: String) -> String {
        return b64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func urlToB64(_ u: String) -> String {
        var s = u.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - (s.count % 4)) % 4
        s += String(repeating: "=", count: pad)
        return s
    }

    /// Build the contact deep link. Flagship + no keys yields exactly the legacy
    /// `https://rcq.app/u/<uin>`.
    static func buildContactLink(_ a: Address, sk: String? = nil, ik: String? = nil, base: String = "https://rcq.app") -> String {
        var params: [String] = []
        if !isFlagship(a.host) { params.append("h=\(a.host)") }
        if let sk = sk { params.append("k=\(b64ToUrl(sk))") }
        if let ik = ik { params.append("i=\(b64ToUrl(ik))") }
        let q = params.joined(separator: "&")
        return "\(base)/u/\(a.uin)" + (q.isEmpty ? "" : "?\(q)")
    }

    struct ParsedContactLink {
        let address: Address
        let sk: String?
        let ik: String?
    }

    /// Parse a scanned contact link. `uin` is the path segment; `query` the raw
    /// query string (with or without a leading '?').
    static func parseContactLink(uin: String, query: String) throws -> ParsedContactLink {
        guard isAllDigits(uin) else { throw FedError.invalidAddress("bad uin") }
        let q = query.hasPrefix("?") ? String(query.dropFirst()) : query
        var dict: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        let host = dict["h"] ?? flagshipHost
        let address = try parseAddress("\(uin)@\(host)")
        return ParsedContactLink(
            address: address,
            sk: dict["k"].map(urlToB64),
            ik: dict["i"].map(urlToB64)
        )
    }
}
