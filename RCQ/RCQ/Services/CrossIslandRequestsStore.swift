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
///
/// F1 (spec 2026-09-15): a row can also come from a VISITED island's own
/// `GET /contacts/pending`, a request somebody on that island addressed to
/// this account's guest copy there. Such a row is keyed like every other one,
/// (sender uin, island), so a §5f request and a server request from the same
/// sender are one row with both halves.
final class CrossIslandRequestsStore: ObservableObject {
    static let shared = CrossIslandRequestsStore()

    /// Live count of held requests for the pending banner / badges.
    @Published private(set) var requestCount: Int = 0
    /// Bumped on every change, including the ones that keep the count (a
    /// server row merging into a §5f row, a retry counter), so an open
    /// Requests screen redraws.
    @Published private(set) var revision: Int = 0

    /// One held message: the SEALED payload (re-fed through ingest verbatim on
    /// Accept, so it files with the correct sender + kind) plus a plaintext
    /// preview captured at quarantine time (the payload can't be previewed
    /// without decrypting).
    ///
    /// For a SAME-ISLAND row (`host: ""` - the opt-in Privacy quarantine)
    /// `payload` is instead the DECRYPTED envelope JSON: the v=2 ratchet
    /// consumed the ciphertext the moment the sender became known, so a
    /// re-feed could never open it again. `sentAt` carries the server time of
    /// those rows (nil on cross-island rows and rows persisted before it).
    struct Held: Codable {
        let payload: String
        let preview: String
        var sentAt: Date? = nil
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
        /// F1: the id of the pending row on `host` that asked for this
        /// account's guest copy there. Nil for rows that only came by §5f.
        var serverRequestID: Int? = nil
        /// F1: this account's per-island uin on `host` the row was addressed to.
        var serverGuestUIN: Int? = nil
        /// F1: the name `host` serves for the sender. The island's word, not
        /// the sender's; shown only when no §5f name came with the row.
        var serverNickname: String? = nil
        /// F1: how many times the accept deposit to the requester failed. The
        /// poll deposits it again while this is below the cap, then the row
        /// says it gave up.
        var srvAcceptTries: Int? = nil
        /// F1: the key `host` serves for the sender differs from the one this
        /// device already saw for them in a room there.
        var keyChanged: Bool? = nil
        var id: String { "\(uin)@\(host.lowercased())" }
        var preview: String { msgs.first?.preview ?? "" }
        /// True once a §5f `act:"request"` landed for this sender, or the
        /// sender's island holds a pending request for our copy there. A row
        /// can be both (they asked AND wrote); accepting handles both in one tap.
        var isContactRequest: Bool { reqNickname != nil || serverRequestID != nil }
        /// A §5f request came with this row: a decline has a requester to
        /// deposit `act:"decline"` to.
        var hasContactReq: Bool { reqNickname != nil }
        /// Capped for display: both names are somebody else's word, and a
        /// screen-long name is only there to push the island tag out of view.
        var displayName: String? {
            (reqNickname ?? serverNickname).map { String($0.prefix(CrossIslandRequestsStore.maxNameLength)) }
        }
    }

    private static let appGroup = "group.app.rcq.shared"
    private static let prefix = "rcq.ci-requests.v1."
    private static let blockedPrefix = "rcq.ci-blocked.v1."
    private static let answeredPrefix = "rcq.ci-answered.v1."
    private static let maxHeld = 20
    /// §5f anti-abuse: the deposit is open, so a stranger's request costs one
    /// HTTP call. Bound the list so a flood fills a fixed number of rows rather
    /// than the disk; the oldest rows fall off first.
    private static let maxRequests = 100
    /// Server rows answered here, oldest first. A row is answered once, and
    /// the island stops serving it once withdrawn or declined, so the set only
    /// has to outlive the rows still served; the cap keeps a flood of answered
    /// rows from growing it without end.
    private static let maxAnswered = 500
    /// A name stored or shown for a request, in characters. The rows live in
    /// the App Group suite the notification extension also opens, so an
    /// island's name cannot be allowed to grow that file.
    static let maxNameLength = 64

