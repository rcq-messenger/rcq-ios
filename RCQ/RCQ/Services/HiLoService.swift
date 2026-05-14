import Combine
import Foundation
import os.log

/// Hi-Lo state holder. Solo per-user game — no WS broadcast, all
/// state lives on the server and is mirrored here from REST replies.
/// Public surface parallels `CrashService` so the view
/// layer feels consistent.
@MainActor
final class HiLoService: ObservableObject {
    static let shared = HiLoService()

    // ── Live state ─────────────────────────────────────────────────
    @Published private(set) var sessionID: String = ""
    @Published private(set) var seedHash: String = ""
    @Published private(set) var bet: Int = 0
    @Published private(set) var currentCard: Int = 0
    @Published private(set) var draws: [Int] = []
    @Published private(set) var multiplier: Double = 1.0
    @Published private(set) var multiplierHigher: Double = 0.0
    @Published private(set) var multiplierLower: Double = 0.0
    @Published private(set) var canHigher: Bool = false
    @Published private(set) var canLower: Bool = false
    @Published private(set) var active: Bool = false

    /// True while a /guess or /cashout HTTP call is in flight. Drives
    /// button disable in the view so the user can't fire two
    /// concurrent guesses — which used to race the response handler
    /// and look like "the choice stage froze" (one tap registers, the
    /// next 1-2 taps queue up extra HTTP requests, the server walks
    /// through cards while the iOS state hasn't caught up yet, so the
    /// buttons appear stuck on the previous card).
    @Published private(set) var inFlight: Bool = false

    /// Outcome banner data — set when a guess loses or a /cashout
    /// settles. Cleared on next /start. Drives the result overlay.
    @Published var lastResult: HiLoOutcome?
    /// Last error from a network attempt — toasted briefly.
    @Published var lastError: String?

    private let log = Logger(subsystem: "app.rcq.client", category: "hilo")

    private init() {}

    // ── Surface ────────────────────────────────────────────────────

    /// Pull the current session if we left it mid-chain. Idempotent
    /// — null reply just means "no session".
    func refresh() async {
        do {
            let snap: HiLoState? = try await APIClient.shared.request(
                "GET", "/hilo/state",
            )
            apply(snap)
        } catch {
            log.error("hilo refresh: \(error.localizedDescription)")
        }
    }

