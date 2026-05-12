import SwiftUI

/// Root-level overlay layer for floating game minis (Crash + Auction).
/// Mounted in `RootView`'s top ZStack so the bubble persists across
/// NavigationStack pushes and tab swaps. Host is invisible; bubble
/// subtree re-enables hit-testing on its own rect.
struct GameMinisOverlayHost: View {
    @StateObject private var crash = CrashService.shared
    @StateObject private var auctions = UinAuctionService.shared
    @EnvironmentObject private var appState: AppState
    @AppStorage("rcq.gameMinis.enabled") private var minisEnabled: Bool = true

    @State private var showFullCrash: Bool = false
    @State private var showFullAuction: Bool = false

    var body: some View {
        ZStack {
            if minisEnabled && crash.shouldShowMini {
                FloatingMini(
                    storageKey: "rcq.mini.crash.position",
                    initialPosition: defaultCrashPosition(),
                    bubbleSize: CGSize(width: 220, height: 44)
                ) { docked in
                    CrashMiniBubble(isDocked: docked) { showFullCrash = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            if minisEnabled && auctions.shouldShowMini {
                FloatingMini(
                    storageKey: "rcq.mini.auction.position",
                    initialPosition: defaultAuctionPosition(),
                    bubbleSize: CGSize(width: 280, height: 62)
                ) { docked in
                    AuctionMiniBubble(isDocked: docked) { showFullAuction = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: crash.shouldShowMini)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: auctions.shouldShowMini)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: minisEnabled)
        .fullScreenCover(isPresented: $showFullCrash) { CrashView() }
        .fullScreenCover(isPresented: $showFullAuction) { UinAuctionView() }
        .onChange(of: appState.pendingOpenUinAuction) { newValue in
            // Outbid banner tap → open auction. Reset the flag once
            // consumed so the same banner can fire again next round.
            if newValue {
                appState.pendingOpenUinAuction = false
                showFullAuction = true
            }
        }
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
