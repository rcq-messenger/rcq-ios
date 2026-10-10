import Foundation

/// Report 1067, the device half: what this account knows about whether its
/// contacts on other islands still exist, and the probe that finds out. The
/// rules themselves (which answers count, when to ask, what lifts a mark) are
/// `PeerLiveness` in CrossIslandLogic.swift, where they are checked offline.
///
/// ⚠ Per account, and keyed `uin@host`, never by the bare number: numbers are
/// per island, and the same digits on our own island are somebody else
/// (#1061). Each mark also names the signing key it is about and is ignored
/// once the row at that address pins another key, or was added after the mark
/// (`PeerLiveness.holds`).
///
/// A contact found gone is MARKED, not removed: a false "gone" exists (an
/// island restored from an old database, a number that moved), and the
/// history is never touched. The person removes the contact from the chat's
/// banner when they are ready to.
@MainActor
final class PeerLivenessStore: ObservableObject {
    static let shared = PeerLivenessStore()

    /// Bumped when something a screen shows changes (a mark set or lifted),
    /// never for the probe's own stamps: the list and every row observe this,
    /// and a chat opening must not redraw them for a timestamp.
    @Published private(set) var revision = 0

    nonisolated private static let appGroup = "group.app.rcq.shared"
    nonisolated private static let keyPrefix = "rcq.peerliveness.v1."

    private let defaults: UserDefaults
    private var storeKey: String
    private var marks: [String: PeerLiveness.Mark]

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        storeKey = Self.keyFor(AppGroup.readActiveAccountID())
        marks = Self.load(defaults, storeKey)
    }

    nonisolated private static func keyFor(_ id: UUID?) -> String { keyPrefix + (id?.uuidString ?? "none") }

    private static func load(_ d: UserDefaults, _ key: String) -> [String: PeerLiveness.Mark] {
        guard let data = d.data(forKey: key),
              let map = try? JSONDecoder().decode([String: PeerLiveness.Mark].self, from: data) else { return [:] }
        return map
    }

    private func persist() {
        if marks.isEmpty {
            defaults.removeObject(forKey: storeKey)
        } else if let data = try? JSONEncoder().encode(marks) {
            defaults.set(data, forKey: storeKey)
        }
    }

    private static func address(_ uin: Int, _ host: String) -> String { "\(uin)@\(host.lowercased())" }

    /// Re-point at the active account: every account switch, and entering or
    /// leaving a decoy session (whose namespace holds nothing), like
    /// `CrossIslandStore.bind`.
    func bind(accountID: UUID?) {
        storeKey = Self.keyFor(accountID)
        marks = Self.load(defaults, storeKey)
        revision += 1
    }

    /// Burn only: the marks were about the burned identity's contacts, which
    /// `CrossIslandStore.wipe` takes away in the same breath.
    func wipe() {
        defaults.removeObject(forKey: storeKey)
        marks = [:]
        revision += 1
    }

    /// The same for an account that is NOT the active one (a same-key account
    /// burned together with it). Leaves the bound account's marks alone.
    nonisolated static func wipeStored(accountID: UUID) {
        (UserDefaults(suiteName: appGroup) ?? .standard).removeObject(forKey: keyFor(accountID))
    }

    /// The mark at `uin@host` while it still speaks about the contact pinned
    /// there now.
    private func liveMark(_ uin: Int, _ host: String) -> PeerLiveness.Mark? {
        guard let m = marks[Self.address(uin, host)] else { return nil }
        let row = CrossIslandStore.shared.row(uin: uin, host: host)
        let ok = PeerLiveness.holds(
            m, rowSigningKey: row?.signingKey,
            rowAddedAt: CrossIslandStore.shared.addedAtFor(uin, host)
        )
        return ok ? m : nil
    }

    /// Is any address marked gone at all? For the per-message path, so the
    /// common case (nobody marked) skips the row lookup. The probe stamps live
    /// in the same records, so "any record" would be true for most accounts.
    var hasGoneMarks: Bool { marks.values.contains { $0.gone != nil } }

    /// Their island says this account no longer exists.
    func isGone(uin: Int, host: String) -> Bool {
        guard !marks.isEmpty else { return false }
        return liveMark(uin, host)?.gone != nil
    }

    /// Their island serves this address under a key other than the pinned one.
    func keyChanged(uin: Int, host: String) -> Bool {
        guard !marks.isEmpty, let m = liveMark(uin, host) else { return false }
        return m.keyChanged != nil && m.gone == nil
    }

    /// The record about `sk` at this address with no row checks: the probe's
    /// stamps are bookkeeping, valid for as long as the key is the same.
    func stamps(uin: Int, host: String, sk: String) -> PeerLiveness.Mark? {
        guard let m = marks[Self.address(uin, host)], PeerLiveness.sameKey(m.sk, sk) else { return nil }
        return m
    }

    /// Change the record for `uin@host` and write it back only if something
    /// changed. Only about the contact pinned at that address under `sk`: a key
    /// that is not pinned there (a stale caller) leaves nothing, and a record
    /// that no longer holds starts over, keeping only its probe stamps.
    func update(uin: Int, host: String, sk: String, notify: Bool = true,
                _ change: (inout PeerLiveness.Mark) -> Void) {
        guard let row = CrossIslandStore.shared.row(uin: uin, host: host),
              !row.signingKey.isEmpty, PeerLiveness.sameKey(sk, row.signingKey) else { return }
        let k = Self.address(uin, host)
        let prev = marks[k]
        var next = PeerLiveness.Mark(sk: row.signingKey)
        if let prev, PeerLiveness.sameKey(prev.sk, row.signingKey) {
            if PeerLiveness.holds(prev, rowSigningKey: row.signingKey,
                                  rowAddedAt: CrossIslandStore.shared.addedAtFor(uin, host)) {
                next = prev
            } else {
                next.probedAt = prev.probedAt
                next.failProbeAt = prev.failProbeAt
            }
        }
        change(&next)
        if next == prev { return }
        if prev == nil && next.isEmpty { return }
        marks[k] = next
        persist()
        if notify { revision += 1 }
    }

    /// A message from the contact at `uin@host`, verified under the key pinned
    /// for them, deposited at `depositedAt`: they are there. The one place an
    /// "account deleted" mark comes off (`PeerLiveness.heardFromLifts`).
    func noteHeardFrom(uin: Int, host: String, depositedAt: Date?) {
        // Every verified envelope from another island passes through here, so
        // the common case (nothing marked) is decided without a lookup.
        guard !marks.isEmpty, let m = liveMark(uin, host) else { return }
        let at = depositedAt.map { $0.timeIntervalSince1970 * 1000 }
        guard PeerLiveness.heardFromLifts(m, depositedAt: at) else { return }
        update(uin: uin, host: host, sk: m.sk) { $0.gone = nil }
    }

    /// The contact was removed: whatever was known about that address goes too.
    func forget(uin: Int, host: String) {
        guard marks.removeValue(forKey: Self.address(uin, host)) != nil else { return }
        persist()
        revision += 1
    }
}

