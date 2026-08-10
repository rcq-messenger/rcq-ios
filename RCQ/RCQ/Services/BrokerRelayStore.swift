import Foundation
import Network

/// Relays pulled from the BROKER (`GET /broker/bridges`) — the per-request,
/// anti-enumeration distribution channel that complements the fully-public
/// signed relay-config (so a censor can't scrape + block the whole pool). See
/// `RCQ/docs/relay-broker-design.md`. Composes with `ContactRelayStore` (social
/// bridge sharing): both feed the transport pool with off-config relays.
///
/// Device-level. Best-effort fetch at boot (the bucket is derived SERVER-SIDE
/// from the requester IP, so the client sends no identity — just `?n=`). Each
/// descriptor is decoded into the shared `Envelope.RelayShareWire` (same keys)
/// and parsed via `ContactRelayStore.relayFromWire`, then retagged
/// `broker-<server>-<port>` for a collision-proof sing-box tag.
@MainActor
final class BrokerRelayStore {
    static let shared = BrokerRelayStore()
    private init() {}

    typealias Relay = RelayConfigStore.RelayEntry

    private let key = "rcq.brokerRelays.v1"
    /// Tags of broker relays the broker marked `tier == "trusted"` (admin-promoted).
    /// Only these are eligible to become an onion ENTRY (an entry sees the client
    /// IP, so it must be a vetted relay); community broker relays stay exits /
    /// fallback. The tier rides the TLS-authenticated `/broker/bridges` response
    /// (broker.py serves `d["tier"]`) — same trust anchor as the app's own API.
    private let trustedKey = "rcq.brokerRelays.trusted.v1"
    private let reportTSKey = "rcq.brokerRelays.reachReportTS.v1"
    /// The paid tenant key, if the user has one. Device-level like everything
    /// else here: it buys network access, not an identity, and somebody with
    /// two accounts on one phone bought it once.
    private let tenantKeyKey = "rcq.brokerRelays.tenantKey.v1"
    /// Tags of the endpoints this account PAYS for. The broker marks them
    /// because without the mark a bought node was indistinguishable from one of
    /// the fourteen everybody gets, so it went into the same latency race and
    /// lost it about as often as it won.
    private let privateKey = "rcq.brokerRelays.private.v1"
    /// What the broker made of the key we last sent: nil (none sent), "ok",
    /// "unknown", "expired". A wrong key used to be indistinguishable from a
    /// right one, so the app accepted anything typed into the field.
    private let verdictKey = "rcq.brokerRelays.keyVerdict.v1"
    private static let host = "api.rcq.app"   // the broker lives on the flagship
    private static let want = 3
    private static let sharedPriority = 1000  // sort at the back, like contact relays
    private static let reportInterval: TimeInterval = 3600   // report at most hourly
    private static let probeTimeout: TimeInterval = 2.5
    private static let maxProbe = 20

    private struct BridgesResponse: Codable { let relays: [Envelope.RelayShareWire] }
    /// The verdict on the key we sent, alongside the relays.
    private struct KeyResponse: Codable { let key: String? }
    /// Parsed in parallel with `BridgesResponse` (same array, positionally
    /// aligned) to pull each descriptor's `tier` without touching `RelayShareWire`.
    private struct TierResponse: Codable {
        struct Item: Codable { let tier: String?; let `private`: Bool? }
        let relays: [Item]
    }

