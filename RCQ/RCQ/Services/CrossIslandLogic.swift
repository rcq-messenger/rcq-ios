import Foundation

// Pure rules behind the cross-island features (spec 2026-09-15): the poll of
// pending contact requests on visited islands (F1), the burn cascade over
// this account's copies on other islands (F2), which catalogue island the
// backup toggle may register on (report #988), and at the bottom the three
// rules report #1024 and the push reports turned out to be made of — how the
// cross-island half of the visible roster is folded, which island a number
// means when a card is about to resolve it, and what an island's reply can say
// about our own row being a guest copy.
//
// ⚠ Foundation only, on purpose. No keychain, no stores, no `IslandHTTP`, no
// main actor: every input comes in as a value and every side effect goes out
// through a protocol. The app has no unit-test target, so this file is the
// part that can be compiled on its own against a fake transport and checked
// case by case; keep anything that touches the app out of it.

// MARK: - F1: when to poll one island

/// When to ask one visited island for the pending contact requests addressed
/// to this account's copy there. The caller passes the clock, the jitter
/// comes from an injected source, and nothing here does I/O.
///
/// - A host never polled is due at once.
/// - After a good answer the next poll is due in 5 min, jittered ±20%.
/// - Each failure waits longer: 5, 10, 20, 40, then 60 min flat.
/// - A 429's Retry-After is honoured, but never read as less than 5 min.
/// - `forceSoon` (the Requests screen opening) makes a host due at once, at
///   most once per 60 s per host, and never while the host is backing off:
///   an island that told us to wait is not asked again because a screen
///   opened.
///
/// The cadence is the whole privacy budget of this poll (spec F1, "What B
/// learns"): one request per 5 min or slower, against a 30 s queue poll that
/// already runs. `GET /contacts/pending` is limited to 120 a minute; this
/// stays three orders of magnitude under it.
struct PendingPollSchedule {
    static let base: TimeInterval = 300
    static let jitter = 0.2
    static let backoff: [TimeInterval] = [300, 600, 1200, 2400, 3600]
    static let retryAfterFloor: TimeInterval = 300
    static let forceDebounce: TimeInterval = 60

    private struct HostState {
        var nextAt: Date
        var failures: Int
        var lastForce: Date?
    }

    private var hosts: [String: HostState] = [:]
    /// A value in 0..<1. Injected so the jitter bounds can be checked.
    private let random: () -> Double

    init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    func due(_ host: String, now: Date) -> Bool {
        guard let s = hosts[host.lowercased()] else { return true }
        return now >= s.nextAt
    }

    /// Record the outcome of one poll. `retryAfter` is the 429's header, nil
    /// for every other failure and for a success.
    mutating func onResult(_ host: String, ok: Bool, retryAfter: TimeInterval? = nil, now: Date) {
        let key = host.lowercased()
        var s = hosts[key] ?? HostState(nextAt: now, failures: 0, lastForce: nil)
        if ok {
            s.failures = 0
            let spread = Self.base * Self.jitter
            s.nextAt = now.addingTimeInterval(Self.base - spread + 2 * spread * min(max(random(), 0), 1))
        } else {
            var wait = Self.backoff[min(s.failures, Self.backoff.count - 1)]
            if let retryAfter { wait = max(wait, max(retryAfter, Self.retryAfterFloor)) }
            s.failures += 1
            s.nextAt = now.addingTimeInterval(wait)
        }
        hosts[key] = s
    }

    /// Pull the next poll of `host` in to now. Returns false when the call was
    /// debounced or the host is backing off, and the caller should not poll.
    @discardableResult
    mutating func forceSoon(_ host: String, now: Date) -> Bool {
        let key = host.lowercased()
        guard var s = hosts[key] else {
            hosts[key] = HostState(nextAt: now, failures: 0, lastForce: now)
            return true
        }
        guard s.failures == 0 else { return false }
        if let last = s.lastForce, now.timeIntervalSince(last) < Self.forceDebounce { return false }
        s.lastForce = now
        s.nextAt = min(s.nextAt, now)
        hosts[key] = s
        return true
    }
}

// MARK: - F1: what to do with one server row

/// One row of `GET /contacts/pending` on a visited island, measured against
/// what this device already knows. Order matters and is the spec's:
/// a block wins over everything, an answer already given is never given
/// twice, an accept whose deposit failed is retried before the "already a
/// contact" rule (that failed accept is what saved the contact), and only a
/// row nobody has dealt with is shown.
enum PendingRowRule {
    enum Action: Equatable {
        /// `DELETE /contacts/pending/{id}` on that island.
        case withdraw
        /// Hide it here for good; the island keeps the row. For islands that
        /// do not advertise `contact_pending_withdraw`: never a decline in
        /// its place, which would tell the requester "no" (spec F1 security).
        case markAnswered
        /// Deposit the accept again (it did not reach the requester).
        case redeposit
        /// Leave the row as it is (answered and settled, or given up on).
        case keep
        /// Show it as a request, merged with any §5f row of the same sender.
        case upsert
    }

    static let maxAcceptTries = 3

    static func action(
        blocked: Bool,
        answered: Bool,
        acceptTries: Int,
        isContact: Bool,
        canWithdraw: Bool
    ) -> Action {
        if blocked { return canWithdraw ? .withdraw : .markAnswered }
        // An answered row still served by the island is one whose withdraw did
        // not land (network, stale capability). Asking again is right: the
        // answer was given, and a success or `no_such_request` ends it.
        if answered { return canWithdraw ? .withdraw : .keep }
        if acceptTries > 0 { return acceptTries < maxAcceptTries ? .redeposit : .keep }
        if isContact { return canWithdraw ? .withdraw : .markAnswered }
        return .upsert
    }
}

// MARK: - F1: which room ids the prior-key check reads

/// The room ids a sender-key chain from a room on `host` can be filed under.
///
/// A room on another island has a negative local alias here, but the SKDM that
/// set up a chain carries whatever id its sender used: a member at home on
/// that island (and Android and the web) sends the island's own positive id,
/// an iOS visitor sends its alias. So both go in, or the chains of every
/// native member are never found and the check falls back to the roster keys
/// served by the very island it is checking.
///
/// ⚠ A positive id can also be the id of a room on another island that happens
/// to share the number, with a sender that shares the uin. The result is an
/// extra key to compare, which can only raise a warning, never skip one.
enum PriorKeyRooms {
    static func gids(
        roomIDs: [Int],
        host: String,
        remote: (Int) -> (host: String, remoteId: Int)?
    ) -> Set<Int> {
        let h = host.lowercased()
        var out = Set<Int>()
        for id in roomIDs {
            out.insert(id)
            guard id < 0, let ref = remote(id), ref.host.lowercased() == h, ref.remoteId > 0 else { continue }
            out.insert(ref.remoteId)
        }
        return out
    }
}

// MARK: - F2: burn across islands

/// One island this account has a copy on, as the burn sees it.
///
/// `keys` are raw Ed25519 private keys in the order to try them. Today that is
/// the one signing key; ⏭ a pending rotation (F3, release C2) puts both keys
/// here, the old one first for an island the rotation has not reached, so a
/// burn mid-rotation still finds the copy that answers only to the old key.
struct BurnTarget: Sendable {
    let host: String
    var tokens: [String]
    var keys: [Data]
}

enum BurnFailure: String, Sendable {
    /// Nothing answered, twice (or once, with retries off).
    case offline
    /// The deadline passed while this island was being worked on.
    case timeout
    /// 403: the account is blocked there and the island refuses the delete.
    case suspended
    /// The island has no recover handshake (the challenge 404s), so a copy
    /// without a live token cannot be proven ours and cannot be deleted.
    case tooOld
    /// Any other refusal, including a key the island says was rotated away or
    /// answers for several accounts: something may remain that we cannot
    /// reach with the keys this device holds.
    case server
    /// More copies than the cap: we stopped deleting and some may remain.
    case limit
}

/// What an island CLAIMS happened to our copy. It is the operator's word on
/// every route, so the interface says "island confirmed", never "deleted".
enum IslandBurnResult: Equatable, Sendable {
    case confirmed(Int)
    case alreadyGone
    case failed(BurnFailure)
    case notTried

    /// Nothing left for us to do on that island.
    var isSettled: Bool {
        switch self {
        case .confirmed, .alreadyGone: return true
        case .failed, .notTried: return false
        }
    }
}

enum BurnHTTP: Equatable, Sendable {
    case status(Int)
    case unreachable
}

