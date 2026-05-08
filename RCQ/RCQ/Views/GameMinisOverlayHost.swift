import SwiftUI

/// Root-level overlay layer for floating game minis (Crash + Auction).
/// Mounted in `RootView`'s top ZStack so the bubble persists across
/// NavigationStack pushes and tab swaps. Host is invisible; bubble
/// subtree re-enables hit-testing on its own rect.
struct GameMinisOverlayHost: View {
    @StateObject private var crash = CrashService.shared
    @StateObject private var auctions = UinAuctionService.shared
    @AppStorage("rcq.gameMinis.enabled") private var minisEnabled: Bool = true

    var body: some View {
        ZStack {
            if minisEnabled && crash.shouldShowMini {
                FloatingMini(
                    storageKey: "rcq.mini.crash.position",
                    initialPosition: defaultCrashPosition(),
                    bubbleSize: CGSize(width: 220, height: 44)
                ) {
                    CrashMiniBubble()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            if minisEnabled && auctions.shouldShowMini {
                FloatingMini(
                    storageKey: "rcq.mini.auction.position",
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
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: minisEnabled)
    }

    private func defaultCrashPosition() -> CGPoint {
        let bounds = UIScreen.main.bounds
        return CGPoint(x: bounds.width - 120, y: bounds.height - 220)
    }

    private func defaultAuctionPosition() -> CGPoint {
        let bounds = UIScreen.main.bounds
        return CGPoint(x: bounds.width - 120, y: bounds.height - 290)
    }
}
