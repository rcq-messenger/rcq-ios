import CryptoKit
import Foundation

@MainActor
final class RelayConfigStore {
    static let shared = RelayConfigStore()

    private static let signingPublicKeyB64 =
        "TY834OFcBvtUqHcnVw/QrPBOaEAZo7a1GAmABMhjkT8="

    private static let endpoints: [URL] = [
        URL(string: "https://raw.githubusercontent.com/rcq-messenger/rcq-ios/main/relay-config.json")!,
        URL(string: "https://relay.rcq.app/v1/config")!,
    ]
    private static let cacheFile = "relay-config.json"

    /// Wire protocol for a relay. `vless` is the legacy VLESS+Reality
    /// path (TCP/443 with Reality TLS masquerade). `hysteria2` is the
    /// QUIC-over-UDP path with Salamander obfuscation, added to defeat
    /// carriers whose DPI matches the Reality TLS fingerprint.
    enum RelayProtocol: String, Codable, Equatable {
        case vless
        case hysteria2
    }

    struct RelayEntry: Codable, Equatable {
        let tag: String
        let server: String
        let port: Int
        let sni: String
        let priority: Int
        /// Wire protocol. Defaults to `.vless` so payloads from older
        /// signers (which omitted the field) keep working.
        let proto: RelayProtocol

        // VLESS+Reality fields. Populated when `proto == .vless`.
        let uuid: String?
        let publicKey: String?
        let shortID: String?
        let flow: String?

        // Hysteria2 fields. Populated when `proto == .hysteria2`.
        let password: String?
        let obfsPassword: String?

        enum CodingKeys: String, CodingKey {
            case tag, server, port, sni, priority, proto, uuid, flow, password
            case publicKey = "public_key"
            case shortID = "short_id"
            case obfsPassword = "obfs_password"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tag = try c.decode(String.self, forKey: .tag)
            server = try c.decode(String.self, forKey: .server)
            port = try c.decode(Int.self, forKey: .port)
            sni = try c.decode(String.self, forKey: .sni)
            priority = try c.decode(Int.self, forKey: .priority)
            proto = try c.decodeIfPresent(RelayProtocol.self, forKey: .proto) ?? .vless
            uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
            publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey)
            shortID = try c.decodeIfPresent(String.self, forKey: .shortID)
            flow = try c.decodeIfPresent(String.self, forKey: .flow)
            password = try c.decodeIfPresent(String.self, forKey: .password)
            obfsPassword = try c.decodeIfPresent(String.self, forKey: .obfsPassword)
        }

