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

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // ── Public surface ──────────────────────────────────────────────

    func refresh() async {
        do {
            let snapshot: CrashStateSnapshot = try await APIClient.shared
                .request("GET", "/crash/state")
            apply(snapshot)
        } catch {
            log.error("crash refresh failed: \(error.localizedDescription)")
        }
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
            lastError = error.localizedDescription
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
            lastError = error.localizedDescription
            return nil
        }
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
            guard id == roundID else { return }
            phase = .running
            runningStartedAt = Date()
            crashInSecondsHint = hint
            bettingStartedAt = nil
            // Cue only when we have skin in the round.
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
            // rendering the stale pre-disconnect round.
            Task { [weak self] in await self?.refresh() }

        default:
            break
        }
    }
}
