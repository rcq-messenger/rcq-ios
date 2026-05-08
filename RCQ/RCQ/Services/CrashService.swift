import Combine
import Foundation
import os.log

/// Live state holder for the Crash game. Subscribes to
/// `WebSocketService.shared.events` directly — same pattern as
/// `RandomChatService` / `TradesService` / `CallService`. The view
/// observes `@Published` fields and renders.
///
/// Server-side state machine ticks BETTING → RUNNING → CRASHED → repeat
/// in a single forever-running asyncio task; this client mirrors phase
/// transitions and animates the multiplier locally between events.
///
/// Wallet flow: bet placement HTTP-deducts tokens, cashout HTTP-credits
/// them. The local `walletTokensHint` mirrors the most recent server
/// response so the UI feels instant; the canonical balance comes from
/// `ItemsService.shared.wallet` after the next /me/inventory refresh.
@MainActor
final class CrashService: ObservableObject {
    static let shared = CrashService()

    // ── Round-state mirror ──────────────────────────────────────────
    @Published private(set) var phase: CrashPhase = .betting
    @Published private(set) var roundID: String = ""
    @Published private(set) var seedHash: String = ""
    /// Server-side wall-clock anchor for the running phase. Set the
    /// instant a `crash_round_running` event lands; the view computes
    /// `elapsed = Date().timeIntervalSince(runningStartedAt)` and feeds
    /// that into `multiplier(at:)` to animate.
    @Published private(set) var runningStartedAt: Date?
    /// Hint from server about when this round will crash, measured from
    /// `runningStartedAt`. View uses it for the countdown chip and to
    /// stop animating past the crash point if the end event is briefly
    /// delayed by network jitter.
    @Published private(set) var crashInSecondsHint: Double = 0
    /// Set the moment a `crash_round_betting` event lands. View uses
    /// `Date().timeIntervalSince(bettingStartedAt)` to render the
    /// "betting closes in X.Xs" countdown without polling.
    @Published private(set) var bettingStartedAt: Date?
    @Published private(set) var bettingSeconds: Double = 8.0

    /// Final crash point, populated only during the .crashed phase
    /// (between `crash_round_end` and the next `crash_round_betting`).
    @Published private(set) var lastCrashPoint: Double?
    @Published private(set) var lastSeed: String?
    /// Wall-clock anchor for the .crashed phase. Set when
    /// `crash_round_end` lands, cleared on the next betting phase.
    /// Drives the live "next round in Xs" countdown in CrashView so
    /// the pill ticks down from 4 → 0 instead of being a frozen "4s"
    /// label.
    @Published private(set) var crashedAt: Date?

    /// Cumulative cashouts for the current round, in order of occurrence.
    @Published private(set) var cashouts: [CrashCashoutEvent] = []
    /// Per-UIN participant lifecycle for the round — drives the
    /// unified live feed (holding/cashed/burned). Built incrementally
    /// from `crash_bet_placed` (→ .holding), `crash_cashout` (→ .cashed),
    /// and `crash_round_end` (anything still .holding becomes .burned).
    @Published private(set) var participants: [CrashParticipant] = []
    /// Bet count for the current round — drives the "X players" badge.
    @Published private(set) var betsCount: Int = 0
    /// Sliding window of recent crashes — last 20.
    @Published private(set) var history: [CrashHistoryEntry] = []

    /// What WE bet this round (nil if we haven't placed). Cleared on
    /// new round.
    @Published private(set) var myBetAmount: Int?
    /// In-flight flag for `placeBet`. Used as a re-entrancy guard so
    /// rapid double-taps on the bet button don't race the server
    /// into an "already bet this round" 400. Not @Published — pure
    /// internal state, not surfaced to UI.
    private var isPlacingBet: Bool = false
    /// Set the moment we cash out — drives the "you cashed at X.XXx"
    /// banner. Cleared on new round.
    @Published private(set) var myCashoutMultiplier: Double?
    @Published private(set) var myPayout: Int?
    /// True if we held the bet through to the crash. Drives the red
    /// "burned" banner. Cleared on new round.
    @Published private(set) var iLost: Bool = false