    private let defaults: UserDefaults
    private var key: String
    private var blockedKey: String
    private var answeredKey: String
    private var cache: [String: Request]
    private var blocked: Set<String>
    private var answered: [String]

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        let id = AppGroup.readActiveAccountID()
        key = Self.prefix + (id?.uuidString ?? "none")
        blockedKey = Self.blockedPrefix + (id?.uuidString ?? "none")
        answeredKey = Self.answeredPrefix + (id?.uuidString ?? "none")
        cache = Self.loadRequests(defaults, key)
        blocked = Self.loadBlocked(defaults, blockedKey)
        answered = Self.loadAnswered(defaults, answeredKey)
        requestCount = cache.count
    }

    /// Re-point at the active account on launch + every account switch.
    func bind(accountID: UUID?) {
        key = Self.prefix + (accountID?.uuidString ?? "none")
        blockedKey = Self.blockedPrefix + (accountID?.uuidString ?? "none")
        answeredKey = Self.answeredPrefix + (accountID?.uuidString ?? "none")
        cache = Self.loadRequests(defaults, key)
        blocked = Self.loadBlocked(defaults, blockedKey)
        answered = Self.loadAnswered(defaults, answeredKey)
        changed()
    }

    /// Forget every held request and every block of the active account (burn
    /// only). A burn mints a fresh identity under the SAME account UUID, so
    /// these keys do not change and nothing else clears them: strangers who
    /// wrote to the burned identity surfaced as pending requests to the new
    /// one, holding their sealed payloads with them. A switch must NOT call
    /// this, `bind` is that path.
    func wipe() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: blockedKey)
        defaults.removeObject(forKey: answeredKey)
        cache = [:]
        blocked = []
        answered = []
        changed()
    }

    /// Same erase for an account that is NOT the active one (a same-key
    /// account burned together with the active one, spec F2). Writes nothing
    /// into the bound account's slots.
    static func wipeStored(accountID: UUID) {
        let d = UserDefaults(suiteName: appGroup) ?? .standard
        for p in [prefix, blockedPrefix, answeredPrefix] {
            d.removeObject(forKey: p + accountID.uuidString)
        }
    }

    private func reqKey(_ uin: Int, _ host: String) -> String { "\(uin)@\(host.lowercased())" }

    private func answeredKey(_ host: String, _ id: Int) -> String { "\(host.lowercased())#\(id)" }

    func isBlocked(uin: Int, host: String) -> Bool { blocked.contains(reqKey(uin, host)) }

    /// Quarantine one sealed payload from an un-accepted cross-island sender
    /// (or, with `host: ""` + `sentAt`, one decrypted same-island envelope
    /// from the opt-in stranger quarantine).
    /// Returns false (caller drops it) when the sender is blocked.
    @discardableResult
    func hold(uin: Int, host: String, payload: String, preview: String, sentAt: Date? = nil) -> Bool {
        if isBlocked(uin: uin, host: host) { return false }
        let k = reqKey(uin, host)
        var r = cache[k] ?? Request(uin: uin, host: host, firstAt: Date(), msgs: [])
        r.msgs.append(Held(payload: payload, preview: preview, sentAt: sentAt))
        if r.msgs.count > Self.maxHeld { r.msgs = Array(r.msgs.suffix(Self.maxHeld)) }
        cache[k] = r
        persist()
        changed()
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
        changed()
        return true
    }

    // MARK: F1: rows from a visited island's pending list

    /// Merge one pending row served by `host` into the request list. Merges
    /// into an existing §5f or held row of the same sender and never moves its
    /// `firstAt`; refuses blocked senders and rows already answered here, and
    /// respects the list cap like every other row. Returns false when refused.
    @discardableResult
    func upsertServerRequest(uin: Int, host: String, id: Int, guestUIN: Int, nickname: String) -> Bool {
        let h = host.lowercased()
        if isBlocked(uin: uin, host: h) || isAnswered(host: h, id: id) { return false }
        let k = reqKey(uin, h)
        var r = cache[k] ?? Request(uin: uin, host: h, firstAt: Date(), msgs: [])
        let name = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        let next = (id, guestUIN, name.isEmpty ? nil : name)
        if r.serverRequestID == next.0, r.serverGuestUIN == next.1, r.serverNickname == next.2, cache[k] != nil {
            return true
        }
        if r.serverRequestID != id {
            // A new row id is a new request: an earlier accept's retry count
            // and key warning belonged to the old one.
            r.srvAcceptTries = nil
            r.keyChanged = nil
        }
        r.serverRequestID = next.0
        r.serverGuestUIN = next.1
        r.serverNickname = next.2
        cache[k] = r
        trim()
        persist()
        changed()
        return true
    }

    /// The island's answer is the list of rows still pending on `host`. A row
    /// here whose server id is not among them was withdrawn, answered on
    /// another device or swept: its server half goes, and a row that had
    /// nothing else (no §5f request, no held message) goes with it.
    func reconcileServerRequests(host: String, liveIDs: Set<Int>) {
        let h = host.lowercased()
        var touched = false
        for (k, r) in cache where r.host.lowercased() == h {
            guard let sid = r.serverRequestID, !liveIDs.contains(sid) else { continue }
            // Also a row waiting on an accept retry: the poll retries only rows
            // the island still serves, so one it stopped serving (the requester
            // withdrew it) would otherwise say "we'll try again" for good.
            touched = true
            if r.reqNickname == nil && r.msgs.isEmpty {
                cache[k] = nil
            } else {
                var next = r
                next.serverRequestID = nil
                next.serverGuestUIN = nil
                next.serverNickname = nil
                next.keyChanged = nil
                cache[k] = next
            }
        }
        guard touched else { return }
        persist()
        changed()
    }

    /// Remember that the pending row `id` on `host` has been answered here (or
    /// on another device of this account), so no poll offers it again. Also
    /// drops a row that consisted of that server request alone.
    func markAnswered(host: String, id: Int) {
        let a = answeredKey(host, id)
        if !answered.contains(a) {
            answered.append(a)
            if answered.count > Self.maxAnswered { answered.removeFirst(answered.count - Self.maxAnswered) }
            persistAnswered()
        }
        let h = host.lowercased()
        if let (k, r) = cache.first(where: { $0.value.host.lowercased() == h && $0.value.serverRequestID == id }) {
            if r.reqNickname == nil && r.msgs.isEmpty {
                cache[k] = nil
            } else {
                var next = r
                next.serverRequestID = nil
                next.serverGuestUIN = nil
                next.serverNickname = nil
                next.srvAcceptTries = nil
                next.keyChanged = nil
                cache[k] = next
            }
            persist()
        }
        changed()
    }

    func isAnswered(host: String, id: Int) -> Bool { answered.contains(answeredKey(host, id)) }

    func request(uin: Int, host: String) -> Request? { cache[reqKey(uin, host)] }

    /// An accept reached our list but not the requester (the deposit failed).
    /// The row stays for the poll to deposit again; its held messages are
    /// handed back for replay, because the sender is a contact now. Returns
    /// the tries so far, nil when there is no such server row.
    @discardableResult
    func holdForAcceptRetry(uin: Int, host: String) -> (tries: Int, held: [Held])? {
        let k = reqKey(uin, host)
        guard var r = cache[k], r.serverRequestID != nil else { return nil }
        let held = r.msgs
        r.msgs = []
        let tries = (r.srvAcceptTries ?? 0) + 1
        r.srvAcceptTries = tries
        cache[k] = r
        persist()
        changed()
        return (tries, held)
    }

    /// Count one more failed accept deposit made by the poll.
    func noteAcceptRetryFailed(uin: Int, host: String) {
        let k = reqKey(uin, host)
        guard var r = cache[k] else { return }
        r.srvAcceptTries = (r.srvAcceptTries ?? 0) + 1
        cache[k] = r
        persist()
        changed()
    }

    func setKeyChanged(uin: Int, host: String) {
        let k = reqKey(uin, host)
        guard var r = cache[k], r.keyChanged != true else { return }
        r.keyChanged = true
        cache[k] = r
        persist()
        changed()
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
        changed()
        return r
    }

    /// Block a sender: drop the request + remember so future deposits are dropped.
    func block(uin: Int, host: String) {
        clear(uin: uin, host: host)
        blocked.insert(reqKey(uin, host))
        persistBlocked()
    }

    private func changed() {
        requestCount = cache.count
        revision &+= 1
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

    private static func loadAnswered(_ d: UserDefaults, _ key: String) -> [String] {
        guard let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return s
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: key) }
    }

    private func persistBlocked() {
        if let data = try? JSONEncoder().encode(blocked) { defaults.set(data, forKey: blockedKey) }
    }

    private func persistAnswered() {
        if let data = try? JSONEncoder().encode(answered) { defaults.set(data, forKey: answeredKey) }
    }
}
