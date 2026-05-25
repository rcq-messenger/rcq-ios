import Combine
import Foundation
import os.log

/// Crash game live state. Subscribes to WebSocketService directly. Server
/// runs the BETTING → RUNNING → CRASHED loop; this client mirrors phase
/// transitions and animates the multiplier between events.
@MainActor
final class CrashService: ObservableObject {
    static let shared = CrashService()

    // ── Round-state mirror ──────────────────────────────────────────
    @Published private(set) var phase: CrashPhase = .betting
    @Published private(set) var roundID: String = ""
    @Published private(set) var seedHash: String = ""
    @Published private(set) var runningStartedAt: Date?
    @Published private(set) var crashInSecondsHint: Double = 0
    @Published private(set) var bettingStartedAt: Date?
    @Published private(set) var bettingSeconds: Double = 8.0

    @Published private(set) var lastCrashPoint: Double?
    @Published private(set) var lastSeed: String?
    @Published private(set) var crashedAt: Date?

    @Published private(set) var cashouts: [CrashCashoutEvent] = []
    @Published private(set) var participants: [CrashParticipant] = []
    @Published private(set) var betsCount: Int = 0
    @Published private(set) var history: [CrashHistoryEntry] = []

    @Published private(set) var myBetAmount: Int?
    private var isPlacingBet: Bool = false
    @Published private(set) var myCashoutMultiplier: Double?
    @Published private(set) var myPayout: Int?
    @Published private(set) var iLost: Bool = false

    @Published var lastError: String?

    // ── Mini-bar state ──────────────────────────────────────────────
    @Published private(set) var isMinimized: Bool = false
    @Published private(set) var isHidden: Bool = false

    var shouldShowMini: Bool {
        isMinimized && !isHidden && (phase == .betting || phase == .running || phase == .crashed)
    }

    func minimize() {
        isMinimized = true
    }

    func expand() {
        isMinimized = false
        isHidden = false
    }

    func hideMini() {
        isHidden = true
    }

    // ── Internal ────────────────────────────────────────────────────
    private let log = Logger(subsystem: "app.rcq.client", category: "crash")
    private var cancellables = Set<AnyCancellable>()
    /// Slot for the currently in-flight refresh. New `refresh()` calls
    /// cancel the previous one — WS reconnect storms used to fire many
    /// refreshes in parallel, each pulling state and racing apply()
    /// against WS events, which produced the "round seems to be in
    /// the wrong phase / restarts mid-bet" visual chaos testers saw.
    private var refreshTask: Task<Void, Never>?
    /// Wallclock of the last WS event we applied. Refresh's apply path
    /// checks this — if a WS event came in AFTER the snapshot GET
    /// started, the snapshot is stale and we drop it. WS events carry
    /// fresher state than a synchronous HTTP poll can, so we always
    /// prefer them when there's a contest.
    private var lastEventAt: Date = .distantPast

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // ── Public surface ──────────────────────────────────────────────

