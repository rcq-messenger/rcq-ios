import Foundation
import CryptoKit

/// Cross-island GROUPS (room-host, federation §5c).
///
/// A group lives entirely on ONE island; a member from another island becomes
/// a first-class citizen of the group's island via a GUEST registration —
/// recover-first with the SAME keypair (the multihome mechanic), giving a
/// per-island (uin, jwt). All group machinery then runs unchanged on the host
/// island; the guest client deposits sends there and polls its guest mailbox.
/// No island ever talks to another island.
///
/// Unlike multihome backup homes, visited islands are PRIVATE: never published
/// in the signed home-island record (group membership is not an addressing
/// fact). Per-account, mirroring CrossIslandRequestsStore.
///
/// Foreign group ids: per-island ints collide across islands, and every store
/// (threads/unread/routes) keys groups by an Int. Foreign groups therefore get
/// a stable NEGATIVE local alias id; the API boundary translates
/// alias ↔ (host, remoteId). Mirrors web visited-islands.ts / Android
/// VisitedIslandsStore.
final class VisitedIslandsStore {
    static let shared = VisitedIslandsStore()

    struct Visited: Codable {
        let host: String
        let uin: Int     // per-island uin of this identity (same keys as primary)
        let jwt: String
        let addedAt: Date
    }

    struct AliasRef: Codable {
        let host: String
        let remoteId: Int
        let aliasId: Int // negative, stable per account
    }

    private static let appGroup = "group.app.rcq.shared"
    private static let visitedPrefix = "rcq.visited.v1."
    private static let aliasPrefix = "rcq.fgroup-alias.v1."

    private let defaults: UserDefaults
    private var visitedKey: String
    private var aliasKey: String

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let id = AppGroup.readActiveAccountID()
        visitedKey = Self.visitedPrefix + (id?.uuidString ?? "none")
        aliasKey = Self.aliasPrefix + (id?.uuidString ?? "none")
    }

    /// Re-point at the active account on launch + every account switch.
    func bind(accountID: UUID?) {
        visitedKey = Self.visitedPrefix + (accountID?.uuidString ?? "none")
        aliasKey = Self.aliasPrefix + (accountID?.uuidString ?? "none")
    }

    // MARK: visited islands

    func list() -> [Visited] {
        guard let data = defaults.data(forKey: visitedKey),
              let v = try? JSONDecoder().decode([Visited].self, from: data) else { return [] }
        return v
    }

    func get(host: String) -> Visited? { list().first { $0.host == host.lowercased() } }

    func save(_ v: Visited) {
        let next = list().filter { $0.host != v.host.lowercased() } +
            [Visited(host: v.host.lowercased(), uin: v.uin, jwt: v.jwt, addedAt: v.addedAt)]
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: visitedKey) }
    }

    func updateCreds(host: String, uin: Int, jwt: String) {
        guard let cur = get(host: host) else { return }
        save(Visited(host: cur.host, uin: uin, jwt: jwt, addedAt: cur.addedAt))
    }

    // MARK: foreign-group alias ids

    private func aliases() -> [AliasRef] {
        guard let data = defaults.data(forKey: aliasKey),
              let a = try? JSONDecoder().decode([AliasRef].self, from: data) else { return [] }
        return a
    }

    func isForeignGroupId(_ id: Int) -> Bool { id < 0 }

    /// Stable local alias for (host, remoteId); allocated on first sight.
    func aliasFor(host: String, remoteId: Int) -> Int {
        let h = host.lowercased()
        let all = aliases()
        if let hit = all.first(where: { $0.host == h && $0.remoteId == remoteId }) { return hit.aliasId }
        let aliasId = -(1000 + all.count) // negative: server ids are positive
        let next = all + [AliasRef(host: h, remoteId: remoteId, aliasId: aliasId)]
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: aliasKey) }
        return aliasId
    }

    func refByAlias(_ aliasId: Int) -> AliasRef? { aliases().first { $0.aliasId == aliasId } }

    func wipe() {
        defaults.removeObject(forKey: visitedKey)
        defaults.removeObject(forKey: aliasKey)
    }
}