/// The recover handshake as the burn needs to tell its answers apart.
///
/// ⚠ `Multihome.recoverOn` cannot be used here: it folds "the challenge
/// endpoint does not exist" into a thrown status, and the burn has to tell
/// that (an island too old to prove anything on) from `identity_not_found`
/// (proven absent). Reading the first as the second would report a copy gone
/// that is still there, and then wipe the only key able to delete it.
enum BurnRecover: Equatable, Sendable {
    case account(token: String)
    case notFound
    case rotated
    case ambiguous
    case challengeMissing
    case status(Int)
    case unreachable
}

protocol BurnTransport: Sendable {
    func deleteAccount(host: String, bearer: String) async -> BurnHTTP
    func recover(host: String, signingKey: Data) async -> BurnRecover
}

enum BurnCascadeMachine {
    /// Deletes per island, tokens and recovered rows together. One signing key
    /// can carry several rows on one island (a key registered twice before
    /// recover-first existed); four is more than any real account has, and a
    /// bound is what stops an island that answers 204 and keeps the row from
    /// holding the loop forever.
    static let maxDeletes = 4

    /// Burn one island's copies.
    ///
    /// 1. Every stored token: `DELETE /auth/account`. 2xx counts; 401 and 404
    ///    fall through to the key; 403 is a suspended account.
    /// 2. Every key: recover, delete what recover hands us, recover again,
    ///    until the island says `identity_not_found` for that key. A rotated
    ///    or ambiguous answer moves on to the next key but keeps the island
    ///    from counting as clean.
    /// 3. Settled only when EVERY key ended on `identity_not_found`: one key
    ///    answering "no such identity" says nothing about a copy that answers
    ///    only to another key (spec F2, critic 3).
    ///
    /// One retry per request on no answer or a 5xx, when `retry` is on.
    static func burnOne(_ target: BurnTarget, transport: BurnTransport, retry: Bool) async -> IslandBurnResult {
        var deleted = 0

        func delete(_ bearer: String) async -> BurnHTTP {
            let first = await transport.deleteAccount(host: target.host, bearer: bearer)
            guard retry, needsRetry(first), !Task.isCancelled else { return first }
            return await transport.deleteAccount(host: target.host, bearer: bearer)
        }

        func recover(_ key: Data) async -> BurnRecover {
            let first = await transport.recover(host: target.host, signingKey: key)
            guard retry, needsRetry(first), !Task.isCancelled else { return first }
            return await transport.recover(host: target.host, signingKey: key)
        }

        for token in target.tokens {
            if Task.isCancelled { return .failed(.timeout) }
            if deleted >= maxDeletes { return .failed(.limit) }
            switch await delete(token) {
            case .status(let code) where (200..<300).contains(code):
                deleted += 1
            case .status(401), .status(404):
                continue
            case .status(403):
                return .failed(.suspended)
            case .status:
                return .failed(.server)
            case .unreachable:
                return .failed(Task.isCancelled ? .timeout : .offline)
            }
        }

        var everyKeyNotFound = !target.keys.isEmpty
        keys: for key in target.keys {
            while true {
                if Task.isCancelled { return .failed(.timeout) }
                switch await recover(key) {
                case .notFound:
                    continue keys
                case .rotated, .ambiguous:
                    everyKeyNotFound = false
                    continue keys
                case .challengeMissing:
                    return .failed(.tooOld)
                case .status(403):
                    return .failed(.suspended)
                case .status:
                    return .failed(.server)
                case .unreachable:
                    return .failed(Task.isCancelled ? .timeout : .offline)
                case .account(let token):
                    if deleted >= maxDeletes { return .failed(.limit) }
                    switch await delete(token) {
                    case .status(let code) where (200..<300).contains(code):
                        deleted += 1
                    case .status(403):
                        return .failed(.suspended)
                    case .status:
                        // A token recover minted a moment ago and the delete
                        // still refuses it: going round again would only ask
                        // for the same answer. Stop and say so.
                        return .failed(.server)
                    case .unreachable:
                        return .failed(Task.isCancelled ? .timeout : .offline)
                    }
                }
            }
        }

        guard everyKeyNotFound else { return .failed(.server) }
        return deleted > 0 ? .confirmed(deleted) : .alreadyGone
    }

    /// Burn every target, up to `concurrency` at once, and return by
    /// `deadline` whatever the transport does.
    ///
    /// ⚠ The deadline does not wait for the work to acknowledge cancellation.
    /// A request stuck in a tunnel handshake or a held connection may ignore
    /// it, and a structured task group would sit on its exit until that
    /// request gave up, which is exactly the hang the deadline exists to cut.
    /// So the work runs in its own task, gets cancelled when time is up, and
    /// the answer is read off the board as it stands: an island still being
    /// worked on is `timeout`, one never started is `notTried`.
    static func run(
        _ targets: [BurnTarget],
        deadline: TimeInterval,
        retry: Bool,
        concurrency: Int = 6,
        transport: BurnTransport
    ) async -> [String: IslandBurnResult] {
        guard !targets.isEmpty else { return [:] }
        let board = Board()
        let width = max(1, concurrency)
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for target in targets {
                    if running >= width {
                        await group.next()
                        running -= 1
                    }
                    if Task.isCancelled { break }
                    await board.start(target.host)
                    group.addTask {
                        let result = await burnOne(target, transport: transport, retry: retry)
                        await board.finish(target.host, result)
                    }
                    running += 1
                }
                await group.waitForAll()
            }
        }
        let gate = ResumeOnce()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
            gate.fire()
        }
        let watcher = Task {
            await work.value
            gate.fire()
        }
        // A caller that is cancelled (the burn screen torn down by the lock)
        // gets the board as it stands now, the same as at the deadline, instead
        // of holding the drains down for the rest of the 15 s.
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.fire()
        }
        work.cancel()
        timer.cancel()
        watcher.cancel()
        return await board.results(for: targets.map(\.host))
    }

    private static func needsRetry(_ answer: BurnHTTP) -> Bool {
        switch answer {
        case .unreachable: return true
        case .status(let code): return code >= 500
        }
    }

    private static func needsRetry(_ answer: BurnRecover) -> Bool {
        switch answer {
        case .unreachable: return true
        case .status(let code): return code >= 500
        default: return false
        }
    }

    private actor Board {
        private var started: Set<String> = []
        private var done: [String: IslandBurnResult] = [:]

        func start(_ host: String) { started.insert(host) }

        func finish(_ host: String, _ result: IslandBurnResult) {
            // First answer stands: a late finish after the deadline was read
            // must not change what the caller has already shown.
            if done[host] == nil { done[host] = result }
        }

        func results(for hosts: [String]) -> [String: IslandBurnResult] {
            var out: [String: IslandBurnResult] = [:]
            for host in hosts {
                out[host] = done[host] ?? (started.contains(host) ? .failed(.timeout) : .notTried)
            }
            // Frozen: whatever lands after this read is not reported.
            for (host, result) in out where done[host] == nil { done[host] = result }
            return out
        }
    }

    /// A wait that the first of several callers ends, exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if fired {
                    lock.unlock()
                    c.resume()
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        }

        func fire() {
            lock.lock()
            guard !fired else { lock.unlock(); return }
            fired = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }
}

// MARK: - #988: which catalogue island may take an automatic backup

/// Why an island turned a registration away at its door, read from the
/// `detail.code` of a 403 on `/auth/register` (`app/routers/auth.py`):
/// `entry_required` on a paid island, `invite_required` on an invite-only one,
/// and `invite_invalid` when a code was sent and did not open it.
enum IslandDoorRefusal: String, Equatable, Sendable {
    case entry
    case invite
}

/// What one catalogue island told the backup toggle about itself. Asked fresh
/// on every flip of the toggle, never from a cache (#988).
enum BackupProbe: Equatable, Sendable {
    /// No usable answer: `/health` not 2xx, a redirect, a timeout, a network
    /// or trust failure, or a `/server/info` that could not be read. Nothing
    /// is dialled on a silent island, not even a recover.
    case silent
    /// A stranger may register: add a copy the way every add does (recover
    /// first, then register).
    case open
    /// The door is shut: take back a copy this account already has there, and
    /// never register.
    case shut
}

/// One probe answer as it arrived. Redirects are refused, so a 3xx comes back
/// as itself; nil is no answer at all (timeout, network, trust refusal).
struct BackupProbeAnswer: Equatable, Sendable {
    let status: Int
    let body: Data
}

