import Combine
import Foundation

/// Pet Hunt service — backend-talker for `/pets/hunt/*` endpoints.
/// Holds @Published state for the main view + memorial sheet.
///
/// Local mining buffer ticks forward client-side between refreshes
/// so the user sees jetons accumulate live (every second) instead
/// of jumping in steps when state is re-fetched.
@MainActor
final class PetHuntService: ObservableObject {
    static let shared = PetHuntService()

    @Published private(set) var state: HuntState?
    /// Local-tick approximation of `state.accumulated` — bumped every
    /// second by `PetHuntView` so users see the counter rolling.
    /// Reset to `state.accumulated` on every fresh refresh.
    @Published private(set) var displayedAccumulated: Int = 0
    @Published private(set) var memorial: [MemorialEntry] = []
    /// Last hunt outcome — set when `/send` returns. UI presents the
    /// result modal off this binding then resets it via
    /// `acknowledgeResult`.
    @Published var lastResult: HuntResult?
    @Published private(set) var sending: Bool = false
    @Published var lastError: String?

    private init() {}

    /// Pull `/state`. Called on PetHuntView appear + after any
    /// claim / send mutation so the displayed counters re-anchor
    /// to canonical server values.
    func refreshState() async {
        do {
            let s: HuntState = try await APIClient.shared.request("GET", "/pets/hunt/state")
            self.state = s
            self.displayedAccumulated = s.accumulated
        } catch {
            // Silent on initial load — view shows a placeholder if
            // state stays nil. Surfaced for actions further down.
            print("[PetHuntService] refreshState failed: \(error)")
        }
    }

    /// Claim accumulated mining buffer → wallet. Sets new
    /// `lastClaimAt` server-side, refreshes state on success +
    /// pings ItemsService so the wallet badge re-renders.
    @discardableResult
    func claim() async -> Int? {
        struct Empty: Encodable {}
        do {
            let out: ClaimOut = try await APIClient.shared.request(
                "POST", "/pets/hunt/claim", body: Empty()
            )
            // Optimistic local update so the counter hits 0
            // without a re-fetch round-trip.
            displayedAccumulated = 0
            await refreshState()
            await ItemsService.shared.refreshInventory()
            return out.claimed
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// Send the equipped pet on a hunt in `zone`. Server rolls
    /// outcome and returns it; we mirror reward into the wallet via
    /// `ItemsService.refreshInventory()` and surface the result via
    /// `lastResult`.
    @discardableResult
    func sendHunt(zone: HuntZone) async -> HuntResult? {
        guard !sending else { return nil }
        sending = true
        defer { sending = false }
        do {
            struct Body: Encodable { let zone: String }
            let result: HuntResult = try await APIClient.shared.request(
                "POST", "/pets/hunt/send",
                body: Body(zone: zone.rawValue),
            )
            self.lastResult = result
            // Refresh state + inventory so the new wallet balance,
            // hunts-left counter, and (if pet died) the missing
            // pet from the inventory grid all reflect immediately.
            await refreshState()
            await ItemsService.shared.refreshInventory()
            // If the pet died, also refresh memorial so the
            // tombstone appears next time the user opens it.
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

    /// Pull `/memorial`. Lazy — only called when the Memorial sheet
    /// is opened, not on app start.
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

    /// Bumps the live ticker. Driven by the view's 1Hz Timer.
    /// Computes a fractional rate from `state.dailyYield` (jetons /
    /// 86400 sec); per-second integer increment may be 0 most ticks
    /// for low-tier pets — that's fine, the counter stalls and
    /// jumps when whole jetons accrue.
    func tickTo(_ now: Date) {
        guard let s = state, let last = s.lastClaimAt, s.pet != nil else { return }
        if s.capReached {
            // Already at the 24h ceiling — stop animating.
            return
        }
        let elapsed = now.timeIntervalSince(last)
        let cap: TimeInterval = 24 * 3600
        let bounded = min(elapsed, cap)
        let perSec = Double(s.dailyYield) / 86_400.0
        let live = Int(bounded * perSec)
        if live > displayedAccumulated {
            displayedAccumulated = live
        }
    }
}

private struct ClaimOut: Decodable {
    let claimed: Int
    let walletTokens: Int
    let lastClaimAt: Date

    enum CodingKeys: String, CodingKey {
        case claimed
        case walletTokens = "wallet_tokens"
        case lastClaimAt = "last_claim_at"
    }
}
