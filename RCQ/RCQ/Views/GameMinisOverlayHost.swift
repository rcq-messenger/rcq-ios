import SwiftUI

/// Root-level overlay layer that hosts the floating game mini
/// bubbles (Crash + Auction). Mounted in a top-level `ZStack`
/// in `RootView` so it persists across NavigationStack pushes
/// and tab swaps without being rebuilt — the mini stays parked
/// where the user dragged it even as they walk through chats,
/// inventory, settings, etc.
///
/// The host itself is invisible and `allowsHitTesting(false)`
/// so taps fall through to the underlying NavigationStack
/// everywhere except the bubble's actual content rect (the
/// bubble re-enables hit-testing on its own subtree).
///
/// Both minis can be active simultaneously. To prevent them
/// landing in the exact same spot, the auction bubble's
/// initial position is offset 80pt above the crash bubble's.
/// User-dragged positions persist independently.
struct GameMinisOverlayHost: View {
    @StateObject private var crash = CrashService.shared
    @StateObject private var auctions = UinAuctionService.shared

    var body: some View {
        ZStack {
            if crash.shouldShowMini {
                FloatingMini(
                    storageKey: "rcq.mini.crash.position",
                    initialPosition: defaultCrashPosition(),
                    bubbleSize: CGSize(width: 220, height: 44)
                ) {
                    CrashMiniBubble()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            if auctions.shouldShowMini {
                FloatingMini(
                    storageKey: "rcq.mini.auction.position",
                    // Height bumped from 44 → 62 to fit the timer
                    // strip on top of the bubble (kicker-band look,
                    // shares the bubble's fill so it reads as one
                    // pill, not two stacked cards).
                    initialPosition: defaultAuctionPosition(),
                    bubbleSize: CGSize(width: 280, height: 62)
                ) {
                    AuctionMiniBubble()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: crash.shouldShowMini)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: auctions.shouldShowMini)
    }

    /// Lower-right by default — out of the way of the contact
    /// list's bottom capsule but still on a thumb path.
    private func defaultCrashPosition() -> CGPoint {
        let bounds = UIScreen.main.bounds
        return CGPoint(x: bounds.width - 120, y: bounds.height - 220)
    }

    /// Stacked above the crash bubble's default so a fresh user
    /// with both active sees them side-by-side instead of
    /// overlapping.
    private func defaultAuctionPosition() -> CGPoint {
        let bounds = UIScreen.main.bounds
        return CGPoint(x: bounds.width - 120, y: bounds.height - 290)
    }
}