/// Asks a contact's island whether the account pinned at `uin@host` still
/// exists, and marks the answer (report 1067). See `PeerLiveness` for the
/// three questions and why only exact answers count.
///
/// ⚠⚠ Never `/messages/sealed` and never `island-record` on their island: a
/// deposit wakes the phone at the other end and answers with presence, and the
/// record endpoint is a per-number lookup there is no reason to make. The
/// probe asks only about a number and a key this device already holds.
///
/// ⚠ Step 3 reads our OWN island's gossip mirror (the same bounded, no-redirect
/// GET), and a read keeps the mirrored record alive there (it renews its
/// `touched_at`). That is why a contact
/// marked gone is never probed again, and why a send to one skips the mirror
/// (`MessageService.sendEnvelope`): a burned person's "where to reach me" must
/// not be kept warm on our island by our own retries.
@MainActor
enum PeerLivenessProbe {
    /// The probe running for an address, with our island's clock at its last
    /// answer.
    private static var inFlight: [String: Task<(PeerLiveness.Verdict, Double?), Never>] = [:]

    /// One request to their island is given this long, start to finish.
    nonisolated private static let deadline: TimeInterval = 10
    /// A key card, a uin or a record of homes is a few hundred bytes; more is
    /// not an answer.
    nonisolated private static let bodyCap = 8 * 1024