    /// Relays for the transport pool (cached from the last successful fetch).
    func relays() -> [Relay] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Relay].self, from: data) else { return [] }
        return list
    }

    /// The cached broker relays that were marked trusted — onion-entry eligible.
    func trustedRelays() -> [Relay] {
        let tags = Set(UserDefaults.standard.stringArray(forKey: trustedKey) ?? [])
        guard !tags.isEmpty else { return [] }
        return relays().filter { tags.contains($0.tag) }
    }

    /// The endpoints this account pays for.
    func privateRelays() -> [Relay] {
        let tags = Set(UserDefaults.standard.stringArray(forKey: privateKey) ?? [])
        guard !tags.isEmpty else { return [] }
        return relays().filter { tags.contains($0.tag) }
    }

    /// What the broker said about the key on the last refresh.
    var keyVerdict: String? { UserDefaults.standard.string(forKey: verdictKey) }

    /// The paid access key, or nil.
    var tenantKey: String? {
        (UserDefaults.standard.string(forKey: tenantKeyKey))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Store (or clear, with nil) the paid access key.
    func setTenantKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: tenantKeyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: tenantKeyKey)
        }
    }

    func refreshInBackground() { Task { await self.refresh() } }

    /// Best-effort: pull a few bridges from the broker + cache them. No-op on any
    /// network/decode failure (we keep whatever we had).
    func refresh() async {
        guard let url = URL(string: "https://\(Self.host)/broker/bridges?n=\(Self.want)") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The paid key, when there is one, rides in Authorization — the broker
        // adds that tenant's private endpoints to the ordinary answer. A header
        // rather than a query parameter because proxies redact this one, and a
        // relay key in an access log is the same mistake as a session token in
        // one. Without a key nothing about this request changes.
        if let paid = tenantKey {
            req.setValue("Bearer \(paid)", forHTTPHeaderField: "Authorization")
        }
        do {
            // Through the tunnel when it's up: a BLOCKED user can't reach
            // api.rcq.app directly, so without this they NEVER receive broker
            // bridges (incl. the community relays operators raise). Once a bundled
            // relay carries the tunnel, the fetch rides it. Tradeoff: the broker
            // then buckets by the relay IP, not the user IP (weaker anti-enum) —
            // acceptable, since some bridges beats none. Unblocked users: direct.
            let config = URLSessionConfiguration.ephemeral
            if SingBoxTransport.shared.isActive, let proxy = SingBoxTransport.proxyDictionary() {
                config.connectionProxyDictionary = proxy
            }
            let (data, response) = try await URLSession(configuration: config).data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let parsed = try JSONDecoder().decode(BridgesResponse.self, from: data)
            let tiers = (try? JSONDecoder().decode(TierResponse.self, from: data))?.relays ?? []
            let verdict = (try? JSONDecoder().decode(KeyResponse.self, from: data))?.key
            var out: [Relay] = []
            var trusted: [String] = []
            var mine: [String] = []
            for (i, w) in parsed.relays.enumerated() {
                guard let r = ContactRelayStore.relayFromWire(w) else { continue }
                let safe = String(r.server.map { $0.isLetter || $0.isNumber ? $0 : "-" })
                let tag = "broker-\(safe)-\(r.port)"
                out.append(Relay(
                    tag: tag, server: r.server, port: r.port, sni: r.sni,
                    priority: Self.sharedPriority, proto: r.proto, uuid: r.uuid, publicKey: r.publicKey,
                    shortID: r.shortID, flow: r.flow, password: r.password, obfsPassword: r.obfsPassword,
                ))
                if i < tiers.count, tiers[i].tier == "trusted" { trusted.append(tag) }
                if i < tiers.count, tiers[i].private == true { mine.append(tag) }
            }
            if let enc = try? JSONEncoder().encode(out) {
                UserDefaults.standard.set(enc, forKey: key)
            }
            UserDefaults.standard.set(trusted, forKey: trustedKey)
            UserDefaults.standard.set(mine, forKey: privateKey)
            if let verdict { UserDefaults.standard.set(verdict, forKey: verdictKey) }
            else { UserDefaults.standard.removeObject(forKey: verdictKey) }
        } catch {
            // best-effort — keep the cached set
        }
    }

    func reportReachabilityInBackground() { Task { await self.reportReachability() } }

    /// Report which known relays are reachable FROM THIS NETWORK so the broker can
    /// serve them region-by-region (POST /broker/reachability — the server side of
    /// region quorum). Probes the relay union (signed-config + shared + broker) with
    /// a DIRECT TCP connect (that IS the reachability measurement), then posts the
    /// ok/fail verdicts THROUGH the tunnel when up (a blocked user can't reach the
    /// flagship direct). Best-effort, throttled hourly.
    ///
    /// SKIPPED under a user local proxy (Tor/I2P): a direct probe to relay IPs would
    /// bypass the proxy and leak the real IP — the Tor-leak rule.
    func reportReachability() async {
        if SingBoxTransport.localProxyMode { return }
        let now = Date().timeIntervalSince1970
        if now - UserDefaults.standard.double(forKey: reportTSKey) < Self.reportInterval { return }
        var seen = Set<String>()
        let targets = (RelayConfigStore.shared.currentRelays() + ContactRelayStore.shared.relays() + relays())
            .filter { !$0.server.isEmpty && (1...65535).contains($0.port)
                && seen.insert("\($0.server):\($0.port)").inserted }
            .prefix(Self.maxProbe)
        if targets.isEmpty { return }
        var verdicts: [(String, Int, Bool)] = []
        await withTaskGroup(of: (String, Int, Bool).self) { group in
            for r in targets {
                let server = r.server, port = r.port
                group.addTask { (server, port, await Self.probe(host: server, port: port, timeout: Self.probeTimeout)) }
            }
            for await v in group { verdicts.append(v) }
        }
        if verdicts.isEmpty { return }
        let reports = verdicts.map { ["server": $0.0, "port": $0.1, "ok": $0.2] as [String: Any] }
        guard let body = try? JSONSerialization.data(withJSONObject: ["reports": reports]),
              let url = URL(string: "https://\(Self.host)/broker/reachability") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        if SingBoxTransport.shared.isActive, let proxy = SingBoxTransport.proxyDictionary() {
            config.connectionProxyDictionary = proxy
        }
        _ = try? await URLSession(configuration: config).data(for: req)
        UserDefaults.standard.set(now, forKey: reportTSKey)
    }

    /// Direct TCP reachability probe: true if a connection to host:port reaches
    /// `.ready` within `timeout`, false on failure/timeout. nonisolated so it runs
    /// off the main actor in the task group.
    private nonisolated static func probe(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let q = DispatchQueue(label: "rcq.reach.probe")
            var done = false
            @Sendable func finish(_ ok: Bool) {
                q.async {
                    guard !done else { return }
                    done = true
                    conn.cancel()
                    cont.resume(returning: ok)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break   // .waiting (e.g. blocked) rides to the timeout below
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
