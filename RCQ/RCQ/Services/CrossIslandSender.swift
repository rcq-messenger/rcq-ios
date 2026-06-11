import Foundation

/// Federation Layer B (F2) — cross-island send helpers.
///
/// Fetch a peer's open public-key card from their island, resolve their current
/// home island(s) from their signed home-island record (verified), and deposit a
/// pre-sealed blob to an arbitrary island's `/messages/sealed`. The v=1 seal
/// itself is done by the caller (`MessageService.crypto.encrypt`). Mirrors the
/// web `federation-send.ts`, verified end-to-end against a real second island.
enum CrossIslandSender {

    struct Card: Decodable {
        let identity_key: String
        let signing_key: String
        let signal_identity_key: String?
        // §5c display: the open card now carries the peer's nickname (+ optional
        // gender/status) so a cross-island contact shows a real name, not uin@host.
        let nickname: String?
        let gender: String?
        let status_message: String?
    }

    struct Home {
        let host: String
        let uin: Int
    }

    /// Fetch a peer's open public-key card from their island (no auth).
    static func fetchCard(host: String, uin: Int) async -> Card? {
        guard let url = URL(string: "https://\(host)/federation/keys/\(uin)") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(Card.self, from: data)
    }

    /// Resolve the peer's verified home islands (spec §4). Falls back to the
    /// single home `[(host, uin)]` when no record is published or it doesn't verify.
    static func resolveHomes(host: String, uin: Int) async -> [Home] {
        let fallback = [Home(host: host, uin: uin)]
        guard let card = await fetchCard(host: host, uin: uin) else { return fallback }
        guard let url = URL(string: "https://\(host)/federation/island-record/\(uin)"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fallback }
        let result = RcqFederation.verifyRecord(doc, opts: .init(expectedIk: card.signal_identity_key, expectedSk: card.signing_key))
        guard case .success(let rec) = result, let homes = rec["homes"] as? [[String: Any]] else { return fallback }
        let parsed = homes.compactMap { h -> Home? in
            guard let hh = h["host"] as? String, let uu = h["uin"] as? Int else { return nil }
            return Home(host: hh, uin: uu)
        }
        return parsed.isEmpty ? fallback : parsed
    }

    /// Deposit a pre-sealed blob to `host`'s `/messages/sealed` (no auth — sealed
    /// sender). Returns true on a 2xx.
    @discardableResult
    static func deposit(host: String, uin: Int, payload: String) async -> Bool {
        guard let url = URL(string: "https://\(host)/messages/sealed") else { return false }
        struct Body: Encodable { let to_uin: Int; let envelope_type: String; let payload: String }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Body(to_uin: uin, envelope_type: "message", payload: payload))
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }
}