    /// Ask, at most once a day per address for `.open` and every few minutes
    /// for `.failure`. Never throws; a skipped probe answers `.unknown`.
    ///
    /// Only for a contact held in `CrossIslandStore`: the pinned keys are half
    /// of the question, and without them there is nobody to ask about.
    @discardableResult
    static func probe(uin: Int, host: String, trigger: PeerLiveness.Trigger) async -> PeerLiveness.Verdict {
        // A duress session has no contacts of its own on other islands and puts
        // nothing on the wire for the real account's ones.
        guard !PanicPINService.shared.isDecoy, !Multihome.isOwnHost(host) else { return .unknown }
        guard let row = CrossIslandStore.shared.row(uin: uin, host: host),
              !row.signingKey.isEmpty, !row.identityKey.isEmpty else { return .unknown }
        let address = "\(uin)@\(host.lowercased())"
        if let running = inFlight[address] { return await running.value.0 }
        let store = PeerLivenessStore.shared
        // Already gone: the mark stands until they write, and asking again would
        // only renew their record in our island's mirror (see above).
        if store.isGone(uin: uin, host: host) { return .gone }
        let sk = row.signingKey
        let ik = row.identityKey
        let prev = store.stamps(uin: uin, host: host, sk: sk)
        let now = Date().timeIntervalSince1970 * 1000
        let last = trigger == .open ? prev?.probedAt : prev?.failProbeAt
        guard PeerLiveness.mayProbe(trigger, last: last, now: now) else { return .unknown }
        // Stamped before the network, so a relaunch in the middle does not ask
        // twice. Not announced: nothing on screen depends on it.
        store.update(uin: uin, host: host, sk: sk, notify: false) {
            $0.probedAt = now
            if trigger == .failure { $0.failProbeAt = now }
        }
        let account = AccountManager.shared.activeAccountID
        let ownHost = Multihome.ownHost()
        let job = Task<(PeerLiveness.Verdict, Double?), Never> {
            // Our own island's clock at its answer about the record: the clock
            // its deposit stamps are on, which is what lifts the mark later.
            var islandNow: Double?
            let verdict = await PeerLiveness.classify(
                uin: uin, host: host, pinnedIdentityKey: ik, pinnedSigningKey: sk,
                get: { path in await fetch(host: host, path: path) },
                record: {
                    let reply = await fetch(host: ownHost, path: PeerLiveness.recordPath(signingKey: sk))
                    islandNow = reply?.islandNow
                    return PeerLiveness.recordStep(reply, host: host, uin: uin) { body in
                        verifiedHomes(body, signingKey: sk)
                    }
                }
            )
            return (verdict, islandNow)
        }
        inFlight[address] = job
        let (verdict, islandNow) = await job.value
        inFlight[address] = nil
        // The answer is about the account that asked. A switch or a duress
        // session while it was out leaves it unwritten rather than filed under
        // whoever is signed in now.
        guard AccountManager.shared.activeAccountID == account, !PanicPINService.shared.isDecoy else {
            return verdict
        }
        let at = Date().timeIntervalSince1970 * 1000
        store.update(uin: uin, host: host, sk: sk) { m in
            m = PeerLiveness.applying(verdict, to: m, now: at, islandNow: islandNow)
        }
        return verdict
    }

    /// One GET to their island. Never engages the tunnel for this (it still
    /// rides one that is already up): opening a chat must not start relays on
    /// its own, and a route that is blocked is simply an unknown. Redirects are
    /// refused, so only the island's own answer about itself counts, and the
    /// whole request is bounded, not just the gaps between its bytes.
    nonisolated private static func fetch(host: String, path: String) async -> PeerLiveness.Reply? {
        guard let url = URL(string: "https://\(host)\(path)") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: deadline)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
        let request = req
        return await BackupAutoPick.withDeadline(deadline) {
            guard let (body, resp) = try? await IslandHTTP.probe(for: request, cap: bodyCap, delegate: RefuseProbeRedirects()),
                  let http = resp as? HTTPURLResponse else { return nil }
            return PeerLiveness.Reply(
                status: http.statusCode, body: body,
                islandNow: PeerLiveness.httpDate(http.value(forHTTPHeaderField: "Date"))
            )
        }
    }

    /// The homes a record our own island served names, verified under the
    /// pinned key. Nil when it is not a record or does not verify, which
    /// `PeerLiveness.recordStep` reads as unknown, never as "no record".
    nonisolated private static func verifiedHomes(_ body: Data, signingKey: String) -> [PeerLiveness.Home]? {
        guard let rec = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              case .success(let doc) = RcqFederation.verifyRecord(rec, opts: .init(expectedSk: signingKey)),
              let homes = doc["homes"] as? [[String: Any]] else { return nil }
        return homes.compactMap { h in
            guard let host = h["host"] as? String, let uin = h["uin"] as? Int else { return nil }
            return PeerLiveness.Home(host: host, uin: uin)
        }
    }
}

/// Refuses every redirect for the liveness probe: the 3xx itself comes back as
/// the answer, which reads as unknown. Only the redirection callback, so the
/// body stays with the call (see `IslandHTTP.probe`).
private final class RefuseProbeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