    func start(bet: Int) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        struct Body: Encodable { let bet: Int }
        do {
            let snap: HiLoState = try await APIClient.shared.request(
                "POST", "/hilo/start", body: Body(bet: bet),
            )
            apply(snap)
            lastResult = nil
            // Optimistic wallet hint — server already deducted.
            ItemsService.shared.applyWalletDelta(tokens: -bet)
        } catch {
            lastError = APIErrorPresenter.friendly(error)
        }
    }

    func guess(_ direction: HiLoDirection) async {
        // Hard guard against double-fire — even if the view's
        // `.disabled` flag flips on a frame late, a second tap can
        // squeeze through and start a parallel HTTP request.
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        struct Body: Encodable { let direction: String }
        do {
            let raw = try await APIClient.shared.rawRequest(
                "POST", "/hilo/guess", body: Body(direction: direction.rawValue),
            )
            guard let dict = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
            let won = dict["won"] as? Bool ?? false
            let nextCard = dict["next_card"] as? Int ?? 0
            let drawHistory = (dict["draws"] as? [Int]) ?? draws + [nextCard]
            // Card-flip click on every reveal — independent of
            // win/lose. Played first so the win/lose chime layers
            // on top of the flip click.
            SoundService.shared.play(.hiloFlip)
            if !won {
                let mult = dict["multiplier_at_loss"] as? Double ?? multiplier
                let seed = dict["seed"] as? String
                lastResult = HiLoOutcome(
                    won: false, multiplier: mult, payout: 0,
                    finalCard: nextCard, draws: drawHistory, seed: seed,
                )
                active = false
                draws = drawHistory
                currentCard = nextCard
                SoundService.shared.play(.hiloLose)
                return
            }
            let autoCashout = dict["auto_cashout"] as? Bool ?? false
            let mult = dict["multiplier"] as? Double ?? multiplier
            if autoCashout {
                let payout = dict["payout"] as? Int ?? 0
                let seed = dict["seed"] as? String
                lastResult = HiLoOutcome(
                    won: true, multiplier: mult, payout: payout,
                    finalCard: nextCard, draws: drawHistory, seed: seed,
                )
                active = false
                draws = drawHistory
                currentCard = nextCard
                multiplier = mult
                if let new = dict["wallet_tokens"] as? Int {
                    ItemsService.shared.setWalletTokens(new)
                }
                SoundService.shared.play(.hiloWin)
                return
            }
            // Normal correct guess — chain continues.
            currentCard = nextCard
            draws = drawHistory
            multiplier = mult
            recomputeChainOdds()
        } catch {
            lastError = APIErrorPresenter.friendly(error)
        }
    }

    func cashout() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let raw = try await APIClient.shared.rawRequest("POST", "/hilo/cashout")
            guard let dict = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
            let mult = dict["multiplier"] as? Double ?? multiplier
            let payout = dict["payout"] as? Int ?? 0
            let seed = dict["seed"] as? String
            let drawHistory = (dict["draws"] as? [Int]) ?? draws
            lastResult = HiLoOutcome(
                won: true, multiplier: mult, payout: payout,
                finalCard: drawHistory.last ?? currentCard,
                draws: drawHistory, seed: seed,
            )
            active = false
            multiplier = mult
            if let new = dict["wallet_tokens"] as? Int {
                ItemsService.shared.setWalletTokens(new)
            }
            SoundService.shared.play(.hiloWin)
        } catch {
            lastError = APIErrorPresenter.friendly(error)
        }
    }

    /// Drop the local snapshot — used after the result banner is
    /// dismissed so the view returns to the "place a bet" state.
    func reset() {
        sessionID = ""
        seedHash = ""
        bet = 0
        currentCard = 0
        draws = []
        multiplier = 1.0
        multiplierHigher = 0.0
        multiplierLower = 0.0
        canHigher = false
        canLower = false
        active = false
        lastResult = nil
    }

    // ── Internals ──────────────────────────────────────────────────

    private func apply(_ snap: HiLoState?) {
        guard let snap else { reset(); return }
        sessionID = snap.sessionID
        seedHash = snap.seedHash
        bet = snap.bet
        currentCard = snap.currentCard
        draws = snap.draws
        multiplier = snap.multiplier
        multiplierHigher = snap.multiplierHigher
        multiplierLower = snap.multiplierLower
        canHigher = snap.canHigher
        canLower = snap.canLower
        active = snap.active
    }

    /// Re-derive the "next bump" multipliers locally so the cashout
    /// arrows can label correctly between server round-trips. Mirrors
    /// the server's `_multiplier_for(card, direction)` formula
    /// (1/probability × (1 - HOUSE_EDGE)).
    private func recomputeChainOdds() {
        let card = currentCard
        canHigher = card < 13
        canLower = card > 1
        let edge = 0.97
        if canHigher {
            let p = Double(13 - card) / 12.0
            let bump = (1.0 / p) * edge
            multiplierHigher = round(multiplier * bump * 10000) / 10000
        } else {
            multiplierHigher = 0
        }
        if canLower {
            let p = Double(card - 1) / 12.0
            let bump = (1.0 / p) * edge
            multiplierLower = round(multiplier * bump * 10000) / 10000
        } else {
            multiplierLower = 0
        }
    }
}

// ── Models ──────────────────────────────────────────────────────────

enum HiLoDirection: String { case higher, lower }

struct HiLoState: Codable {
    let sessionID: String
    let seedHash: String
    let bet: Int
    let currentCard: Int
    let draws: [Int]
    let multiplier: Double
    let multiplierHigher: Double
    let multiplierLower: Double
    let canHigher: Bool
    let canLower: Bool
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case seedHash = "seed_hash"
        case bet
        case currentCard = "current_card"
        case draws
        case multiplier
        case multiplierHigher = "multiplier_higher"
        case multiplierLower = "multiplier_lower"
        case canHigher = "can_higher"
        case canLower = "can_lower"
        case active
    }
}

struct HiLoOutcome: Hashable {
    let won: Bool
    let multiplier: Double
    let payout: Int
    let finalCard: Int
    let draws: [Int]
    let seed: String?
}
