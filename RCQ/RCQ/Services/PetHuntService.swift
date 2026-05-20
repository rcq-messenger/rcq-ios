import Combine
import Foundation

/// `/pets/hunt/*` client. Local accumulator ticks between server refreshes.
@MainActor
final class PetHuntService: ObservableObject {
    static let shared = PetHuntService()

    @Published private(set) var state: HuntState?
    @Published private(set) var displayedAccumulated: Int = 0
    @Published private(set) var displayedAccumulatedGems: Int = 0
    @Published private(set) var memorial: [MemorialEntry] = []
    @Published var lastResult: HuntResult?
    @Published private(set) var sending: Bool = false
    @Published var lastError: String?

    private init() {}

    func refreshState() async {
        do {
            let s: HuntState = try await APIClient.shared.request("GET", "/pets/hunt/state")
            self.state = s
            self.displayedAccumulated = s.accumulated
            self.displayedAccumulatedGems = s.accumulatedGems
        } catch {
            print("[PetHuntService] refreshState failed: \(error)")
        }
    }

    @discardableResult
    func claim() async -> Int? {
        struct Empty: Encodable {}
        do {
            let out: ClaimOut = try await APIClient.shared.request(
                "POST", "/pets/hunt/claim", body: Empty()
            )
            displayedAccumulated = 0
            displayedAccumulatedGems = 0
            await refreshState()
            await ItemsService.shared.refreshInventory()
            return out.claimed
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    @discardableResult
    func sendHunt(zone: HuntZone) async -> HuntResult? {
        guard !sending else { return nil }
        SmokeTracker.shared.tick(.petHunt)
        sending = true
        defer { sending = false }
        do {
            struct Body: Encodable { let zone: String }
            let result: HuntResult = try await APIClient.shared.request(
                "POST", "/pets/hunt/send",
                body: Body(zone: zone.rawValue),
            )
            self.lastResult = result
            await refreshState()
            await ItemsService.shared.refreshInventory()
            if result.petDied { await refreshMemorial() }
            return result
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    func acknowledgeResult() {
        lastResult = nil
    }

    /// Lazy: only called when the memorial sheet opens.
    func refreshMemorial() async {
        do {
            let entries: [MemorialEntry] = try await APIClient.shared.request(
                "GET", "/pets/hunt/memorial"
            )
            self.memorial = entries
        } catch {
            print("[PetHuntService] refreshMemorial failed: \(error)")
        }
    }

    /// 1Hz tick driven by the view. Per-second integer increment may be 0 for low-tier pets.
    func tickTo(_ now: Date) {
        guard let s = state, let last = s.lastClaimAt, s.pet != nil else { return }
        if s.capReached {
            return
        }
        let elapsed = now.timeIntervalSince(last)
        let cap: TimeInterval = 24 * 3600
        let bounded = min(elapsed, cap)
        let tokPerSec = Double(s.dailyYield) / 86_400.0
        let gemPerSec = Double(s.dailyGems) / 86_400.0
        let liveTok = Int(bounded * tokPerSec)
        let liveGem = Int(bounded * gemPerSec)
        if liveTok > displayedAccumulated {
            displayedAccumulated = liveTok
        }
        if liveGem > displayedAccumulatedGems {
            displayedAccumulatedGems = liveGem
        }
    }
}

private struct ClaimOut: Decodable {
    let claimed: Int
    let claimedGems: Int
    let walletTokens: Int
    let walletGems: Int
    let lastClaimAt: Date

    enum CodingKeys: String, CodingKey {
        case claimed
        case claimedGems = "claimed_gems"
        case walletTokens = "wallet_tokens"
        case walletGems = "wallet_gems"
        case lastClaimAt = "last_claim_at"
    }
}