/// Raw-host group operations for §5c. APIClient is pinned to the primary
/// island, so every cross-island call goes through URLSession directly here
/// (groups list/preview/join with the guest jwt; group-sealed deposit is the
/// open unauthenticated path; queue drain with the guest jwt). The returned
/// RCQGroups are stamped with the local alias id + host so the rest of the app
/// keeps working on plain Ints.
enum CrossIslandGroups {
    enum CIGError: Error { case noKeys, http(Int) }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = iso.date(from: s) ?? isoPlain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    /// Guest credentials for `host`, registering recover-first on first use —
    /// the multihome mechanic, but PRIVATE (never published). Throws on failure.
    static func ensureGuest(host: String, nickname: String) async throws -> VisitedIslandsStore.Visited {
        guard let h = Multihome.normalizeHost(host) else { throw Multihome.AddError.invalidHost }
        if let existing = VisitedIslandsStore.shared.get(host: h) { return existing }
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes),
              let idBytes = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let identityPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: idBytes) else {
            throw CIGError.noKeys
        }
        let creds: Multihome.Credentials
        if let recovered = try await Multihome.recoverOn(host: h, signingPriv: signingPriv) {
            creds = recovered
        } else {
            creds = try await postJSON(
                "https://\(h)/auth/register",
                json: [
                    "nickname": nickname,
                    "identity_key": identityPriv.publicKey.rawRepresentation.base64EncodedString(),
                    "signing_key": signingPriv.publicKey.rawRepresentation.base64EncodedString(),
                ],
                jwt: nil
            )
        }
        let v = VisitedIslandsStore.Visited(host: h, uin: creds.uin, jwt: creds.token, addedAt: Date())
        VisitedIslandsStore.shared.save(v)
        return v
    }

    /// Refresh an expired guest jwt via the recover handshake. Returns the
    /// updated entry or nil.
    static func refreshGuest(host: String) async -> VisitedIslandsStore.Visited? {
        guard let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let signingPriv = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes),
              let c = ((try? await Multihome.recoverOn(host: host, signingPriv: signingPriv)) ?? nil)
        else { return nil }
        VisitedIslandsStore.shared.updateCreds(host: host, uin: c.uin, jwt: c.token)
        return VisitedIslandsStore.shared.get(host: host)
    }

    /// Creds for a foreign host: a visited/guest island OR one of our BACKUP
    /// islands (multihome). A cross-island group can be hosted on EITHER — both
    /// stores hold this identity's (uin, jwt) for that host. Without the backup
    /// fallback, a group on your backup island has no roster/name and its sends
    /// misroute to your own island (the "Группа / 0 участников / не дошло" bug).
    static func foreignCreds(host: String, ownUIN: Int?) -> (uin: Int, jwt: String)? {
        if let v = VisitedIslandsStore.shared.get(host: host) { return (v.uin, v.jwt) }
        guard let me = ownUIN else { return nil }
        if let h = MultihomeStore.shared.list(ownUin: me).first(where: { $0.host.lowercased() == host.lowercased() }) {
            return (h.uin, h.jwt)
        }
        return nil
    }

    /// Groups we joined on `host`, ids rewritten to the local alias + host
    /// stamped. A 401 refreshes the guest jwt once (visited islands only; a
    /// backup island's token is long-lived + refreshed by the backup drain).
    /// [] on any failure.
    static func guestGroups(host: String, ownUIN: Int?) async -> [RCQGroup] {
        guard let creds = foreignCreds(host: host, ownUIN: ownUIN) else { return [] }
        func fetch(_ jwt: String) async throws -> [RCQGroup] {
            try await getJSON("https://\(host)/groups", jwt: jwt)
        }
        do {
            var groups: [RCQGroup]
            do {
                groups = try await fetch(creds.jwt)
            } catch CIGError.http(401) {
                guard let fresh = await refreshGuest(host: host) else { return [] }
                groups = try await fetch(fresh.jwt)
            }
            return groups.map { g in
                var g = g
                g.id = VisitedIslandsStore.shared.aliasFor(host: host, remoteId: g.id)
                g.host = host
                return g
            }
        } catch {
            return []
        }
    }

    /// Preview a foreign group. The invite LINK is the capability, so we read the
    /// PUBLIC card (name/avatar/member count) even on an island we haven't visited
    /// — the server's /groups/{id}/preview is optional-auth. Sends the guest token
    /// when we have one (visited), otherwise unauthenticated. So a received
    /// cross-island invite shows the real group, not a blank card.
    static func previewForeign(host: String, remoteId: Int) async -> GroupService.GroupPreview? {
        let jwt = VisitedIslandsStore.shared.get(host: host)?.jwt
        return try? await getJSON("https://\(host)/groups/\(remoteId)/preview", jwt: jwt)
    }

    /// §5c join: guest-register (explicit user action — seeing a link never
    /// touches the island), join there, return the group stamped with the
    /// local alias + host. Nil on failure.
    static func joinForeign(host: String, remoteId: Int, nickname: String) async -> RCQGroup? {
        do {
            let v = try await ensureGuest(host: host, nickname: nickname)
            let g: RCQGroup = try await postJSON("https://\(host)/groups/\(remoteId)/join", json: [:], jwt: v.jwt)
            var aliased = g
            aliased.id = VisitedIslandsStore.shared.aliasFor(host: host, remoteId: remoteId)
            aliased.host = host
            return aliased
        } catch {
            return nil
        }
    }

    /// §5c owner-initiated group add: the local uin bound to a signing key on
    /// `host`, or nil when no account there has it yet. Open inverse key card.
    static func resolveUinForKey(host: String, signingKeyB64: String) async -> Int? {
        guard let enc = signingKeyB64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(host)/federation/uin-for-key?signing_key=\(enc)") else { return nil }
        var ukReq = URLRequest(url: url)
        AccessTokenStore.stamp(&ukReq)   // closed-island gate (foreign host)
        guard let (data, resp) = try? await URLSession.shared.data(for: ukReq),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        struct Out: Decodable { let uin: Int }
        return (try? decoder.decode(Out.self, from: data))?.uin
    }

    /// §5c: register a contact's PUBLIC keys on `host` so an owner-initiated add
    /// has a local uin for the roster. The contact later recovers the SAME uin
    /// (recover-first is keyed by the signing key). Returns the new uin, or nil.
    static func registerForeignKeys(host: String, identityKey: String, signingKey: String, nickname: String) async -> Int? {
        struct Out: Decodable { let uin: Int }
        let out: Out? = try? await postJSON(
            "https://\(host)/auth/register",
            json: ["nickname": nickname, "identity_key": identityKey, "signing_key": signingKey],
            jwt: nil
        )
        return out?.uin
    }

    /// Deposit a group fan-out into the group's island. The deposit endpoint is
    /// the open unauthenticated path (same as 1:1), so no jwt needed.
    struct GroupEntry: Encodable { let to_uin: Int; let payload: String }
    static func groupSealedDeposit(host: String, remoteId: Int, envelopeType: String, payloads: [GroupEntry]) async throws {
        struct Body: Encodable { let group_id: Int; let envelope_type: String; let payloads: [GroupEntry] }
        let body = try JSONEncoder().encode(Body(group_id: remoteId, envelope_type: envelopeType, payloads: payloads))
        guard let url = URL(string: "https://\(host)/messages/group-sealed") else { throw CIGError.http(0) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CIGError.http(code) }
    }

    /// Drain the guest mailbox on every visited island (the receive path — the
    /// host island spools group fan-out there). Group rows file under the local
    /// alias; a stray 1:1 row routes through the normal ingest, whose
    /// cross-island consent gate quarantines unknown senders. Mirrors the
    /// multihome backup drain.
    @MainActor
    static func drainVisitedQueues() async {
        struct Row: Decodable { let envelope_type: String; let payload: String; let group_id: Int? }
        for v in VisitedIslandsStore.shared.list() {
            var rows: [Row]? = try? await getJSON("https://\(v.host)/messages/queue", jwt: v.jwt)
            if rows == nil, let fresh = await refreshGuest(host: v.host) {
                rows = try? await getJSON("https://\(v.host)/messages/queue", jwt: fresh.jwt)
            }
            guard let rows else { continue }
            for r in rows {
                let gid = r.group_id.map { VisitedIslandsStore.shared.aliasFor(host: v.host, remoteId: $0) }
                let packet = WebSocketService.EnvelopePacket(
                    type: r.envelope_type, payload: r.payload, serverTime: Date(),
                    offline: true, groupID: gid
                )
                _ = MessageService.shared.ingest(envelope: packet)
            }
        }
    }

    // MARK: raw HTTP

    private static func getJSON<T: Decodable>(_ urlString: String, jwt: String?) async throws -> T {
        guard let url = URL(string: urlString) else { throw CIGError.http(0) }
        var req = URLRequest(url: url)
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CIGError.http(code) }
        return try decoder.decode(T.self, from: data)
    }

    private static func postJSON<T: Decodable>(_ urlString: String, json: [String: String], jwt: String?) async throws -> T {
        guard let url = URL(string: urlString) else { throw CIGError.http(0) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CIGError.http(code) }
        return try decoder.decode(T.self, from: data)
    }
}
