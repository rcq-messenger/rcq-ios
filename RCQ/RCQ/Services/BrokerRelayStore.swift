import Foundation

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
    private static let host = "api.rcq.app"   // the broker lives on the flagship
    private static let want = 3
    private static let sharedPriority = 1000  // sort at the back, like contact relays

    private struct BridgesResponse: Codable { let relays: [Envelope.RelayShareWire] }
    /// Parsed in parallel with `BridgesResponse` (same array, positionally
    /// aligned) to pull each descriptor's `tier` without touching `RelayShareWire`.
    private struct TierResponse: Codable {
        struct Item: Codable { let tier: String? }
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

    func refreshInBackground() { Task { await self.refresh() } }

    /// Best-effort: pull a few bridges from the broker + cache them. No-op on any
    /// network/decode failure (we keep whatever we had).
    func refresh() async {
        guard let url = URL(string: "https://\(Self.host)/broker/bridges?n=\(Self.want)") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
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
            var out: [Relay] = []
            var trusted: [String] = []
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
            }
            if let enc = try? JSONEncoder().encode(out) {
                UserDefaults.standard.set(enc, forKey: key)
            }
            UserDefaults.standard.set(trusted, forKey: trustedKey)
        } catch {
            // best-effort — keep the cached set
        }
    }
}
