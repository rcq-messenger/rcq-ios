import Foundation

/// Crash game phase. Mirrors the server's `_Round.state` string field
/// (`"betting"` / `"running"` / `"crashed"`).
enum CrashPhase: String, Codable {
    case betting
    case running
    case crashed
}

/// One settled cashout from the broadcast feed. Echoed both as the
/// per-event `crashCashout` and bundled in `crashRoundEnd.cashouts` so
/// late-joiners see the full round result.
struct CrashCashoutEvent: Hashable, Codable, Identifiable {
    let uin: Int
    /// Display nickname cached server-side at bet time. Optional for
    /// forward-compat with old payloads (pre-nickname server build) —
    /// the view falls back to the bare UIN when absent.
    let nickname: String?
    let multiplier: Double
    let payout: Int

    /// Synthetic id for SwiftUI ForEach in the live feed. UIN is unique
    /// per round (server enforces one bet per UIN per round) so
    /// `uin` alone is fine.
    var id: Int { uin }
}

/// Per-participant lifecycle for the live feed. One row per UIN that
/// placed a bet this round; transitions:
///
///   .holding → (cashout) → .cashed(multiplier, payout)
///   .holding → (round_end without cashout) → .burned
///
/// The Crash UI groups by state so the user sees a "still in" /
/// "cashed" / "burned" stack instead of just the green winners.
struct CrashParticipant: Identifiable, Hashable {
    let uin: Int
    /// Display nickname carried in `crash_bet_placed` / `crash_cashout`.
    /// Optional for forward-compat (old server build) and because some
    /// peers may have an empty/null nickname.
    var nickname: String?
    let amount: Int
    var state: State

    var id: Int { uin }

    enum State: Hashable {
        case holding                 // bet placed, round not yet settled for them
        case cashed(Double, Int)     // (multiplier, payout) — left in time
        case burned                  // round crashed before they cashed out

        /// Sort weight for the feed — cashed at top, holders middle, burned bottom.
        var sortRank: Int {
            switch self {
            case .cashed: return 0
            case .holding: return 1
            case .burned: return 2
            }
        }
    }
}

/// Snapshot of the live round state, fetched via `GET /crash/state`
/// when the user opens the screen. WS events drive incremental updates
/// after that.
struct CrashStateSnapshot: Codable {
    let roundID: String
    let state: CrashPhase
    let seedHash: String
    let elapsedSeconds: Double
    let multiplierNow: Double
    let crashInSecondsHint: Double?
    let bettingSecondsLeft: Double?
    let betsCount: Int
    let myBetAmount: Int?
    let myCashoutAt: Double?
    let myPayout: Int?
    let cashouts: [CrashCashoutEvent]
    let history: [CrashHistoryEntry]
    let lastCrashPoint: Double?

    enum CodingKeys: String, CodingKey {
        case roundID = "round_id"
        case state
        case seedHash = "seed_hash"
        case elapsedSeconds = "elapsed_seconds"
        case multiplierNow = "multiplier_now"
        case crashInSecondsHint = "crash_in_seconds_hint"
        case bettingSecondsLeft = "betting_seconds_left"
        case betsCount = "bets_count"
        case myBetAmount = "my_bet_amount"
        case myCashoutAt = "my_cashout_at"
        case myPayout = "my_payout"
        case cashouts
        case history
        case lastCrashPoint = "last_crash_point"
    }
}

/// Past crash result entry — drives the small history strip across
/// the top of the Crash screen ("1.42x · 8.91x · 2.10x · …").
struct CrashHistoryEntry: Hashable, Codable, Identifiable {
    let roundID: String
    let crashPoint: Double

    var id: String { roundID }

    enum CodingKeys: String, CodingKey {
        case roundID = "round_id"
        case crashPoint = "crash_point"
    }
}