    func refresh() async {
        refreshTask?.cancel()
        let startedAt = Date()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                do {
                    let snapshot: CrashStateSnapshot = try await APIClient.shared
                        .request("GET", "/crash/state")
                    if Task.isCancelled { return }
                    // WS event raced ahead of us — its data is newer.
                    // Discarding the snapshot prevents the classic
                    // "ws says running, http snapshot says betting,
                    // UI flips back" thrash that froze the graph mid-
                    // round for testers.
                    if self.lastEventAt > startedAt {
                        self.log.notice("crash refresh dropped: WS event raced past")
                        return
                    }
                    self.apply(snapshot)
                    return
                } catch {
                    self.log.error("crash refresh failed (attempt \(attempt + 1)): \(error.localizedDescription)")
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                }
            }
        }
        refreshTask = task
        await task.value
    }

    @discardableResult
    func placeBet(amount: Int) async -> Int? {
        guard !roundID.isEmpty else { return nil }
        guard phase == .betting else {
            lastError = "crash.error.betting_closed".localized
            return nil
        }
        // Silent no-op on double-tap; server would 400 with "already bet".
        if isPlacingBet || myBetAmount != nil { return nil }
        isPlacingBet = true
        defer { isPlacingBet = false }
        struct Body: Encodable { let round_id: String; let amount: Int }
        struct Reply: Decodable { let ok: Bool; let wallet_tokens: Int }
        do {
            let reply: Reply = try await APIClient.shared.request(
                "POST", "/crash/bet",
                body: Body(round_id: roundID, amount: amount)
            )
            myBetAmount = amount
            ItemsService.shared.setWalletTokens(reply.wallet_tokens)
            SoundService.shared.play(.crashBetPlaced)
            return reply.wallet_tokens
        } catch {
            // Race with another in-flight tap; silent no-op.
            if let apiErr = error as? APIError, case .http(400, let body) = apiErr,
               body?.contains("already") == true {
                return nil
            }
            lastError = Self.friendlyBetError(error)
            // "Betting closed" almost always means our local phase is
            // stale (we still think .betting but server advanced to
            // .running). Pull a fresh snapshot so the bar reflects
            // reality before the user taps again.
            if let apiErr = error as? APIError, case .http(let code, let body) = apiErr,
               code == 400 || code == 409,
               body?.contains("not active") == true || body?.contains("not running") == true
                    || body?.contains("betting closed") == true {
                Task { [weak self] in await self?.refresh() }
            }
            return nil
        }
    }

    @discardableResult
    func cashout() async -> Double? {
        guard !roundID.isEmpty else { return nil }
        guard phase == .running else {
            lastError = "crash.error.cashout_too_late".localized
            return nil
        }
        struct Body: Encodable { let round_id: String }
        struct Reply: Decodable { let ok: Bool; let multiplier: Double; let payout: Int; let wallet_tokens: Int }
        do {
            let reply: Reply = try await APIClient.shared.request(
                "POST", "/crash/cashout",
                body: Body(round_id: roundID)
            )
            myCashoutMultiplier = reply.multiplier
            myPayout = reply.payout
            ItemsService.shared.setWalletTokens(reply.wallet_tokens)
            SoundService.shared.play(.crashCashout)
            return reply.multiplier
        } catch {
            lastError = Self.friendlyCashoutError(error)
            return nil
        }
    }

    /// Maps API errors to user-readable strings. The server returns
    /// short English tags ("round not active", "round not running",
    /// "too late, already crashed", "no bet", "insufficient gems") —
    /// all real outcomes the player needs to recognise. We surface
    /// localised text instead of the raw tag.
    ///
    /// Special case: a cashout that lands after the round transitioned
    /// to `crashed` (the round-loop hit `crashed` before the request
    /// arrived) is semantically identical to "too late, already
    /// crashed" — bet is forfeit. Mapping both 409 variants to the
    /// same `cashout_too_late` string so the player gets one clear
    /// explanation instead of guessing what "round not running" means.
    static func friendlyCashoutError(_ error: Error) -> String {
        if let apiErr = error as? APIError, case .http(let status, let body) = apiErr {
            let raw = body ?? ""
            if status == 409 {
                if raw.contains("already crashed")
                    || raw.contains("not running")
                    || raw.contains("not active") {
                    return "crash.error.cashout_too_late".localized
                }
                if raw.contains("already cashed") {
                    return "crash.error.already_cashed".localized
                }
            }
            if status == 404 && raw.contains("no bet") {
                return "crash.error.no_bet".localized
            }
        }
        return "crash.error.network".localized
    }

    static func friendlyBetError(_ error: Error) -> String {
        if let apiErr = error as? APIError, case .http(let status, let body) = apiErr {
            let raw = body ?? ""
            if status == 409 {
                if raw.contains("not active") || raw.contains("betting closed") {
                    return "crash.error.betting_closed".localized
                }
                if raw.contains("already bet") {
                    return "crash.error.already_bet".localized
                }
            }
            if status == 402 {
                return "crash.error.insufficient".localized
            }
        }
        return "crash.error.network".localized
    }

    /// Live multiplier projection. Capped at the server's crash hint
    /// so a delayed end event can't visibly outrun the actual crash.
    func projectedMultiplier(at now: Date) -> Double {
        guard phase == .running, let started = runningStartedAt else { return 1.00 }
        let elapsed = max(0, now.timeIntervalSince(started))
        let cap = exp(0.07 * (crashInSecondsHint + 0.20))
        return min(exp(0.07 * elapsed), cap)
    }

    /// Server uses GROWTH_RATE = 0.07.
    static func multiplier(forElapsed seconds: Double) -> Double {
        guard seconds > 0 else { return 1.00 }
        return exp(0.07 * seconds)
    }

    // ── Snapshot apply ──────────────────────────────────────────────

    private func apply(_ snap: CrashStateSnapshot) {
        roundID = snap.roundID
        phase = snap.state
        seedHash = snap.seedHash
        history = snap.history
        cashouts = snap.cashouts
        betsCount = snap.betsCount
        myBetAmount = snap.myBetAmount
        myCashoutMultiplier = snap.myCashoutAt
        myPayout = snap.myPayout
        switch snap.state {
        case .betting:
            if let left = snap.bettingSecondsLeft {
                bettingStartedAt = Date().addingTimeInterval(-(8.0 - left))
            } else {
                bettingStartedAt = Date()
            }
            bettingSeconds = 8.0
            runningStartedAt = nil
            crashInSecondsHint = 0
            lastCrashPoint = nil
            lastSeed = nil
            iLost = false
        case .running:
            runningStartedAt = Date().addingTimeInterval(-snap.elapsedSeconds)
            crashInSecondsHint = snap.crashInSecondsHint ?? 0
            bettingStartedAt = nil
            lastCrashPoint = nil
            lastSeed = nil
        case .crashed:
            runningStartedAt = nil
            crashInSecondsHint = 0
            bettingStartedAt = nil
            lastCrashPoint = snap.lastCrashPoint
            lastSeed = nil
            // Anchor to "now"; mid-phase opens show a stale 4s at worst.
            crashedAt = Date()
            iLost = snap.myBetAmount != nil && snap.myCashoutAt == nil
        }
    }

    // ── WS event dispatch ──────────────────────────────────────────

    private func handle(_ event: WebSocketService.Event) {
        // Only the phase-changing events stamp lastEventAt — those are
        // the ones a stale snapshot could roll back. .opened is just a
        // connection cue (no state) and .crashBetPlaced/.crashCashout
        // mutate side state that a snapshot legitimately refreshes.
        switch event {
        case .crashRoundBetting, .crashRoundRunning, .crashRoundEnd:
            lastEventAt = Date()
        default: break
        }
        switch event {
        case .crashRoundBetting(let id, let hash, let bs):
            roundID = id
            seedHash = hash
            phase = .betting
            bettingStartedAt = Date()
            bettingSeconds = bs
            runningStartedAt = nil
            crashInSecondsHint = 0
            crashedAt = nil
            cashouts = []
            participants = []
            betsCount = 0
            myBetAmount = nil
            myCashoutMultiplier = nil
            myPayout = nil
            iLost = false
            lastCrashPoint = nil
            lastSeed = nil

        case .crashRoundRunning(let id, let hint):
            // Old strict guard `id == roundID` silently dropped this
            // event when the client missed crashRoundBetting (briefly
            // disconnected) — phase stuck at .betting forever, the
            // bet button stayed enabled and the user got a 400 "round
            // not active" when they tapped it. Now: adopt the new
            // roundID + go to .running. No async refresh from here —
            // that introduced thrash where snapshot applies raced WS
            // events and flipped phase back and forth.
            if id != roundID {
                log.notice("crashRoundRunning for unknown round — adopting")
                roundID = id
                // Reset state we'd otherwise carry over from the prior
                // round (myBet etc.) — the user hasn't bet in THIS round.
                myBetAmount = nil
                myCashoutMultiplier = nil
                myPayout = nil
                iLost = false
                cashouts = []
                participants = []
                betsCount = 0
                lastCrashPoint = nil
                lastSeed = nil
            }
            phase = .running
            runningStartedAt = Date()
            crashInSecondsHint = hint
            bettingStartedAt = nil
            // Cue only when we have skin in the round.
            if myBetAmount != nil {
                SoundService.shared.play(.crashRunning)
            }

        case .crashRoundEnd(let id, let crash, let seed, let cs):
            // Always append to history, even when the id doesn't match
            // our current roundID — happens when the new round's
            // betting event arrived first; the history strip should
            // still record the crash that just happened.
            if !history.contains(where: { $0.roundID == id }) {
                let entry = CrashHistoryEntry(roundID: id, crashPoint: crash)
                history.append(entry)
                if history.count > 20 { history.removeFirst(history.count - 20) }
            }
            // Only flip phase + show the splash if it's for the round
            // the user is currently watching.
            guard id == roundID else { return }
            phase = .crashed
            lastCrashPoint = crash
            lastSeed = seed
            cashouts = cs
            runningStartedAt = nil
            crashInSecondsHint = 0
            crashedAt = Date()
            // cs → .cashed (catches late-joiners), residual .holding → .burned.
            for c in cs {
                if let idx = participants.firstIndex(where: { $0.uin == c.uin }) {
                    participants[idx].state = .cashed(c.multiplier, c.payout)
                    if participants[idx].nickname == nil, let nick = c.nickname {
                        participants[idx].nickname = nick
                    }
                }
            }
            for i in participants.indices where participants[i].state == .holding {
                participants[i].state = .burned
            }
            let entry = CrashHistoryEntry(roundID: id, crashPoint: crash)
            history.append(entry)
            if history.count > 20 { history.removeFirst(history.count - 20) }
            if myBetAmount != nil && myCashoutMultiplier == nil {
                iLost = true
                SoundService.shared.play(.crashBurn)
            }

        case .crashCashout(let id, let uin, let nick, let mult, let payout):
            // Late cashout events for past rounds are harmless — just
            // drop them silently. Strict guard prevents the in-round
            // cashout list from growing stale entries.
            guard id == roundID else { return }
            if !cashouts.contains(where: { $0.uin == uin }) {
                cashouts.append(CrashCashoutEvent(uin: uin, nickname: nick, multiplier: mult, payout: payout))
            }
            if let idx = participants.firstIndex(where: { $0.uin == uin }) {
                participants[idx].state = .cashed(mult, payout)
                if participants[idx].nickname == nil, let nick {
                    participants[idx].nickname = nick
                }
            }

        case .crashBetPlaced(let id, let uin, let nick, let amount, let count):
            guard id == roundID else { return }
            betsCount = count
            if !participants.contains(where: { $0.uin == uin }) {
                participants.append(CrashParticipant(uin: uin, nickname: nick, amount: amount, state: .holding))
            }

        case .opened:
            // WS reconnect — pull a fresh snapshot so we don't keep
            // rendering the stale pre-disconnect round. `refresh()`
            // now cancels any in-flight refresh so the storm of
            // reconnects during a flaky WS doesn't spawn parallel
            // applies and race against direct WS events.
            Task { [weak self] in await self?.refresh() }

        default:
            break
        }
    }
}
