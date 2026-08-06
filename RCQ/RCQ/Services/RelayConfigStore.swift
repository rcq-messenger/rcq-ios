import CryptoKit
import Foundation

@MainActor
final class RelayConfigStore {
    static let shared = RelayConfigStore()

    // Which keys may sign this payload lives in `SigningKeys` — a SET, so the
    // signing key can change without a release. See that file for why the set is
    // compiled in rather than carried by the payload it authenticates.

    /// The two mirrors compiled into the app.
    ///
    /// ⚠ These two names are also the entire attack surface of the delivery
    /// channel: a censor who blocks both leaves a client with nothing but the
    /// bundled pool and a hand-pasted token. `remoteSources` is the way out.
    private static let bundledEndpoints: [Source] = [
        .https(URL(string: "https://raw.githubusercontent.com/rcq-messenger/rcq-ios/main/relay-config.json")!),
        .https(URL(string: "https://relay.rcq.app/v1/config")!),
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

    /// Names the transport uses, so moving off the flagship apex is a config
    /// push rather than a release. Both were compiled in until now, which meant
    /// the one lever that answers "they blocked the whole apex by name" could
    /// only be pulled by shipping a build and waiting for people to take it.
    struct TransportNames: Codable {
        /// Bare hostname of the CF front (`cdn.rcq.app` until a payload says
        /// otherwise). Used on a DIRECT connection, so it needs nothing from a
        /// relay's allow-list.
        let front: String?
        /// Full https URL the reachability probe fetches.
        let probe: String?
        /// Where the device SUBSCRIBES for wakes. Parsed and ignored here — iOS
        /// is woken through APNs and has no push socket of its own. Present so
        /// a payload written for Android does not look malformed to this client.
        let push: String?
    }

    struct Payload: Codable {
        let version: Int
        let issuedAt: String
        let relays: [RelayEntry]
        let onion: OnionPolicy?
        /// Extra mirrors this payload names for itself. Absent on older payloads.
        let sources: [SourceEntry]?
        /// Transport names. Absent on older payloads.
        let transport: TransportNames?

        enum CodingKeys: String, CodingKey {
            case version, relays, onion, sources, transport
            case issuedAt = "issued_at"
        }
    }

    /// Onion routing policy from the signed config (`onion.enabled`, O3). When
    /// true AND ≥2 VLESS relays exist, SingBoxTransport builds a 2-hop chain
    /// (M3 metadata resistance, RCQ/docs/onion-design.md). Default OFF — only a
    /// signature-valid payload that explicitly sets it flips onion on, so
    /// rollout is a signed-config push to a cohort, ZERO app release.
    static var onionEnabled = false

    /// Hostname of the CF front, from the signed config. nil until a payload
    /// names one, and `APIClient.builtInProxyURL` stands in — so this is purely
    /// additive and a client that never sees a `transport` block behaves
    /// exactly as before.
    ///
    /// ⚠ Absent must mean UNCHANGED, not "reset to the compiled-in name": a
    /// rollback to an older payload would otherwise drag every client back onto
    /// the apex, which is the single thing this mechanism exists to leave.
    /// nonisolated(unsafe): written only on the main actor while a payload is
    /// parsed, read from the transport and the API client, which are not
    /// main-actor bound. A reader racing a config push sees either the old name
    /// or the new one, and both are valid names to dial.
    nonisolated(unsafe) private(set) static var frontHost: String?

    /// Full https URL the reachability probe fetches, from the signed config.
    ///
    /// ⚠ Unlike `frontHost` this one is ALSO fetched through each relay by the
    /// selector, so every relay's allow-list has to permit the host first.
    /// Relays derive that list from this same payload but on a timer, so
    /// publishing a probe they do not yet allow leaves the client unable to
    /// measure any relay, and therefore with no tunnel at all. Move the relays
    /// first.
    nonisolated(unsafe) private(set) static var probeURL: String?

    /// One entry of the payload's `sources` array. Unknown types are skipped
    /// rather than rejected, so a payload announcing a channel this build cannot
    /// speak stays usable for everything else in it.
    struct SourceEntry: Codable, Equatable {
        let type: String?
        let url: String?
        /// For `dns-txt`: the name whose TXT record carries a signed seed.
        let name: String?
    }

    /// Where a payload can be read from. `https` is a mirror URL; `dnsTxt` is a
    /// name read over DoH — a channel that survives both mirror names being
    /// blocked, since it rides resolvers half the internet needs to stay up.
    enum Source: Equatable {
        case https(URL)
        case dnsTxt(String)

        var key: String {
            switch self {
            case .https(let u): return "https:\(u.absoluteString)"
            case .dnsTxt(let n): return "dns:\(n)"
            }
        }
    }

    /// Extra mirrors carried BY the signed config, so a new delivery channel — a
    /// domain bought at another registrar, a mirror somewhere expensive to block
    /// wholesale — reaches installed clients without an app release.
    private static var remoteSources: [Source] = []

    /// Version of the last verified payload, and the floor for the next one.
    private(set) static var version: Int?

    /// How many mirrors we will walk in one refresh. A refresh runs before the
    /// transport is up, so each dead entry costs its full timeout; a payload
    /// listing fifty would turn launch into a stall.
    private static let maxSources = 8

    /// Mirrors to walk, freshest knowledge first, then the compiled-in pair.
    ///
    /// ★ The bundled pair is ALWAYS appended and never replaced. A published
    /// source list is an ADDITION, not a substitution — otherwise one bad push,
    /// a typo'd host or a lapsed domain, points every installed client at a dead
    /// mirror with no route back, and no later push could reach them to fix it.
    /// Additive, the worst a bad entry costs is one timeout.
    ///
    /// Config entries lead because they are the reason this exists: the two
    /// bundled names are exactly what a censor enumerates first, so on the
    /// network that needs them the new mirror is the one likely to answer.
    static func effectiveEndpoints() -> [Source] {
        var seen = Set<String>()
        var out: [Source] = []
        for source in remoteSources + bundledEndpoints where seen.insert(source.key).inserted {
            out.append(source)
            if out.count == maxSources { break }
        }
        return out
    }

    private var cached: [RelayEntry]?

    private init() {
        if let onDisk = Self.loadFromDisk() {
            cached = onDisk.relays.sorted { $0.priority < $1.priority }
            Self.onionEnabled = onDisk.onion?.enabled ?? false
            // Restore the names too, not just the relays. A blocked client
            // cannot refresh, so the launch after the block starts is exactly
            // when the last known front has to survive — reading it back only
            // on a successful refresh would forget it precisely then.
            Self.applyTransport(onDisk)
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
        for source in Self.effectiveEndpoints() {
            var data: Data
            switch source {
            case .https(let url):
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                guard let (body, response) = try? await session.data(for: req),
                      let http = response as? HTTPURLResponse, http.statusCode == 200
                else { continue }
                data = body
            case .dnsTxt(let name):
                guard let encoded = await DnsTxt.fetch(name: name, session: session),
                      let decoded = Data(base64Encoded: encoded)
                else { continue }
                data = decoded
            }
            // The floor is whatever we already trust, so a mirror serving a
            // stale but genuinely signed payload cannot move us backwards.
            guard let payload = Self.verifyAndDecode(data, minVersion: Self.version) else { continue }
            let sorted = payload.relays.sorted { $0.priority < $1.priority }
            cached = sorted
            Self.version = payload.version
            Self.onionEnabled = payload.onion?.enabled ?? false
            Self.applySources(payload)
            Self.applyTransport(payload)
            Self.saveToDisk(data)
            return
        }
    }

    /// Adopt the transport names a payload carries. Absent block, or an absent
    /// field inside it, leaves the current value alone for the same reason
    /// `applySources` does: a rollback must not walk clients back onto the apex.
    ///
    /// A `front` with a slash in it is refused. It is a bare hostname by
    /// contract, and letting a path through would silently produce URLs like
    /// `https://host/prefix/health` that fail in a way pointing at the network
    /// rather than at the payload.
    private static func applyTransport(_ payload: Payload) {
        guard let t = payload.transport else { return }
        if let front = t.front, !front.isEmpty, !front.contains("/") {
            frontHost = front
        }
        if let probe = t.probe, probe.hasPrefix("https://") {
            probeURL = probe
        }
    }

    /// Adopt the mirrors a payload names. A payload carrying no `sources` leaves
    /// a previously published list alone: otherwise a rollback would silently
    /// narrow the channel back to the two compiled-in names.
    private static func applySources(_ payload: Payload) {
        guard let entries = payload.sources, !entries.isEmpty else { return }
        let parsed = entries.compactMap { entry -> Source? in
            switch entry.type ?? "https" {
            case "https":
                guard let raw = entry.url, raw.hasPrefix("https://"),
                      let url = URL(string: raw) else { return nil }
                return .https(url)
            case "dns-txt":
                guard let name = entry.name, !name.isEmpty else { return nil }
                return .dnsTxt(name)
            default:
                return nil   // a channel this build cannot speak; the rest stays usable
            }
        }
        if !parsed.isEmpty { remoteSources = parsed }
    }

    // MARK: - Signature verification

    /// Verify the signature, then decode.
    ///
    /// `minVersion` refuses a payload older than one already trusted. A
    /// signature proves a payload came from us; it says nothing about WHEN.
    /// Anyone who can answer for a mirror, or sit on the path to one, can replay
    /// an OLD signed payload and walk a client back onto a relay set retired
    /// months ago — no forgery, just an old truth served late.
    ///
    /// Both app updaters were always safe from this because they compare against
    /// what is installed. This list had no such check on either side, and the
    /// guard in the signer only stops us doing it to ourselves by accident.
    /// Recovering from a bad push means publishing a HIGHER version with
    /// corrected content, never re-publishing an older number.
    static func verifyAndDecode(_ data: Data, minVersion: Int? = nil) -> Payload? {
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
        guard SigningKeys.verify(.relayConfig, message: canonical, signature: sigBytes) else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        if let minVersion, payload.version < minVersion { return nil }
        return payload
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
        // ⚠ An SNI has to be plausible for the ADDRESS, not just innocuous on
        // its own. This pair presented `www.yandex.ru` from a DigitalOcean
        // address until 2026-08-05, and Yandex is never served out of
        // DigitalOcean — one join of SNI against the address owner finds every
        // connection we make, and Reality's resistance to ACTIVE probing does
        // nothing about that. It now presents a name that genuinely lives on
        // the same ASN and region as the relay. Oracle and GCP still carry
        // Akamai-hosted names for want of admin access to those two machines.
        //
        // Keep in step: `curl -s https://relay.rcq.app/v1/config`, compare tag /
        // server / sni / keys. Hysteria2 leads on each host, matching the signed
        // priorities.
        RelayEntry(
            tag: "relay-do-fra-spaces-hy2",
            server: "165.22.90.214",
            port: 443,
            sni: "fra1.digitaloceanspaces.com",
            priority: 0,
            proto: .hysteria2,
            password: "JN0qzA4LJfhHPKKN3QHj4eN8",
            obfsPassword: "jXfGkLToOkTihpeJzDiNf8Bb",
        ),
        RelayEntry(
            tag: "relay-do-fra-spaces",
            server: "165.22.90.214",
            port: 443,
            sni: "fra1.digitaloceanspaces.com",
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
