import Foundation

/// Variant A — cross-island "message requests" (consent).
///
/// Cross-island delivery is permissionless (open mailbox + sealed deposit, like
/// email): anyone who knows your `uin@host` can seal a message into your queue.
/// Same-island has a contact-request approval flow; cross-island has none. So
/// rather than auto-surfacing an unknown cross-island sender into the chat list,
/// we QUARANTINE their messages here until the user Accepts (→ the sender
/// becomes a normal cross-island contact and the held messages replay) or
/// Blocks. Mirrors web-chat's crossisland-requests.ts. Per-account (no bleed).
///
/// ObservableObject so the contact list's pending banner can include held
/// cross-island requests — without it the banner (the only path to
/// PendingRequestsView) never rendered when ONLY a cross-island request
/// waited, making the request invisible (founder report: 100@is2 → 911,
/// "нигде не вижу заявок"). All mutators run on the main actor
/// (MessageService.ingest, AppState, the request views).
final class CrossIslandRequestsStore: ObservableObject {
    static let shared = CrossIslandRequestsStore()

    /// Live count of held requests for the pending banner / badges.
    @Published private(set) var requestCount: Int = 0

    /// One held message: the SEALED payload (re-fed through ingest verbatim on
    /// Accept, so it files with the correct sender + kind) plus a plaintext
    /// preview captured at quarantine time (the payload can't be previewed
    /// without decrypting).
    struct Held: Codable {
        let payload: String
        let preview: String
    }

    struct Request: Codable, Identifiable {
        let uin: Int
        let host: String
        var firstAt: Date
        var msgs: [Held]
        /// §5f: the sender's self-asserted display name from their `contactreq`
        /// envelope. Non-nil ⇒ this row is a real CONTACT request (they asked to
        /// be added), not just quarantined chatter. Optional so rows persisted
        /// before §5f decode unchanged.
        var reqNickname: String? = nil
        /// §5f optional short greeting that rode with the request.
        var reqNote: String? = nil
        var id: String { "\(uin)@\(host.lowercased())" }
        var preview: String { msgs.first?.preview ?? "" }
        /// True once a §5f `act:"request"` landed for this sender. A row can be
        /// both (they asked AND wrote); accepting handles both in one tap.
        var isContactRequest: Bool { reqNickname != nil }
    }

    private static let appGroup = "group.app.rcq.shared"
    private static let prefix = "rcq.ci-requests.v1."
    private static let blockedPrefix = "rcq.ci-blocked.v1."
    private static let maxHeld = 20
    /// §5f anti-abuse: the deposit is open, so a stranger's request costs one
    /// HTTP call. Bound the list so a flood fills a fixed number of rows rather
    /// than the disk; the oldest rows fall off first.
    private static let maxRequests = 100

    private let defaults: UserDefaults
    private var key: String
    private var blockedKey: String
    private var cache: [String: Request]
    private var blocked: Set<String>

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let id = AppGroup.readActiveAccountID()
        key = Self.prefix + (id?.uuidString ?? "none")
        blockedKey = Self.blockedPrefix + (id?.uuidString ?? "none")
        cache = Self.loadRequests(defaults, key)
        blocked = Self.loadBlocked(defaults, blockedKey)
        requestCount = cache.count
    }

    /// Re-point at the active account on launch + every account switch.
    func bind(accountID: UUID?) {
        key = Self.prefix + (accountID?.uuidString ?? "none")
        blockedKey = Self.blockedPrefix + (accountID?.uuidString ?? "none")
        cache = Self.loadRequests(defaults, key)
        blocked = Self.loadBlocked(defaults, blockedKey)
        requestCount = cache.count
    }

    private func reqKey(_ uin: Int, _ host: String) -> String { "\(uin)@\(host.lowercased())" }

    func isBlocked(uin: Int, host: String) -> Bool { blocked.contains(reqKey(uin, host)) }

    /// Quarantine one sealed payload from an un-accepted cross-island sender.
    /// Returns false (caller drops it) when the sender is blocked.
    @discardableResult
    func hold(uin: Int, host: String, payload: String, preview: String) -> Bool {
        if isBlocked(uin: uin, host: host) { return false }
        let k = reqKey(uin, host)
        var r = cache[k] ?? Request(uin: uin, host: host, firstAt: Date(), msgs: [])
        r.msgs.append(Held(payload: payload, preview: preview))
        if r.msgs.count > Self.maxHeld { r.msgs = Array(r.msgs.suffix(Self.maxHeld)) }
        cache[k] = r
        persist()
        requestCount = cache.count
        return true
    }

    /// §5f: record an inbound `contactreq` with `act:"request"` as a PENDING
    /// cross-island request — the same row a quarantined message uses, so it
    /// shows up in exactly the place a same-island pending request does. The
    /// envelope itself is never written to the message store.
    ///
    /// Repeat requests from the same sender refresh the one row instead of
    /// stacking (the key is the sender), which is the client-side rate limit.
    /// Returns false when the sender is blocked (caller drops it silently).
    @discardableResult
    func holdContactRequest(uin: Int, host: String, nickname: String, note: String?) -> Bool {
        if isBlocked(uin: uin, host: host) { return false }
        let k = reqKey(uin, host)
        var r = cache[k] ?? Request(uin: uin, host: host, firstAt: Date(), msgs: [])
        r.reqNickname = nickname
        r.reqNote = (note?.isEmpty ?? true) ? nil : note
        cache[k] = r
        trim()
        persist()
        requestCount = cache.count
        return true
    }

    /// Drop the oldest rows once the bounded list overflows.
    private func trim() {
        guard cache.count > Self.maxRequests else { return }
        let doomed = cache.values
            .sorted { $0.firstAt < $1.firstAt }
            .prefix(cache.count - Self.maxRequests)
        for r in doomed { cache.removeValue(forKey: reqKey(r.uin, r.host)) }
    }

    func list() -> [Request] { cache.values.sorted { $0.firstAt > $1.firstAt } }

    func count() -> Int { cache.count }

    /// Drop a request and return it (after Accept replays its messages).
    @discardableResult
    func clear(uin: Int, host: String) -> Request? {
        let k = reqKey(uin, host)
        let r = cache[k]
        cache[k] = nil
        persist()
        requestCount = cache.count
        return r
    }

    /// Block a sender: drop the request + remember so future deposits are dropped.
    func block(uin: Int, host: String) {
        clear(uin: uin, host: host)
        blocked.insert(reqKey(uin, host))
        persistBlocked()
    }

    // MARK: persistence

    private static func loadRequests(_ d: UserDefaults, _ key: String) -> [String: Request] {
        guard let data = d.data(forKey: key),
              let m = try? JSONDecoder().decode([String: Request].self, from: data) else { return [:] }
        return m
    }

    private static func loadBlocked(_ d: UserDefaults, _ key: String) -> Set<String> {
        guard let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return s
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: key) }
    }

    private func persistBlocked() {
        if let data = try? JSONEncoder().encode(blocked) { defaults.set(data, forKey: blockedKey) }
    }
}