        init(
            tag: String,
            server: String,
            port: Int,
            sni: String,
            priority: Int,
            proto: RelayProtocol,
            uuid: String? = nil,
            publicKey: String? = nil,
            shortID: String? = nil,
            flow: String? = nil,
            password: String? = nil,
            obfsPassword: String? = nil
        ) {
            self.tag = tag
            self.server = server
            self.port = port
            self.sni = sni
            self.priority = priority
            self.proto = proto
            self.uuid = uuid
            self.publicKey = publicKey
            self.shortID = shortID
            self.flow = flow
            self.password = password
            self.obfsPassword = obfsPassword
        }
    }

    struct OnionPolicy: Codable { let enabled: Bool? }

    struct Payload: Codable {
        let version: Int
        let issuedAt: String
        let relays: [RelayEntry]
        let onion: OnionPolicy?

        enum CodingKeys: String, CodingKey {
            case version, relays, onion
            case issuedAt = "issued_at"
        }
    }

    /// Onion routing policy from the signed config (`onion.enabled`, O3). When
    /// true AND ≥2 VLESS relays exist, SingBoxTransport builds a 2-hop chain
    /// (M3 metadata resistance, RCQ/docs/onion-design.md). Default OFF — only a
    /// signature-valid payload that explicitly sets it flips onion on, so
    /// rollout is a signed-config push to a cohort, ZERO app release.
    static var onionEnabled = false

    private var cached: [RelayEntry]?

    private init() {
        if let onDisk = Self.loadFromDisk() {
            cached = onDisk.relays.sorted { $0.priority < $1.priority }
            Self.onionEnabled = onDisk.onion?.enabled ?? false
        }
    }

    func currentRelays() -> [RelayEntry] {
        if let cached, !cached.isEmpty { return cached }
        return Self.bundledFallback
    }

    func refreshInBackground() {
        Task { await self.refresh() }
    }

    private func refresh() async {
        // Route through the tunnel when it's up. A BLOCKED user can't reach the
        // mirrors directly (github raw + Cloudflare relay.rcq.app are DPI-throttled
        // in RU), so before this they were stuck on the bundled pool forever. Once
        // a bundled relay carries the tunnel, the fetch rides it and picks up the
        // domestic relay + rotations for next launch. Unblocked users fetch direct.
        // The signed config is PUBLIC, so tunnelling it leaks nothing.
        let config = URLSessionConfiguration.ephemeral
        if SingBoxTransport.shared.isActive, let proxy = SingBoxTransport.proxyDictionary() {
            config.connectionProxyDictionary = proxy
        }
        let session = URLSession(configuration: config)
        for url in Self.endpoints {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                guard let payload = Self.verifyAndDecode(data) else { continue }
                let sorted = payload.relays.sorted { $0.priority < $1.priority }
                cached = sorted
                Self.onionEnabled = payload.onion?.enabled ?? false
                Self.saveToDisk(data)
                return
            } catch {
                continue
            }
        }
    }

    // MARK: - Signature verification

    static func verifyAndDecode(_ data: Data) -> Payload? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard
            let sigB64 = raw["sig"] as? String,
            let sigBytes = Data(base64Encoded: sigB64)
        else { return nil }
        var signedPart = raw
        signedPart.removeValue(forKey: "sig")
        guard let canonical = try? JSONSerialization.data(
            withJSONObject: signedPart,
            options: [.sortedKeys, .withoutEscapingSlashes],
        ) else { return nil }
        let pubKeyBytes = Data(base64Encoded: signingPublicKeyB64) ?? Data()
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            return nil
        }
        guard publicKey.isValidSignature(sigBytes, for: canonical) else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    // MARK: - Disk cache

    private static var cacheURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask,
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("RCQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(cacheFile)
    }

    private static func saveToDisk(_ data: Data) {
        guard let url = cacheURL else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func loadFromDisk() -> Payload? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return verifyAndDecode(data)
    }

    // MARK: - Bundled fallback

    private static let bundledFallback: [RelayEntry] = [
        // A copy of the live signed config, last synced with **v130
        // (2026-07-31)**. Last-resort fallback when no verified remote/disk
        // list is available, and CRITICAL for a blocked user: both
        // signed-config mirrors (github raw, Cloudflare relay.rcq.app) and the
        // broker (api.rcq.app, fetched direct) are themselves DPI-blockable, so
        // a censored fresh install may ONLY ever see this list.
        //
        // ⚠ Which is why letting it rot is expensive. Until 2026-08-05 it led
        // with the domestic RU relay 45.151.101.221, retired server-side on
        // 06-18 and dead since, so a censored client's first move was to dial a
        // corpse. The oracle entry also carried www.microsoft.com where the
        // signed config says www.apple.com — the exact mismatch that once broke
        // VLESS while Hysteria2 kept working on the same host. And two of the
        // three machines had no Hysteria2 entry at all, so on a network that
        // fingerprints the Reality handshake this build had one UDP option
        // instead of three.
        //
        // Keep in step: `curl -s https://relay.rcq.app/v1/config`, compare tag /
        // server / sni / keys. Hysteria2 leads on each host, matching the signed
        // priorities.
        RelayEntry(
            tag: "relay-do-fra-yandex-hy2",
            server: "165.22.90.214",
            port: 443,
            sni: "www.yandex.ru",
            priority: 0,
            proto: .hysteria2,
            password: "JN0qzA4LJfhHPKKN3QHj4eN8",
            obfsPassword: "jXfGkLToOkTihpeJzDiNf8Bb",
        ),
        RelayEntry(
            tag: "relay-do-fra-yandex",
            server: "165.22.90.214",
            port: 443,
            sni: "www.yandex.ru",
            priority: 1,
            proto: .vless,
            uuid: "2081b3c4-faaa-4cce-a0ab-607197b28237",
            publicKey: "n33TZTLNrc6X7jTGrKWex_sk8aIQ6Qqz-eC8lqYMii8",
            shortID: "aa5d483441e59ac7",
            flow: "xtls-rprx-vision",
        ),
        RelayEntry(
            tag: "relay-oracle-il-hy2",
            server: "129.159.143.135",
            port: 443,
            sni: "www.microsoft.com",
            priority: 2,
            proto: .hysteria2,
            password: "bvuvu74CVsiXdcJazcYphnO5",
            obfsPassword: "PaEHrZABTk36orhfFON7Jure",
        ),
        RelayEntry(
            tag: "relay-oracle-il",
            server: "129.159.143.135",
            port: 443,
            sni: "www.apple.com",
            priority: 3,
            proto: .vless,
            uuid: "ff005e0c-175e-4475-a166-eeac88f514e2",
            publicKey: "_Hhc-2pjkvR914mddMdmuoOVaT74vWR8Gby7KmJp9F8",
            shortID: "318567678ac9878e",
            flow: "xtls-rprx-vision",
        ),
        RelayEntry(
            tag: "relay-gcp-hy2",
            server: "35.238.53.96",
            port: 443,
            sni: "www.apple.com",
            priority: 4,
            proto: .hysteria2,
            password: "QaY3uT8EmfZxfON65jaT5bSu",
            obfsPassword: "fLpJ2c211xjnZcP9VNcNpbZP",
        ),
        RelayEntry(
            tag: "relay-gcp",
            server: "35.238.53.96",
            port: 443,
            sni: "www.apple.com",
            priority: 5,
            proto: .vless,
            uuid: "8e3b35d3-18a6-406d-9ac6-c5558a806663",
            publicKey: "mQZ8CJeMWyf7oYGWJG8oOI52or2kx4yTthl6AGZkSTw",
            shortID: "b5b8979af1f27aab",
            flow: "xtls-rprx-vision",
        ),
    ]
}
