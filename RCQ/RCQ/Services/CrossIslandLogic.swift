import Foundation

// Pure rules behind two cross-island features (spec 2026-09-15): the poll of
// pending contact requests on visited islands (F1) and the burn cascade over
// this account's copies on other islands (F2).
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