    /// Last error surfaced from a bet/cashout attempt. View shows a
    /// brief toast and clears it.
    @Published var lastError: String?

    // ── Mini-bar state ──────────────────────────────────────────────
    /// True when the user left the full Crash view while a round
    /// is in flight. Drives `CrashMinimizedBar` visibility.
    @Published private(set) var isMinimized: Bool = false
    /// User explicitly closed the mini-bar via the X. Suppresses
    /// re-show until the user opens the full Crash screen again
    /// (which calls `expand()`, resetting this flag).
    @Published private(set) var isHidden: Bool = false

    /// `CrashMinimizedBar` renders only when this is true. Includes
    /// the `.crashed` phase so the bubble can fade through a brief
    /// "crashed @ X.XXx" red banner before settling into the next
    /// `.betting` round, instead of disappearing and re-appearing
    /// (which read as "the mini closed").
    var shouldShowMini: Bool {
        isMinimized && !isHidden && (phase == .betting || phase == .running || phase == .crashed)
    }

    /// Called from `CrashView.onDisappear` — flag the mini.
    func minimize() {
        isMinimized = true
    }

    /// Called from `CrashView.onAppear` — full screen takes over,
    /// hide the mini. Also clears the explicit-hide flag so a fresh
    /// round of "place bet + leave" re-shows the mini.
    func expand() {
        isMinimized = false
        isHidden = false
    }

    /// Called from the mini-bar's X. Suppresses re-show until the
    /// user opens the full screen again.
    func hideMini() {
        isHidden = true
    }

    // ── Internal ────────────────────────────────────────────────────
    private let log = Logger(subsystem: "app.rcq.client", category: "crash")
    private var cancellables = Set<AnyCancellable>()

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // ── Public surface ──────────────────────────────────────────────

    /// Pull the current round state from the server. Called when the
    /// view appears so a mid-round opener sees the correct phase
    /// instead of waiting for the next WS event.
    func refresh() async {
        do {
            let snapshot: CrashStateSnapshot = try await APIClient.shared
                .request("GET", "/crash/state")
            apply(snapshot)
        } catch {
            log.error("crash refresh failed: \(error.localizedDescription)")
        }
    }