/// The backup toggle adds a mailbox on an island nobody chose by hand, so the
/// island is asked about its door first, and the door decides what the toggle
/// may do there. The same rule on Android, the web and here.
///
/// ⚠ It used to ask `/health` alone (report #988). The signed catalogue lists
/// the flagship and is2, the flagship's door became paid, and an is2 account
/// flipping the toggle had the flagship picked, dialled and refused with
/// `entry_required`, with the island's JSON printed under the switch.
enum BackupAutoPick {
    /// The most of `/server/info` that is read. A door answer is a few hundred
    /// bytes; a body past this is not an island describing itself.
    static let infoBodyCap = 64 * 1024
    /// The OVERALL deadline of one probe request on the direct route: connect,
    /// headers and body together. Short, because the toggle waits on every
    /// silent island in the catalogue, one after another.
    static let probeDeadlineDirect: TimeInterval = 6
    /// The same over relays, which add a hop and a handshake of their own.
    static let probeDeadlineRelay: TimeInterval = 15

    static func probeDeadline(overRelay: Bool) -> TimeInterval {
        overRelay ? probeDeadlineRelay : probeDeadlineDirect
    }

    /// `op` under an overall deadline: its answer when it finishes in time,
    /// nil when the deadline passes first, and `op` is cancelled then.
    ///
    /// ⚠ Not `URLRequest.timeoutInterval`. That one is an idle timeout, reset
    /// by every byte, so an island trickling its answer a byte at a time
    /// would hold the toggle for as long as it liked (#988).
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ op: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// `/health` answered 2xx, the precondition for asking anything else.
    static func healthy(_ answer: BackupProbeAnswer?) -> Bool {
        guard let answer else { return false }
        return (200..<300).contains(answer.status)
    }

    /// The probe of one island from its two answers.
    static func classify(health: BackupProbeAnswer?, info: BackupProbeAnswer?) -> BackupProbe {
        guard healthy(health),
              let info, (200..<300).contains(info.status),
              info.body.count <= infoBodyCap else { return .silent }
        return door(serverInfo: info.body)
    }

    /// The door as a `/server/info` body states it.
    ///
    /// OPEN when `capabilities.registration_policy` is "open" or absent and
    /// `capabilities.closed_island` is not true. SHUT on any other policy word
    /// (paid, invite, one this build has never heard of), on a true
    /// `closed_island`, and on a field that is present with the wrong type,
    /// JSON null included. Only a field that is missing altogether is absent:
    /// an island older than the field, and those were open. A body that is not
    /// valid UTF-8, not strict JSON, or not an object is SILENT.
    ///
    /// ⚠ Read from the raw JSON on purpose, not from `ServerCapabilities`. That
    /// decoder folds a malformed field into its default ("open", false), which
    /// is right for a person joining an island they chose and wrong here,
    /// where nobody chose it and a field we cannot read is a door we do not
    /// walk through on their behalf.
    ///
    /// ⚠ `entry_price_cents` is not part of the rule. An island may sell
    /// residency while its registration stays open, and the policy is what
    /// `/auth/register` checks.
    static func door(serverInfo body: Data) -> BackupProbe {
        guard let obj = strictObject(body) else { return .silent }
        guard let rawCaps = obj["capabilities"] else { return .open }
        guard let caps = rawCaps as? [String: Any] else { return .shut }
        if let policy = caps["registration_policy"] {
            guard let word = policy as? String, word == "open" else { return .shut }
        }
        if let closed = caps["closed_island"] {
            guard let flag = jsonBool(closed), !flag else { return .shut }
        }
        return .open
    }

