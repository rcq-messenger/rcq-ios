import Foundation

/// Closed-island network gate (masquerade) — the CLIENT side, FOREIGN hosts.
///
/// A fully-private island runs the masquerade Caddyfile: every request must
/// carry `X-RCQ-Auth: <token>` or it gets a decoy. The OWN island's token is the
/// per-account `serverToken` on APIClient; this store holds tokens for FOREIGN
/// hosts (contact islands, visited-group islands, backup islands) so the bare
/// bare `IslandHTTP` cross-island calls can stamp the header. Device-global,
/// keyed by host. A host with no token gets no header (public islands unaffected).
enum AccessTokenStore {
    private static let key = "rcq.access_tokens"  // [host: token]

    private static func map() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    static func token(for host: String) -> String? {
        let h = host.lowercased()
        return map()[h]?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    static func set(host: String, token: String) {
        let h = host.lowercased()
        let t = token.trimmingCharacters(in: .whitespaces)
        var m = map()
        if t.isEmpty { m.removeValue(forKey: h) } else { m[h] = t }
        UserDefaults.standard.set(m, forKey: key)
    }

    static func clear(host: String) {
        var m = map()
        m.removeValue(forKey: host.lowercased())
        UserDefaults.standard.set(m, forKey: key)
    }

    /// Add `X-RCQ-Auth` to a foreign-host request if we hold a token for it and
    /// the caller hasn't already set the header (the redeem call sets the ENTERED
    /// token explicitly and must not be overridden).
    static func stamp(_ req: inout URLRequest) {
        guard let host = req.url?.host,
              req.value(forHTTPHeaderField: "X-RCQ-Auth") == nil,
              let tok = token(for: host) else { return }
        req.setValue(tok, forHTTPHeaderField: "X-RCQ-Auth")
    }
}

enum RedeemResult {
    case ok          // gated host, token accepted, durable token stored
    case noGate      // a normal public island (clean 404) — nothing to do
    case badToken    // gated, token wrong/expired (decoy / non-JSON)
    case error       // network/other — caller may retry
}

enum AccessRedeemer {
    /// Exchange a pasted access token for a durable per-device token and store it
    /// for `host`. A clean 404 = no gate (don't store). Used by the add-account /
    /// add-contact flows for a private island.
    static func redeem(host: String, entered: String) async -> RedeemResult {
        let tok = entered.trimmingCharacters(in: .whitespaces)
        guard !tok.isEmpty, let url = URL(string: "https://\(host)/gate/redeem") else { return .noGate }
        // The gate validates device_id as 16-64 hex chars — strip the UUID dashes.
        let deviceID = KeychainStore.deviceID().replacingOccurrences(of: "-", with: "").lowercased()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(tok, forHTTPHeaderField: "X-RCQ-Auth")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": deviceID])
        do {
            let (data, resp) = try await IslandHTTP.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .noGate }
            guard code == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let durable = (obj["token"] as? String)?.nilIfEmpty else {
                return .badToken
            }
            AccessTokenStore.set(host: host, token: durable)
            return .ok
        } catch {
            return .error
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
