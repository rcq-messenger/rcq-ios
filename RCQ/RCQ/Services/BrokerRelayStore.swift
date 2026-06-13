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
    private static let host = "api.rcq.app"   // the broker lives on the flagship
    private static let want = 3
    private static let sharedPriority = 1000  // sort at the back, like contact relays

    private struct BridgesResponse: Codable { let relays: [Envelope.RelayShareWire] }

    /// Relays for the transport pool (cached from the last successful fetch).
    func relays() -> [Relay] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Relay].self, from: data) else { return [] }
        return list
    }

    func refreshInBackground() { Task { await self.refresh() } }

    /// Best-effort: pull a few bridges from the broker + cache them. No-op on any
    /// network/decode failure (we keep whatever we had).
    func refresh() async {
        guard let url = URL(string: "https://\(Self.host)/broker/bridges?n=\(Self.want)") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let parsed = try JSONDecoder().decode(BridgesResponse.self, from: data)
            var out: [Relay] = []
            for w in parsed.relays {
                guard let r = ContactRelayStore.relayFromWire(w) else { continue }
                let safe = String(r.server.map { $0.isLetter || $0.isNumber ? $0 : "-" })
                out.append(Relay(
                    tag: "broker-\(safe)-\(r.port)", server: r.server, port: r.port, sni: r.sni,
                    priority: Self.sharedPriority, proto: r.proto, uuid: r.uuid, publicKey: r.publicKey,
                    shortID: r.shortID, flow: r.flow, password: r.password, obfsPassword: r.obfsPassword,
                ))
            }
            if let enc = try? JSONEncoder().encode(out) {
                UserDefaults.standard.set(enc, forKey: key)
            }
        } catch {
            // best-effort — keep the cached set
        }
    }
}