    /// Place a bet for the current round. Returns the new wallet
    /// balance on success, or nil on failure (the error is also
    /// surfaced via `lastError`).
    @discardableResult
    func placeBet(amount: Int) async -> Int? {
        guard !roundID.isEmpty else { return nil }
        guard phase == .betting else {
            lastError = "crash.error.betting_closed".localized
            return nil
        }
        // Idempotency guards. Double-tap on the bet button used to
        // race between client-side state flip + server processing:
        // tap-1 fires POST, tap-2 fires another POST while myBetAmount
        // is still nil, server's second POST returns 400 ("already bet
        // this round"), iOS surfaced the raw server error message in a
        // toast. Both the in-flight flag AND the already-bet guard are
        // silent no-ops — no error toast for what the user perceives
        // as a successful "I already pressed it" state.
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
            // Mirror the authoritative new balance into ItemsService
            // so every wallet-binding view (toolbar badges in this
            // sheet, GamesView's badge, future inventory panels) updates
            // in lockstep — no /me/inventory round-trip needed.
            ItemsService.shared.setWalletTokens(reply.wallet_tokens)
            SoundService.shared.play(.crashBetPlaced)
            return reply.wallet_tokens
        } catch {
            // Server-side "already bet this round" — race with another
            // in-flight tap that won. Silent no-op; the UI is already
            // showing `placedBetPill` thanks to the WS bet-confirm event
            // mirroring myBetAmount, so the user doesn't see the
            // double-tap as a failure.
            if let apiErr = error as? APIError, case .http(400, let body) = apiErr,
               body?.contains("already") == true {
                return nil
            }
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Cash out the current bet. Returns the multiplier on success.
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
            // Same authoritative-balance push as on placeBet — ensures
            // the wallet badge ticks UP the instant cashout settles,
            // not after the next inventory refresh.
            ItemsService.shared.setWalletTokens(reply.wallet_tokens)
            SoundService.shared.play(.crashCashout)
            return reply.multiplier
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Live multiplier projection — used by the view's
    /// TimelineView animation. Caps at the crash hint so a delayed
    /// `crash_round_end` event doesn't let the number visibly run
    /// past the truth.
    func projectedMultiplier(at now: Date) -> Double {
        guard phase == .running, let started = runningStartedAt else { return 1.00 }
        let elapsed = max(0, now.timeIntervalSince(started))
        // Stay just under the crash so the UI doesn't briefly show a
        // value the user could have cashed at — the actual crash
        // moment is server-determined. Cap = slightly above hint, with
        // a small fudge for network skew.
        let cap = exp(0.07 * (crashInSecondsHint + 0.20))
        return min(exp(0.07 * elapsed), cap)
    }

    /// Same exponent server uses (`GROWTH_RATE = 0.07`). Exposed so
    /// helpers can compute "what would this multiplier be at t=N".
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
            // Server gave us seconds-left; back-derive the start so the
            // view's countdown stays consistent across phase events.
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
            // We don't know exactly when the crash fired (server-side
            // /state doesn't expose it), but the .crashed → .betting
            // gap is bounded at PAUSE_AFTER_CRASH_SECONDS = 4s. Anchor
            // to "now" so the countdown shows at most a stale 4s on
            // mid-phase opens — corrected to nil the moment the next
            // betting event lands.
            crashedAt = Date()
            // If we had a bet but no cashout entry of our own, we burned.
            iLost = snap.myBetAmount != nil && snap.myCashoutAt == nil
        }
    }

    // ── WS event dispatch ──────────────────────────────────────────

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .crashRoundBetting(let id, let hash, let bs):
            // New round opens. Reset per-round state — ours, peers',
            // history is appended on the round_end before this lands.
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
            guard id == roundID else { return }
            phase = .running
            runningStartedAt = Date()
            crashInSecondsHint = hint
            bettingStartedAt = nil
            // Whoosh — only when we have skin in the round, otherwise
            // the cue spams every spectating screen on every round.
            if myBetAmount != nil {
                SoundService.shared.play(.crashRunning)
            }

        case .crashRoundEnd(let id, let crash, let seed, let cs):
            guard id == roundID else { return }
            phase = .crashed
            lastCrashPoint = crash
            lastSeed = seed
            cashouts = cs
            runningStartedAt = nil
            crashInSecondsHint = 0
            // Anchor the 4s "next round in Xs" countdown shown by
            // CrashView's wait pill.
            crashedAt = Date()
            // Reconcile participants:
            //   - anyone in `cs` becomes .cashed (defensive — should
            //     already be set by per-event handler, but late joiner
            //     who only sees crash_round_end gets caught up here)
            //   - anyone left in .holding flips to .burned
            //   - propagate any nicknames missing on the participant
            //     side (the bet-placed event might have arrived before
            //     we joined the WS, leaving a UIN-only row).
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
            // Append to history (server already pushed this round
            // into its own deque before broadcasting, but we mirror
            // locally so the strip ticks immediately without a /history
            // round-trip).
            let entry = CrashHistoryEntry(roundID: id, crashPoint: crash)
            history.append(entry)
            if history.count > 20 { history.removeFirst(history.count - 20) }
            // Did we burn? Bet placed, no cashout = lost.
            if myBetAmount != nil && myCashoutMultiplier == nil {
                iLost = true
                SoundService.shared.play(.crashBurn)
            }

        case .crashCashout(let id, let uin, let nick, let mult, let payout):
            guard id == roundID else { return }
            // Don't double-count our own cashout — REST reply already
            // appended via `myCashoutMultiplier`. Server still
            // broadcasts to us so peers' clients see consistent
            // ordering, just gate on uin.
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
            // Track participant in .holding state. Server enforces one
            // bet per uin per round so dedupe is paranoid but cheap.
            if !participants.contains(where: { $0.uin == uin }) {
                participants.append(CrashParticipant(uin: uin, nickname: nick, amount: amount, state: .holding))
            }

        default:
            break
        }
    }
}