    /// A JSON `true`/`false`, and nothing else: `JSONSerialization` hands a
    /// number and a boolean back as the same `NSNumber` type, and `1` is not a
    /// boolean an island meant.
    private static func jsonBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A JSON object read strictly: valid UTF-8 without a byte order mark,
    /// RFC 8259 grammar with nothing looser, and an object at the top.
    /// Nil for anything else.
    ///
    /// ⚠ `JSONSerialization` alone is not strict: it takes a trailing comma, a
    /// UTF-8 byte order mark and a UTF-16 body without a word. `StrictJSON`
    /// checks the grammar first, and `JSONSerialization` only builds the value
    /// from bytes already known to be clean.
    static func strictObject(_ data: Data) -> [String: Any]? {
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: data, encoding: .utf8) != nil,
              StrictJSON.isObjectDocument([UInt8](data)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The door refusal carried by an island's error answer, or nil for
    /// anything else. Exactly an HTTP 403 whose JSON body carries `detail` as
    /// an object with `code` one of `entry_required`, `invite_required`,
    /// `invite_invalid`. A bare-string `detail`, another status, or no status
    /// at all is not a door refusal. Compared exactly, never by substring, the
    /// same rule as `Multihome.authErrorDetail`: a proxy page that merely
    /// contains the word is not an island refusing us.
    static func doorRefusal(status: Int, body: String) -> IslandDoorRefusal? {
        guard status == 403,
              let obj = strictObject(Data(body.utf8)),
              let detail = obj["detail"] as? [String: Any],
              let code = detail["code"] as? String else { return nil }
        switch code {
        case "entry_required": return .entry
        case "invite_required", "invite_invalid": return .invite
        default: return nil
        }
    }

    /// The catalogue in its own order (the order is the project's
    /// preference), minus entries that do not parse, our own island under
    /// any of its names, hosts this account already backs up to, and repeats.
    static func candidates(
        catalogue: [String],
        normalize: (String) -> String?,
        isOwn: (String) -> Bool,
        existing: Set<String>
    ) -> [String] {
        let taken = Set(existing.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for entry in catalogue {
            guard let host = normalize(entry) else { continue }
            let key = host.lowercased()
            guard !isOwn(host), !taken.contains(key), seen.insert(key).inserted else { continue }
            out.append(host)
        }
        return out
    }

    /// How adding a copy on an OPEN island went.
    enum RegisterAttempt: Equatable, Sendable {
        case added
        /// 403 `entry_required` / `invite_required` / `invite_invalid`: the
        /// door shut between the probe and the registration.
        case doorRefused
        case failed
    }

    /// How taking back an existing copy on a SHUT island went.
    enum RecoverAttempt: Equatable, Sendable {
        case adopted
        /// The island has no copy of this account.
        case noCopy
        case failed
    }

    enum Outcome: Equatable, Sendable {
        case added(host: String)
        /// At least one island answered and none of them yielded a backup, or
        /// the verified catalogue had no island left to ask.
        case noOpenIsland
        /// The catalogue could not be fetched or failed verification, or not
        /// one island in it answered, the relay pass included.
        case noIslandReachable
    }

    /// Walk the catalogue's candidates in order, ONE AT A TIME, and stop at
    /// the first island that yields a backup.
    ///
    /// `catalogue` fetches and verifies the signed catalogue and returns the
    /// candidates left after exclusions (`candidates`), or nil when it could
    /// not be fetched or failed verification.
    ///
    /// - SILENT: skipped, nothing dialled.
    /// - OPEN: `register`, whose recover-first step is the island's one
    ///   recover. A door refusal there means no copy and a shut door, and the
    ///   walk moves on without asking the island again.
    /// - SHUT: `recover` only, once. `register` is never called on a shut
    ///   island.
    /// - Any other failure moves on to the next island.
    ///
    /// Each island is dialled at most once per pass, even when the list
    /// repeats it. The relay pass runs once, and only when everything was
    /// SILENT: every island, or the catalogue itself. `openRelay` brings the
    /// relay route up (false when there is none, and then the pass is
    /// skipped); a catalogue that failed is fetched again over it, and the
    /// same walk repeats. A verified catalogue with no candidate left is an
    /// answer, not silence: no relay pass, and the outcome is `noOpenIsland`.
    static func run(
        catalogue: () async -> [String]?,
        probe: (String) async -> BackupProbe,
        openRelay: () async -> Bool,
        register: (String) async -> RegisterAttempt,
        recover: (String) async -> RecoverAttempt
    ) async -> Outcome {
        var list: [String]?
        for relayPass in [false, true] {
            if relayPass {
                guard await openRelay() else { break }
            }
            if list == nil { list = await catalogue() }
            guard let candidates = list else { continue }
            if candidates.isEmpty { return .noOpenIsland }
            var asked = Set<String>()
            var answered = false
            for host in candidates {
                guard asked.insert(host.lowercased()).inserted else { continue }
                switch await probe(host) {
                case .silent:
                    continue
                case .open:
                    answered = true
                    if await register(host) == .added { return .added(host: host) }
                case .shut:
                    answered = true
                    if await recover(host) == .adopted { return .added(host: host) }
                }
            }
            if answered { return .noOpenIsland }
        }
        return .noIslandReachable
    }
}

/// An RFC 8259 grammar check over raw bytes, and nothing looser: no trailing
/// commas, comments, single quotes, bare words, NaN, leading zeros, raw
/// control characters in strings, or anything after the value. The top value
/// must be an object. Nesting deeper than `maxDepth` is refused rather than
/// followed, so a hostile body cannot run the stack out. It builds nothing;
/// `BackupAutoPick.strictObject` builds the value once the bytes pass.
struct StrictJSON {
    static let maxDepth = 128

    private let bytes: [UInt8]
    private var at = 0

    private init(_ bytes: [UInt8]) { self.bytes = bytes }

    static func isObjectDocument(_ bytes: [UInt8]) -> Bool {
        var p = StrictJSON(bytes)
        p.skipSpace()
        guard p.peek == UInt8(ascii: "{"), p.value(depth: 0) else { return false }
        p.skipSpace()
        return p.at == bytes.count
    }

    private var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

    private mutating func eat(_ c: UInt8) -> Bool {
        guard peek == c else { return false }
        at += 1
        return true
    }

    private mutating func skipSpace() {
        while let c = peek, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { at += 1 }
    }

    private mutating func word(_ w: String) -> Bool {
        for c in w.utf8 {
            guard eat(c) else { return false }
        }
        return true
    }

    private mutating func value(depth: Int) -> Bool {
        guard let c = peek else { return false }
        switch c {
        case UInt8(ascii: "{"): return depth < Self.maxDepth && object(depth: depth + 1)
        case UInt8(ascii: "["): return depth < Self.maxDepth && array(depth: depth + 1)
        case UInt8(ascii: "\""): return string()
        case UInt8(ascii: "t"): return word("true")
        case UInt8(ascii: "f"): return word("false")
        case UInt8(ascii: "n"): return word("null")
        default: return number()
        }
    }

    private mutating func object(depth: Int) -> Bool {
        at += 1
        skipSpace()
        if eat(UInt8(ascii: "}")) { return true }
        while true {
            skipSpace()
            guard string() else { return false }
            skipSpace()
            guard eat(UInt8(ascii: ":")) else { return false }
            skipSpace()
            guard value(depth: depth) else { return false }
            skipSpace()
            if eat(UInt8(ascii: "}")) { return true }
            guard eat(UInt8(ascii: ",")) else { return false }
        }
    }

    private mutating func array(depth: Int) -> Bool {
        at += 1
        skipSpace()
        if eat(UInt8(ascii: "]")) { return true }
        while true {
            skipSpace()
            guard value(depth: depth) else { return false }
            skipSpace()
            if eat(UInt8(ascii: "]")) { return true }
            guard eat(UInt8(ascii: ",")) else { return false }
        }
    }

    private mutating func string() -> Bool {
        guard eat(UInt8(ascii: "\"")) else { return false }
        while let c = peek {
            at += 1
            if c == UInt8(ascii: "\"") { return true }
            if c < 0x20 { return false }
            guard c == UInt8(ascii: "\\") else { continue }
            guard let e = peek else { return false }
            at += 1
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
                 UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
                 UInt8(ascii: "r"), UInt8(ascii: "t"):
                break
            case UInt8(ascii: "u"):
                for _ in 0..<4 {
                    guard let h = peek, Self.isHex(h) else { return false }
                    at += 1
                }
            default:
                return false
            }
        }
        return false
    }

    private mutating func number() -> Bool {
        _ = eat(UInt8(ascii: "-"))
        guard let first = peek, Self.isDigit(first) else { return false }
        at += 1
        if first != UInt8(ascii: "0") { _ = digits() }
        if eat(UInt8(ascii: ".")) { guard digits() else { return false } }
        if eat(UInt8(ascii: "e")) || eat(UInt8(ascii: "E")) {
            if !eat(UInt8(ascii: "+")) { _ = eat(UInt8(ascii: "-")) }
            guard digits() else { return false }
        }
        return true
    }

    /// At least one digit consumed.
    private mutating func digits() -> Bool {
        let start = at
        while let d = peek, Self.isDigit(d) { at += 1 }
        return at > start
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isHex(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
}

// MARK: - C-G: guest copies through a paid or invite door (spec 2026-09-15)

/// Which join and add paths an island gets (spec 12.1, `decideGuestPath`). The
/// same table on Android, the web and here.
enum GuestPath: Equatable, Sendable {
    /// Today's paths: recover-first then `/auth/register` for a self-join,
    /// `uin-for-key` -> `/auth/register` -> `/members` for an owner-add.
    case legacy
    /// `POST /auth/guest/challenge` + `POST /auth/guest` for a self-join,
    /// `POST /groups/{id}/guests` for an owner-add.
    case guest

    /// nil (the island did not answer) and anything but true are legacy.
    static func decide(advertised: Bool?) -> GuestPath {
        advertised == true ? .guest : .legacy
    }

    /// From a raw `/server/info` body: `capabilities.guest_accounts_v1` has to
    /// be exactly JSON `true`. No body, a body that is not strict JSON, a
    /// missing field, `"true"`, `1` and `null` are all legacy.
    ///
    /// ⚠ Legacy on every doubt, on purpose. It is what every island older than
    /// the field gets, and on an island that does admit guests it fails the
    /// way it fails today (the door sentence), never by creating anything.
    static func decide(serverInfo body: Data?) -> GuestPath {
        guard let body, body.count <= BackupAutoPick.infoBodyCap,
              let obj = BackupAutoPick.strictObject(body),
              let caps = obj["capabilities"] as? [String: Any],
              let flag = caps["guest_accounts_v1"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID() else { return .legacy }
        return flag.boolValue ? .guest : .legacy
    }
}

/// The signed bytes of an `rcq-guest-v1` proof (spec 4.3), byte for byte the
/// island's `app/services/guest_proof.py`. `Tools/GuestProofCheck` pins them
/// against `fixtures/guest-proof-v1.json`, copied verbatim from rcq-server-ref.
///
/// UTF-8, six fields joined by a single 0x0A, no trailing newline:
///
///     rcq-guest-v1
///     <canonical host>   lowercase, ":port" only when not 443
///     <group id>         decimal ASCII, the room id ON THAT ISLAND
///     <identity key>     standard padded base64 of the 32 X25519 bytes
///     <signing key>      standard padded base64 of the 32 Ed25519 bytes
///     <challenge>        verbatim, as `/auth/guest/challenge` handed it out
///
/// The signature itself is made where the private key lives
/// (`CrossIslandGroups`), with CryptoKit; nothing here holds a key.
enum GuestProof {
    static let prefix = "rcq-guest-v1"
    static let version = 1

    /// `reissue_proof.canonical_host`: trimmed and lowercased, a trailing dot
    /// dropped, the port kept only when it is not 443, brackets around an IPv6
    /// literal kept. The island canonicalises the host it was SENT and checks
    /// the signature over that, so the client has to sign the same spelling.
    static func canonicalHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var port = ""
        if host.hasPrefix("[") {
            if let end = host.firstIndex(of: "]") {
                let after = host.index(after: end)
                if after < host.endIndex, host[after] == ":" {
                    port = String(host[host.index(after: after)...])
                    host = String(host[...end])
                }
            }
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            port = String(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host.removeLast() }
        if !port.isEmpty && port != "443" { return "\(host):\(port)" }
        return host
    }

    /// `reissue_proof.decode_key32`: standard base64 with or without padding,
    /// exactly 32 bytes, nil for anything else (the URL-safe alphabet too).
    static func decodeKey32(_ value: String) -> Data? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ isStandardBase64($0) || $0 == UInt8(ascii: "=") }) else { return nil }
        let rem = raw.utf8.count % 4
        if rem != 0 { raw += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: raw), data.count == 32 else { return nil }
        return data
    }

    /// The spelling that is signed: standard padded base64.
    static func canonicalKey(_ raw: Data) -> String { raw.base64EncodedString() }

    /// The proof bytes, or nil for input that cannot be one line of the
    /// layout: a room id that is not positive, a key that is not 32 bytes, an
    /// empty host or challenge, or either carrying a line break (a field with
    /// one inside would shift every field after it).
    ///
    /// ⚠ Line breaks are looked for in the UTF-8 BYTES. In Swift `"\r\n"` is
    /// one Character, so `String.contains("\n")` answers false for it.
    static func proofBytes(
        host: String,
        groupId: Int,
        identityKey: Data,
        signingKey: Data,
        challenge: String
    ) -> Data? {
        guard groupId > 0, identityKey.count == 32, signingKey.count == 32 else { return nil }
        let hostLine = canonicalHost(host)
        guard !hostLine.isEmpty, !hasLineBreak(hostLine),
              !challenge.isEmpty, !hasLineBreak(challenge) else { return nil }
        let lines = [
            prefix,
            hostLine,
            String(groupId),
            canonicalKey(identityKey),
            canonicalKey(signingKey),
            challenge,
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The JSON body of `POST /auth/guest` (spec 4.2). `host` goes as dialled:
    /// the island canonicalises it and checks it against its own names. No
    /// `device_id`, like the recover this path replaces, and nothing about the
    /// home island: the proof carries this island's host, never ours.
    static func requestBody(
        host: String,
        groupId: Int,
        nickname: String,
        identityKey: Data,
        signingKey: Data,
        challenge: String,
        signature: Data
    ) -> [String: Any] {
        [
            "v": version,
            "host": host,
            "group_id": groupId,
            "nickname": nickname,
            "identity_key": canonicalKey(identityKey),
            "signing_key": canonicalKey(signingKey),
            "challenge": challenge,
            "signature": signature.base64EncodedString(),
        ]
    }

    private static func hasLineBreak(_ s: String) -> Bool {
        s.utf8.contains(0x0A) || s.utf8.contains(0x0D)
    }

    private static func isStandardBase64(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
            || c == UInt8(ascii: "+") || c == UInt8(ascii: "/")
    }
}

/// The body of the LEGACY self-join registration, on an island that does not
/// advertise `guest_accounts_v1`. Two differences from what this client sent
/// before (spec 12.1): the register challenge and its signature go along when
/// the island handed out a challenge, and there is never a `desired_uin`, so a
/// copy is not parked on our home number.
enum LegacyGuestRegister {
    static func body(
        nickname: String,
        identityKey: String,
        signingKey: String,
        challenge: String?,
        signature: String?
    ) -> [String: String] {
        var out = [
            "nickname": nickname,
            "identity_key": identityKey,
            "signing_key": signingKey,
        ]
        if let challenge, let signature, !challenge.isEmpty, !signature.isEmpty {
            out["challenge"] = challenge
            out["signature"] = signature
        }
        return out
    }
}

/// An island's refusal as the guest paths read it: the status and
/// `detail.code`, plus `detail.scope` for `guest_add_limit`. Parsed exactly,
/// never by substring (spec 12.1, "Errors"): a proxy page that contains a code
/// word is not the island saying it.
struct IslandRefusal: Equatable, Sendable {
    let status: Int
    let code: String?
    let scope: String?

    init(status: Int, code: String?, scope: String? = nil) {
        self.status = status
        self.code = code
        self.scope = scope
    }

    /// A dependency limiter answers `{"detail": {"code": "rate_limited", ...}}`
    /// too, so one reader covers every refusal on these routes.
    ///
    /// A bare-string `detail` counts as a code only when it is spelled like
    /// one (`island_busy`, the pool-exhaustion answer of every route). FastAPI's
    /// own "Not Found" and the English prose of `add_member` are not codes:
    /// reading them as one would turn "this island has no such route" into a
    /// refusal and skip the legacy fallback.
    static func parse(status: Int, body: Data) -> IslandRefusal {
        guard body.count <= BackupAutoPick.infoBodyCap,
              let obj = BackupAutoPick.strictObject(body) else {
            return IslandRefusal(status: status, code: nil)
        }
        if let bare = obj["detail"] as? String {
            return IslandRefusal(status: status, code: looksLikeCode(bare) ? bare : nil)
        }
        guard let detail = obj["detail"] as? [String: Any] else {
            return IslandRefusal(status: status, code: nil)
        }
        return IslandRefusal(status: status, code: detail["code"] as? String, scope: detail["scope"] as? String)
    }

    /// `[a-z][a-z0-9_]*`, at most 64 bytes.
    static func looksLikeCode(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard let first = u.first, u.count <= 64, first >= 0x61, first <= 0x7A else { return false }
        return u.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }
}

/// What the self-join does after one answer from `POST /auth/guest` (or its
/// challenge), in the order of spec 12.1.
enum GuestJoinStep: Equatable, Sendable {
    /// Ask for a fresh challenge and try once more.
    case retryWithFreshChallenge
    /// The key was retired by a signed key change elsewhere: the
    /// rotated-elsewhere sentence, and NEVER a wipe (C0, P0.2).
    case rotated
    /// The island does not have the route after all (404 or 405 without a
    /// code): take the legacy path.
    case legacy
    /// No answer, or a 5xx: one recover-first attempt, and its credentials if
    /// it returns any.
    case recoverFallback
    /// Terminal. The code picks the sentence (`GuestSentence.join`).
    case refused(IslandRefusal)

    static let retryableCodes: Set<String> = ["invalid_challenge", "guest_replayed", "guest_busy"]

    /// `refusal` nil means nothing answered at all. `retried` is true once the
    /// one fresh-challenge retry has been spent.
    static func after(_ refusal: IslandRefusal?, retried: Bool) -> GuestJoinStep {
        guard let refusal else { return .recoverFallback }
        if let code = refusal.code {
            if code == "identity_rotated" { return .rotated }
            if retryableCodes.contains(code) { return retried ? .refused(refusal) : .retryWithFreshChallenge }
            if refusal.status >= 500 { return .recoverFallback }
            return .refused(refusal)
        }
        if refusal.status == 404 || refusal.status == 405 { return .legacy }
        if refusal.status >= 500 || refusal.status == 0 { return .recoverFallback }
        return .refused(refusal)
    }
}

/// Localisation keys for the refusals of spec 11, mapped as in 12.5. The same
/// table on Android (`GuestPath.joinSentence` / `addSentence`) and the web
/// (`guestJoinErrorKey` / `groupAddErrorKey`). Every key takes the island host
/// as its only `%@` where it names one; formatting a key without one with the
/// host is harmless. Nil means "no specific sentence": the caller shows its
/// generic one (`joinGeneric`, `addGeneric`), never the island's own text.
enum GuestSentence {
    /// The line for a join that failed with no code this table knows.
    static let joinGeneric = "group_join.error.generic"
    /// The line for an add that failed with no code this table knows.
    static let addGeneric = "group.add.error.forbidden"

    /// Codes that only mean "the island cannot mint right now": a spent or
    /// stale challenge after the one silent retry, the create lock held, the
    /// island ceiling in front of the mint, and Redis being down.
    static let unavailableCodes: Set<String> = [
        "invalid_challenge", "guest_replayed", "guest_busy", "island_busy", "guest_unavailable",
    ]

    /// A self-join: `/auth/guest`, the `/groups/{id}/join` right after it, or
    /// the legacy registration's door.
    static func join(_ refusal: IslandRefusal) -> String? {
        if let code = refusal.code, unavailableCodes.contains(code) { return "guest.unavailable" }
        switch refusal.code {
        case "guest_closed": return "guest.join.closed"
        // `allow_guests` off on this room.
        case "guest_room_closed": return "guest.join.room_closed"
        // The room member ceiling.
        case "guest_room_full": return "guest.join.room_full"
        case "guest_room_limit": return "guest.join.room_limit"
        case "rate_limited": return "guest.join.rate"
        case "guest_group_limit": return "guest.join.group_limit"
        case "guest_restricted": return "guest.restricted"
        // The legacy path on an island whose door is shut and whose server
        // cannot take guests yet.
        case "entry_required": return "guest.join.old_paid"
        case "invite_required", "invite_invalid": return "guest.join.old_invite"
        // The existing code and meaning: a closed room needs an add.
        case "group_closed": return "group_join.closed_hint"
        case "blocked": return "group_join.error.blocked"
        // The room is gone. `/auth/guest` answers it for a room id that names
        // nothing on that island, and so does the room's own self-join. The
        // web said so from the start and Android named it later; without it
        // one refusal read as "couldn't join" here and "this group is gone"
        // there, for the same answer (E2, one table on every client).
        case "group_not_found": return "group_join.gone"
        // A self-join mints no seat, so in practice only the owner-add route
        // answers this. Mapped all the same, so the three tables match one for
        // one and a code cannot fall through to the generic line on one client
        // and be named on another.
        case "guest_key_retired": return "group.add.foreign.stale_key"
        case "target_guest": return "group.transfer.err.target_guest"
        // ⚠ NO sentence, on purpose (F2, 16.09). The key was retired by a
        // signed key change made on another device, and that answer opens the
        // account's rotated-elsewhere notice, which says the whole thing. A
        // second sentence beside the notice tells one refusal twice, and the
        // generic "couldn't join" is worse than that: it reads as something a
        // retry could fix. Callers ask `noticeOnly` and show nothing at all.
        // Android stops at the same place (`Session.joinFailureSentence`
        // returns null for `Sentence.ROTATED`) and the web returns before it
        // sets an error.
        case "identity_rotated": return nil
        default: break
        }
        // A limiter that answered in its own shape is still the same wait.
        if refusal.status == 429 { return "guest.join.rate" }
        return nil
    }

    /// A refusal that a notice elsewhere on screen already speaks for: show
    /// NOTHING beside it, not the mapped sentence and not the generic line
    /// (F2, 16.09). Only `identity_rotated` is one, because only it opens a
    /// screen of its own (the rotated-elsewhere notice, P0.2).
    ///
    /// ⚠ Asked BEFORE the tables below, by every caller that prints a
    /// sentence: `join` returning nil for this code would otherwise fall
    /// through to the caller's generic line, which is the second sentence this
    /// rule exists to keep off the screen.
    static func noticeOnly(_ refusal: IslandRefusal) -> Bool {
        refusal.code == "identity_rotated"
    }

    /// An owner-add: `POST /groups/{id}/guests`, or the legacy `/members`
    /// after `uin-for-key` / `/auth/register`. `prose` is the body of a
    /// refusal that carried no code: a native `add_member` still answers in
    /// three English sentences, and only a substring can read those.
    static func add(_ refusal: IslandRefusal, prose: String? = nil) -> String? {
        switch refusal.code {
        case "guest_restricted": return "group.add.foreign.guest_adder"
        case "guest_room_closed": return "guest.join.room_closed"
        case "guest_closed": return "guest.join.closed"
        case "guest_room_full": return "guest.join.room_full"
        case "guest_room_limit": return "guest.join.room_limit"
        case "guest_group_limit": return "guest.join.group_limit"
        case "guest_add_limit": return refusal.scope == "seat" ? "group.add.foreign.seat_limit" : "group.add.foreign.limit"
        case "guest_key_retired": return "group.add.foreign.stale_key"
        // "Not right now", whichever part of the island said it: the mint is
        // busy, the island ceiling sits in front of it, or a challenge went
        // stale. The last two reach an add through the copy's own token
        // re-mint, and the web names them here too (E2).
        case "guest_busy", "island_busy", "guest_unavailable", "invalid_challenge", "guest_replayed":
            return "guest.unavailable"
        case "target_guest": return "group.transfer.err.target_guest"
        case "rate_limited": return "guest.join.rate"
        case "blocked": return "group.add.error.blocked"
        case "invite_contacts_only": return "group.add.error.contacts_only"
        case "invite_nobody": return "group.add.error.nobody"
        default: break
        }
        let m = (prose ?? "").lowercased()
        if m.contains("the group owner has blocked this user") { return "group.add.error.blocked" }
        if m.contains("only accepts group invites from their contacts") { return "group.add.error.contacts_only" }
        if m.contains("does not accept group invites") { return "group.add.error.nobody" }
        // The island has no row for that number at all. Android says so
        // (`GuestPath` NO_USER) and the web says so, and without this row the
        // same refusal read "couldn't add this user" here and "this island does
        // not know them" there (E2, one table on every client). The sentence is
        // the one the transfer screen already ships in every locale.
        if m.contains("no such user") { return "group.transfer.err.no_such_user" }
        if refusal.status == 429 { return "guest.join.rate" }
        return nil
    }

    /// `POST /groups/{id}/transfer-owner`: the codes this spec added. The
    /// older codes keep `GroupService.TransferOwnerError`.
    static func transfer(_ refusal: IslandRefusal) -> String? {
        refusal.code == "target_guest" ? "group.transfer.err.target_guest" : nil
    }

    /// `POST /contacts/respond` refused on a guest copy (spec 10, F1).
    static func respond(_ refusal: IslandRefusal) -> String? {
        refusal.code == "guest_restricted" ? "guest.restricted.contacts" : nil
    }
}

/// The name a guest copy or an owner-added seat is created under (decision D1).
///
/// ⚠⚠ Never the home number. `user-<uin>` is the fallback name other paths
/// use, and the uin in it is the person's number on their HOME island: the one
/// thing a guest copy exists not to tell the island it lives on. The island
/// requires a name (1..64 on `/auth/guest`, `/auth/register` and
/// `/groups/{id}/guests`), so a missing one becomes a neutral word.
enum GuestNickname {
    static let neutral = "Guest"

    /// The name to send, or `neutral` when there is none or it carries one of
    /// `homeUins` as a run of digits of its own (`user-12345`, `12345`, and a
    /// recovered account whose name fell back to its number).
    static func wire(_ nickname: String?, homeUins: [Int]) -> String {
        guard let real = usable(nickname, homeUins: homeUins) else { return neutral }
        return real
    }

    /// The name itself when it may reach another island, nil when it may not.
    /// A rename of the copies uses this: no name is better than `Guest` there.
    static func usable(_ nickname: String?, homeUins: [Int]) -> String? {
        let trimmed = (nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clamped = String(trimmed.prefix(64))
        let runs = digitRuns(clamped)
        for uin in homeUins where uin > 0 && runs.contains(String(uin)) { return nil }
        return clamped
    }

    private static func digitRuns(_ s: String) -> Set<String> {
        var out = Set<String>()
        var cur = ""
        for u in s.unicodeScalars {
            if u.value >= 0x30 && u.value <= 0x39 {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty {
                out.insert(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.insert(cur) }
        // A zero-padded spelling of the number is the number.
        return Set(out.map { run in
            let stripped = run.drop { $0 == "0" }
            return stripped.isEmpty ? "0" : String(stripped)
        })
    }
}

/// Owner-add rules that need no network (spec 12.1, "Owner-add").
enum GuestAddRule {
    /// The contact's card, fetched again from their home just before the add,
    /// names keys other than the ones pinned here: stop, the card we would put
    /// in the room is stale. Compared as decoded bytes, so the padded and the
    /// unpadded spelling of one key are the same key. A card key that does not
    /// decode is a different key.
    static func cardIsStale(
        pinnedIdentityKey: String,
        pinnedSigningKey: String,
        cardIdentityKey: String,
        cardSigningKey: String
    ) -> Bool {
        !sameKey(pinnedIdentityKey, cardIdentityKey) || !sameKey(pinnedSigningKey, cardSigningKey)
    }

    private static func sameKey(_ a: String, _ b: String) -> Bool {
        if let x = GuestProof.decodeKey32(a), let y = GuestProof.decodeKey32(b) { return x == y }
        return a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Spec 7: what a frame that arrived as part of a ROOM (a `group_id` on the
/// queue row, the socket packet or the room log) may carry. Its content renders
/// only in that room's thread, and the kinds below, which only mean something
/// between two people, are dropped and acked without being acted on.
///
/// ⚠ Why the island cannot do this for us: `/messages/group-sealed` takes any
/// subset of members and never checks the sender, so a member can put a
/// payload in front of exactly one other member and the island stores and
/// wakes it like a room post. A guest copy exists to take part in rooms, and
/// this is the rule that keeps a room from being used as a 1:1 channel to it.
///
/// The list is the same on Android (`GroupFrameRule.oneToOneOnly`) and the web.
/// Every kind in it travels 1:1 on this client (`/messages/sealed` to one uin,
/// never `/messages/group-sealed`), which is why dropping it inside a room
/// frame costs the room nothing:
/// * `gskey` / `gsknack`: `MessageService.sendRoomKey` / `sendRoomKeyAsk`,
///   sealed to one member under the `skdm` / `sknack` outer types. Sender keys
///   proper (`skdm`, `sknack`) DO ride group-sealed and are not in this list.
/// * `pkey` / `pkeyask`: `ProfileKeyService`, to one contact.
/// * `carbon` (and the `readmark` and `ciack` inside one): to our own uin.
/// * `secscreen` / `shot`: per-chat toggles, `sendEnvelope` to one contact.
/// * `homerec`: `pushHomeRecordToContacts`, to each contact.
/// * `contactreq`, `call`, `profile`, `visit`: cross-island 1:1 deposits.
enum GroupFrameRule {
    /// Inner `kind` names as this client's `Envelope` encodes them, and ⚠ the
    /// WIRE is what they are read from, never the prose of the spec: the
    /// screenshot notice travels as `shot` (the `screenshotTaken` case encodes
    /// and decodes exactly that), and the secure-screen notice as `secscreen`.
    /// A list naming `screenshot` would compile, pass a table test and drop
    /// nothing at all. `Tools/GuestProofCheck` pins every name here against
    /// the encoder and the decoder in `CryptoService.swift` and against the
    /// ingest switch in `MessageService.swift` (E3, 16.09).
    static let oneToOneOnlyKinds: Set<String> = [
        "contactreq", "ciack", "pkey", "pkeyask", "profile", "visit", "call", "carbon",
        "readmark", "homerec", "gskey", "gsknack", "secscreen", "shot",
    ]

    static func dropsInGroupFrame(kind: String) -> Bool { oneToOneOnlyKinds.contains(kind) }
}

// MARK: - what the screens may offer (decisions D5, D6, D8)

/// One roster row, as the guest rules read it. The island sends both flags on
/// every member (spec 2.3): `guest` for a proven copy AND for an unclaimed
/// seat, `invited` for the seat alone.
struct RosterMemberFlags: Equatable, Sendable {
    let uin: Int
    let guest: Bool
    let invited: Bool

    init(uin: Int, guest: Bool, invited: Bool) {
        self.uin = uin
        self.guest = guest
        self.invited = invited
    }

    /// Not a person who lives on this room's island: a copy, or a seat nobody
    /// has opened yet.
    var isCopy: Bool { guest || invited }
}

/// What a member row from another island may offer (spec 12.1 "Rosters",
/// decision D5). The same table on Android and the web.
///
/// ⚠ The point is not politeness. A copy has no 1:1 anything on this island:
/// a message to it is dropped, a call to it ends as `unavailable` (spec 6.3),
/// and a visit ping would tally a view on a mailbox. The one thing that DOES
/// reach the person is a contact request addressed to the copy, which their
/// home client picks up through C1 pending polling, so that is the one action
/// left standing. An unclaimed seat has nobody behind it at all yet, so it
/// does not even get that.
enum GuestRosterRule {
    /// The line under the name, or nil for a member who lives here.
    static func label(guest: Bool, invited: Bool) -> String? {
        if invited { return "group.member.invited" }
        if guest { return "group.member.guest" }
        return nil
    }

    static func canMessage(guest: Bool, invited: Bool) -> Bool { !(guest || invited) }
    static func canCall(guest: Bool, invited: Bool) -> Bool { !(guest || invited) }
    static func sendsVisitPing(guest: Bool, invited: Bool) -> Bool { !(guest || invited) }

    /// Every other action a profile opened from a room offers (open the chat,
    /// reset the session, block, report) acts on this number ON THIS ISLAND,
    /// which for a copy is a room mailbox and not the person.
    static func hasProfileActions(guest: Bool, invited: Bool) -> Bool { !(guest || invited) }

    /// The one surviving action. False only for an unclaimed seat: there is no
    /// device holding that key, so the request would sit unread until the seat
    /// expires.
    static func canAdd(guest: Bool, invited: Bool) -> Bool { !invited }
}

/// The app's own session is a guest copy (spec 12.1 "Copy signed in as an
/// account", decision D6): which surfaces are not drawn, and whether a push
/// token is handed over.
enum GuestPrimaryRule {
    /// Named rather than scattered so the three clients hide the same list and
    /// a reviewer can read it in one place.
    static let hiddenSurfaces: Set<String> = [
        "contact_search", "add_contact", "calls", "random", "audio_rooms",
        "uin_shop", "invites", "sites", "create_group",
    ]

    static func hides(_ surface: String, guestCopy: Bool) -> Bool {
        guestCopy && hiddenSurfaces.contains(surface)
    }

    /// A guest mailbox never wakes a phone (spec 6.2), so no token is sent.
    static func registersPush(guestCopy: Bool) -> Bool { !guestCopy }

    /// Re-checked on every boot, recover and refresh. ⚠ Nil is "the island did
    /// not say", which every island older than the field answers, and it keeps
    /// what was known instead of quietly promoting a copy to a native account.
    static func next(current: Bool, answered: Bool?) -> Bool { answered ?? current }
}

/// Spec 8.1 read from the roster (decision D8): the island DELETES a room the
/// moment no member who lives on it remains, so the warning has to be shown
/// before the leave, not after.
enum LastResidentRule {
    /// What this roster can say about a leave (decision E4, 16.09).
    enum LeaveCheck: Equatable, Sendable {
        /// Somebody who lives on the room's island stays behind, or the leaver
        /// is a copy and strands nobody.
        case safe
        /// The room would be left with no resident, and the island deletes it.
        case warn
        /// This roster cannot answer: it is empty, it is only a PAGE of a
        /// bigger one, or the leaver is not in it. Fetch once and ask again.
        case needRoster
    }

    /// The question asked of a roster that may not be whole, in the order
    /// Android asks it (`GuestPath.leaveCheck`): the evidence that clears a
    /// leave first, and only then how much of the roster is actually here.
    ///
    /// `memberCount` is the size the island declared, which is larger than
    /// `members` for a room over a hundred people, where the island sends the
    /// compact form.
    ///
    /// ⚠ A page that shows only copies is `needRoster`, NEVER `safe`: it says
    /// nothing about the members it does not show, and a room that big is
    /// exactly where a silent leave costs the most. After the one fetch the
    /// caller warns on anything that is still not `safe`.
    static func leaveCheck(members: [RosterMemberFlags], leaver: Int, memberCount: Int) -> LeaveCheck {
        let me = members.first { $0.uin == leaver }
        // A copy leaving strands nobody: the island deletes the room when the
        // last RESIDENT goes, and that is not us.
        if let me, me.isCopy { return .safe }
        let others = members.filter { $0.uin != leaver }
        // One visible member who lives on the room's island settles it, however
        // much of the roster is missing.
        if others.contains(where: { !$0.isCopy }) { return .safe }
        // Not in the roster we hold, or holding a page of it: it cannot answer.
        if me == nil || members.isEmpty || memberCount > members.count { return .needRoster }
        // Alone in the room: nothing is taken from anybody.
        if others.isEmpty { return .safe }
        return .warn
    }

    /// `members` is the roster as fetched, the leaver included; `leaver` is our
    /// own number IN THAT ROOM (the copy's number on a foreign island).
    ///
    /// ⚠ False on an empty or unfetched roster, and false when the leaver is
    /// itself a copy: a guest leaving strands nobody, and a warning nobody can
    /// act on is worse than none.
    static func lastResident(members: [RosterMemberFlags], leaver: Int) -> Bool {
        guard members.contains(where: { $0.uin == leaver && !$0.isCopy }) else { return false }
        let others = members.filter { $0.uin != leaver }
        guard !others.isEmpty else { return false }
        return others.allSatisfy { $0.isCopy }
    }
}

/// `POST /auth/guest/settle` (spec 9.1, decision D7). The door codes reuse the
/// sentences the join sheet already has, because they are the same door: an
/// island that sells entry says so the same way whether somebody is knocking
/// from outside or settling a copy that is already inside.
extension GuestSentence {
    /// The line for a settle that failed with no code this table knows.
    static let settleGeneric = "residency.error"

    /// ⚠ A refusal that is really a SUCCESS (decision E2, 16.09). The island
    /// answers `not_a_guest` when the row is native already, which means the
    /// settle happened somewhere else: another device did it, or the operator
    /// did. Android (`Sentence.SETTLED`) and the web both run their success
    /// path for that code, clear the local guest flag and say "you now live on
    /// %@"; a sheet that painted it red instead told somebody their settle had
    /// failed and left every guest surface wrong.
    ///
    /// Asked BEFORE `settle(_:)`, which keeps a sentence for the code only for
    /// a caller that has no success path of its own.
    static func settleAlreadyDone(_ refusal: IslandRefusal) -> Bool {
        refusal.code == "not_a_guest"
    }

    static func settle(_ refusal: IslandRefusal) -> String? {
        switch refusal.code {
        // Spent before anything was consumed: the code is still good, it is
        // just a code that carries a number, and this row already has one.
        case "invite_has_number": return "guest.settle.number_invite"
        case "entry_required": return "reg.entry.required"
        case "invite_required": return "reg.invite.required"
        case "invite_invalid", "voucher_other_island", "voucher_expired", "bad_signature":
            return "reg.invite.invalid"
        case "voucher_spent": return "residency.code_spent"
        // The row is native already: somebody settled it on another device.
        // ⚠ The settle sheet never reaches this row: `settleAlreadyDone` reads
        // the code first and finishes the settle as a success (E2). It stays
        // here as the sentence for a caller that only prints one.
        case "not_a_guest": return "residency.already"
        case "guest_unavailable", "island_busy", "guest_busy": return "guest.unavailable"
        case "rate_limited": return "guest.join.rate"
        case "guest_restricted": return "guest.restricted"
        default: break
        }
        if refusal.status == 429 { return "guest.join.rate" }
        return nil
    }
}

// MARK: - #1024: the cross-island half of the visible roster

/// The part of a roster row the rules below need: its number, and the island it
/// lives on with `nil` meaning our own.
///
/// ⚠ A protocol rather than `Contact` so this file stays Foundation only (see
/// the header). `Contact` carries presence, unread counts, a picture and a dozen
/// island-served flags, none of which any rule here looks at; it conforms in
/// `ContactService`.
protocol RosterRow {
    var uin: Int { get }
    var host: String? { get }
}

/// How the cross-island half of the visible roster is made equal to
/// `CrossIslandStore`. Android's `CrossIslandRoster.fold`, same rule.
///
/// ⚠⚠ Report #1024, and the point is that it is a SYNC and not a merge: it adds
/// the store's rows the list is missing AND drops the list's foreign rows the
/// store no longer has. Appending was enough only while it ran after every full
/// roster body, because the body overwrote the list and a dropped store row
/// simply never came back. The roster is read with a conditional GET now, a 304
/// returns from `ContactService.refreshNow` before the fold at the end of it
/// (it has to: re-folding the kept rows repainted presence the websocket had
/// just painted, report #909), and nothing cross-island moves our island's
/// ETag. So a 304 is the permanent answer for such an account, and both
/// directions have to run in that branch or the list only ever changes at an
/// account switch, which is the one thing that clears the ETag.
///
/// ⚠ `host` is the whole of what makes a row ours to manage here. It is
/// local-only, never served by an island, and the one place that sets it is the
/// mapper over `CrossIslandStore`. A row with a nil host belongs to the island
/// and survives untouched, including a same-numbered contact of our own.
enum CrossIslandRoster {

    /// `current` with its cross-island rows made equal to `store`, or nil when
    /// that would change nothing.
    ///
    /// Nil rather than the same array on purpose: `contacts` is `@Published`, an
    /// array is a value, and there is no identity to compare afterwards — so the
    /// "nothing moved" answer has to come from here or every presence frame
    /// wakes every view that reads the roster.
    ///
    /// ⚠ ORDER. Rows already on screen keep their places and genuinely new ones
    /// go on the end, which is the one deliberate difference from Android.
    /// There, `CrossIslandStore.list()` is sorted by `addedAt` and the fold can
    /// simply take the store's order; here `all()` is a dictionary's `values`
    /// and has no order to inherit, so taking it would let the foreign half of
    /// somebody's chat list reshuffle itself on a rehash. Keeping screen order
    /// also makes the fold idempotent, which is what lets the 304 branch run it
    /// on every frame.
    ///
    /// ⚠ A store row whose number a same-island contact already holds is
    /// skipped, exactly as the old merge did: one number is one thread in the
    /// message store, so two rows for it would share one history.
    static func fold<Row: RosterRow & Equatable>(_ current: [Row], store: [Row]) -> [Row]? {
        let local = current.filter { $0.host == nil }
        let localUINs = Set(local.map { $0.uin })
        var held = Set<String>()
        for row in store {
            if localUINs.contains(row.uin) { continue }
            held.insert(key(row))
        }
        // The list's own foreign rows the store still has, in the order they are
        // already drawn in. The row on screen is kept rather than the store's
        // copy: the displayed fields have their own refresh path and a row
        // already in front of somebody must not be rebuilt for no reason.
        var kept: [Row] = []
        var seen = Set<String>()
        for row in current where row.host != nil {
            let k = key(row)
            guard held.contains(k), !seen.contains(k) else { continue }
            seen.insert(k)
            kept.append(row)
        }
        var added: [Row] = []
        for row in store where !localUINs.contains(row.uin) {
            let k = key(row)
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            added.append(row)
        }
        let next = local + kept + added
        return next == current ? nil : next
    }

    /// `uin@host`, lowercased, because a uin alone does not name a person: two
    /// islands can both have a #5 and they are two people.
    private static func key<Row: RosterRow>(_ row: Row) -> String {
        "\(row.uin)@\((row.host ?? "").lowercased())"
    }
}

// MARK: - #1024 / #433 / #429: which island a number means

/// Which island a number means, when a screen is about to resolve a person by
/// it. Android's `PeerIsland`, same source order.
///
/// ⚠⚠ A uin alone does not name a person. Islands number independently, so #134
/// is a different account on every one of them, and getting this wrong is
/// silent: an island answers for the number IT holds, so the wrong island does
/// not fail, it confidently describes somebody else and then gets told we
/// looked at their profile.
enum PeerIsland {

    /// The island a peer's card must be read from, or nil for our own.
    ///
    /// `callerHost` is the island the caller knows the number means, for callers
    /// that know: a room's host, for a member tapped inside that room. Nil means
    /// the caller did not say, which is the 1:1 case, since a thread is opened
    /// by number alone (`UserInfoView.host`, "nil for everything opened from
    /// home").
    ///
    /// `rosterMatched` and `rosterHost` describe the visible roster's row for
    /// this number, if the screen matched one; `rosterHost` is nil for a row on
    /// our own island. `storeHost` is what `CrossIslandStore` holds for the
    /// number, nil when it holds nothing.
    ///
    /// The order is the point:
    ///
    ///  - `callerHost` naming our own island is the caller saying "the local
    ///    one", and it must NOT fall back to anything. That is report #433 (the
    ///    row said is2, the card showed the api account) and #429.
    ///  - A caller naming a foreign island is believed next, since it knows
    ///    something the roster may not hold at all: a room member who is not a
    ///    contact has no row anywhere.
    ///  - Then the roster, which is authoritative once it HAS a row. A matched
    ///    same-island row answers "our island" and is not second-guessed.
    ///  - Only then the store, and this is the line #1024 needed: a
    ///    cross-island contact can exist in the store while the visible roster
    ///    has not folded it in yet (an accept that arrived from another device,
    ///    a roster still answering 304). Without it the 1:1 card resolved such a
    ///    person on OUR island, drew whoever holds that number there, and sent
    ///    them a sealed visit ping for good measure.
    static func cardHost(
        callerHost: String?,
        ourIsland: String?,
        rosterMatched: Bool,
        rosterHost: String?,
        storeHost: String?
    ) -> String? {
        if let callerHost {
            // "Our own island" is an answer, not a missing one.
            if let ourIsland, callerHost.lowercased() == ourIsland.lowercased() { return nil }
            return rosterHost ?? callerHost
        }
        if rosterMatched { return rosterHost }
        // ⚠ A store host equal to our own island still resolves to nil: the
        // question this answers is "somewhere else, and where", and saying
        // "elsewhere" about our own island would send a local card down the
        // cross-island path.
        if let storeHost, let ourIsland, storeHost.lowercased() == ourIsland.lowercased() { return nil }
        return storeHost
    }
}

// MARK: - D6: what a reply can say about our own row being a guest copy

/// The guest flag as an island's reply carries it (spec 2026-09-15, 12.1, "Copy
/// signed in as an account").
///
/// ⚠⚠ Worth a rule of its own because of what the flag DOES rather than what it
/// is: a true stops this device registering a push endpoint at all
/// (`NotificationService.submitTokenIfNeeded`), so a false positive silences an
/// ordinary account's notifications completely, with no error on either side.
/// That was the first hypothesis for the push reports the day after 0.196
/// shipped the gate.
///
/// ⚠⚠ ABSENT MEANS NOT A GUEST, and this is the direction the three clients now
/// share (Android `Session.notePrimaryGuest` + `GuestFlagWireTest`, web
/// `guest-copy.ts`). iOS used to read absent as "no news" and leave a stored
/// true in place, which is the one way a false positive was reachable: one
/// flagged row plus an island rolled back to a build without the field (is2 sat
/// on 2026.09.04.11 for days) silenced push for that account permanently and
/// invisibly. An island that HAS the feature always sends the key — the server
/// fills it explicitly false on `/auth/register`, `/auth/recover`,
/// `/auth/refresh` and the self view — so the only reply that omits it is one
/// from an island where no guest row can exist at all.
///
/// The cost of this direction is the opposite mistake, and it is the cheap one:
/// a real copy on an island that got rolled back is briefly treated as native,
/// so it sees surfaces the island then refuses and offers a push token the
/// island then rejects. Both say so out loud, and the next reply fixes them.
enum GuestFlag {
    /// The one shape every reply that can carry the flag shares. Decoding a
    /// whole reply here is what pins the rule at the wire and not one layer
    /// above it: an absent key, an explicit null and a wrong-typed value all
    /// have to land on "not a guest", and only `true` may set it.
    struct Wire: Decodable {
        var guest: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.guest = try? c.decode(Bool.self, forKey: .guest)
        }

        enum CodingKeys: String, CodingKey { case guest }
    }

    /// What an island said about our own row, resolved.
    static func isGuest(wire: Bool?) -> Bool { wire ?? false }

    /// The same question asked of the reply bytes.
    static func isGuest(json: Data) -> Bool {
        isGuest(wire: (try? JSONDecoder().decode(Wire.self, from: json))?.guest)
    }
}
