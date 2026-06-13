import Foundation

/// In-chat bridge sharing — relays a contact handed you (or you imported by
/// hand) that AUGMENT the signed relay-config pool. Device-level (NOT
/// account-scoped): the transport is per device, and a relay works regardless
/// of which account is active. Persists accepted relays plus who shared each +
/// when. Deduped by `proto:server:port`, capped, each given a unique tag
/// (`shared-<server>-<port>`) so it can never collide with a signed-config tag.
///
/// `SingBoxTransport` appends `relays()` to the verified/bundled pool at the
/// BACK of the priority-sorted list (priority 1000) = extra fallback capacity
/// that never displaces a canary-verified relay nor becomes the onion sticky
/// entry. Its only exposure is metadata + DoS (sealed sender + E2E mean it
/// can't read or forge), so accepting one from a trusted contact is safe within
/// the relay trust model. Mirrors Android ContactRelayStore. See
/// RCQ/docs/bridge-sharing-design.md.
@MainActor
final class ContactRelayStore {
    static let shared = ContactRelayStore()
    private init() {}

    typealias Relay = RelayConfigStore.RelayEntry

    struct Entry: Codable {
        let relay: Relay
        let fromUin: Int          // 0 = manual import
        let fromName: String?
        let addedAt: Double
    }

    private let key = "rcq.contactRelays.v1"
    private let maxEntries = 30
    private static let sharedPriority = 1000  // sort after all signed-config relays

    private func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    private func save(_ list: [Entry]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func dedupKey(_ r: Relay) -> String { "\(r.proto.rawValue):\(r.server):\(r.port)" }

    func list() -> [Entry] { load().sorted { $0.addedAt > $1.addedAt } }
    func relays() -> [Relay] { load().map { $0.relay } }
    func count() -> Int { load().count }
    func has(_ r: Relay) -> Bool { load().contains { dedupKey($0.relay) == dedupKey(r) } }

    /// Add a shared/imported relay. De-dups by proto:server:port (a re-add
    /// refreshes the source/label), assigns a unique tag, caps the list.
    /// Returns true when something new was stored.
    @discardableResult
    func add(_ r: Relay, fromUin: Int, fromName: String?) -> Bool {
        let tagged = Self.retag(r)
        var list = load()
        if let idx = list.firstIndex(where: { dedupKey($0.relay) == dedupKey(tagged) }) {
            list[idx] = Entry(relay: list[idx].relay, fromUin: fromUin, fromName: fromName, addedAt: list[idx].addedAt)
            save(list)
            return false
        }
        list.insert(Entry(relay: tagged, fromUin: fromUin, fromName: fromName, addedAt: Date().timeIntervalSince1970), at: 0)
        if list.count > maxEntries { list = Array(list.prefix(maxEntries)) }
        save(list)
        return true
    }

    func remove(tag: String) { save(load().filter { $0.relay.tag != tag }) }

    private static func retag(_ r: Relay) -> Relay {
        let safe = String(r.server.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return Relay(
            tag: "shared-\(safe)-\(r.port)", server: r.server, port: r.port, sni: r.sni,
            priority: sharedPriority, proto: r.proto, uuid: r.uuid, publicKey: r.publicKey,
            shortID: r.shortID, flow: r.flow, password: r.password, obfsPassword: r.obfsPassword,
        )
    }

    // MARK: - Relay <-> wire (the `relay` object inside a relay_share envelope)

    nonisolated static func relayToWire(_ r: Relay) -> Envelope.RelayShareWire {
        Envelope.RelayShareWire(
            proto: r.proto.rawValue, server: r.server, port: r.port, sni: r.sni,
            uuid: r.uuid?.isEmpty == false ? r.uuid : nil,
            pbk: r.publicKey?.isEmpty == false ? r.publicKey : nil,
            sid: r.shortID?.isEmpty == false ? r.shortID : nil,
            flow: r.flow?.isEmpty == false ? r.flow : nil,
            pw: r.password?.isEmpty == false ? r.password : nil,
            obfs: r.obfsPassword?.isEmpty == false ? r.obfsPassword : nil,
            label: r.tag.isEmpty ? nil : r.tag,
        )
    }

    nonisolated static func relayFromWire(_ w: Envelope.RelayShareWire) -> Relay? {
        let protoStr = (w.proto == "hy2") ? "hysteria2" : w.proto
        guard let proto = RelayConfigStore.RelayProtocol(rawValue: protoStr) else { return nil }
        if proto == .vless, (w.uuid ?? "").isEmpty { return nil }
        if proto == .hysteria2, (w.pw ?? "").isEmpty { return nil }
        let label = (w.label?.isEmpty == false) ? w.label! : "shared-\(w.server)-\(w.port)"
        return Relay(
            tag: label, server: w.server, port: w.port, sni: w.sni, priority: sharedPriority,
            proto: proto, uuid: w.uuid, publicKey: w.pbk, shortID: w.sid, flow: w.flow,
            password: w.pw, obfsPassword: w.obfs,
        )
    }

    // MARK: - Text token (rcq-relay://) for manual import / out-of-band

    nonisolated static func relayToToken(_ r: Relay) -> String {
        var c = URLComponents()
        c.scheme = "rcq-relay"
        c.host = (r.proto == .hysteria2) ? "hy2" : "vless"
        var q: [URLQueryItem] = [
            .init(name: "s", value: r.server),
            .init(name: "p", value: String(r.port)),
            .init(name: "sni", value: r.sni),
        ]
        if let v = r.uuid, !v.isEmpty { q.append(.init(name: "id", value: v)) }
        if let v = r.publicKey, !v.isEmpty { q.append(.init(name: "pbk", value: v)) }
        if let v = r.shortID, !v.isEmpty { q.append(.init(name: "sid", value: v)) }
        if let v = r.flow, !v.isEmpty { q.append(.init(name: "fl", value: v)) }
        if let v = r.password, !v.isEmpty { q.append(.init(name: "pw", value: v)) }
        if let v = r.obfsPassword, !v.isEmpty { q.append(.init(name: "obfs", value: v)) }
        c.queryItems = q
        return c.string ?? ""
    }

    /// Parse an `rcq-relay://` token. Returns nil on anything malformed.
    nonisolated static func relayFromToken(_ token: String) -> Relay? {
        guard let c = URLComponents(string: token.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "rcq-relay" else { return nil }
        let proto: RelayConfigStore.RelayProtocol
        switch c.host?.lowercased() {
        case "hy2", "hysteria2": proto = .hysteria2
        case "vless", .none: proto = .vless
        default: return nil
        }
        func q(_ k: String) -> String? { c.queryItems?.first(where: { $0.name == k })?.value }
        guard let server = q("s"), let portStr = q("p"), let port = Int(portStr), let sni = q("sni") else { return nil }
        let uuid = q("id"); let pw = q("pw")
        if proto == .vless, (uuid ?? "").isEmpty { return nil }
        if proto == .hysteria2, (pw ?? "").isEmpty { return nil }
        return Relay(
            tag: "shared-\(server)-\(port)", server: server, port: port, sni: sni, priority: sharedPriority,
            proto: proto, uuid: uuid, publicKey: q("pbk"), shortID: q("sid"), flow: q("fl"),
            password: pw, obfsPassword: q("obfs"),
        )
    }
}
