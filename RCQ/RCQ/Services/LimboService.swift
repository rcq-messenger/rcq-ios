import Combine
import Foundation
import os.log

/// Limbo state holder. Single-shot per round — no session, just a
/// /roll request and a result. The view holds slider state locally;
/// this service is mostly a thin REST wrapper + result mirror.
@MainActor
final class LimboService: ObservableObject {
    static let shared = LimboService()

    /// Most recent outcome — drives the result banner. Cleared on
    /// next /roll attempt.
    @Published var lastResult: LimboOutcome?
    /// Toasted briefly in the view.
    @Published var lastError: String?
    /// True while a /roll is in flight — disables the button so a
    /// double-tap can't fire two bets.
    @Published private(set) var rolling: Bool = false

    private let log = Logger(subsystem: "app.rcq.client", category: "limbo")

    private init() {}

    /// Send one bet at the given target. `clientSeed` is generated
    /// locally so the player can pre-commit randomness — provably
    /// fair: server seed + client seed → deterministic roll.
    func roll(bet: Int, target: Double) async {
        guard !rolling else { return }
        rolling = true
        // Rolling cue plays the moment we kick off the request — gives
        // the dice-spinning audio a head start so the result chime
        // overlays cleanly when the server replies.
        SoundService.shared.play(.limboRolling)
        defer { rolling = false }
        let clientSeed = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        struct Body: Encodable {
            let bet: Int
            let target: Double
            let client_seed: String
        }
        do {
            let raw = try await APIClient.shared.rawRequest(
                "POST", "/limbo/roll",
                body: Body(bet: bet, target: target, client_seed: clientSeed),
            )
            guard let dict = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
            let won = dict["won"] as? Bool ?? false
            let rolled = dict["rolled"] as? Double ?? 0
            let payout = dict["payout"] as? Int ?? 0
            let payoutMult = dict["payout_multiplier"] as? Double ?? 0
            let serverSeed = dict["server_seed"] as? String
            let serverHash = dict["server_seed_hash"] as? String
            lastResult = LimboOutcome(
                won: won, rolled: rolled, target: target,
                payoutMultiplier: payoutMult, payout: payout,
                bet: bet,
                serverSeed: serverSeed, serverSeedHash: serverHash,
                clientSeed: clientSeed,
            )
            if let new = dict["wallet_tokens"] as? Int {
                ItemsService.shared.setWalletTokens(new)
            }
            SoundService.shared.play(won ? .limboWin : .limboLose)
        } catch {
            lastError = APIErrorPresenter.friendly(error)
        }
    }

    func clearResult() {
        lastResult = nil
    }
}

struct LimboOutcome: Hashable {
    let won: Bool
    let rolled: Double
    let target: Double
    let payoutMultiplier: Double
    let payout: Int
    let bet: Int
    let serverSeed: String?
    let serverSeedHash: String?
    let clientSeed: String
}
