import SwiftUI

/// Floating Auction mini-bubble. Renders only when the user has a bid.
/// Two visual modes: green "leading" or red "outbid + re-bid".
struct AuctionMiniBubble: View {
    @StateObject private var svc = UinAuctionService.shared

    @State private var bidText: String = ""
    var isDocked: Bool = false
    var openFull: () -> Void = {}

    var body: some View {
        if let auction = svc.active {
            Group {
                if isDocked {
                    dockedTab
                } else {
                    VStack(spacing: 0) {
                        timerStrip(auction: auction)
                        mainRow(auction: auction)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(svc.iAmHighBidder ? Theme.Color.accent : Color.red)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: svc.iAmHighBidder)
            .onLongPressGesture(minimumDuration: 0.35) { openFull() }
            // Double-tap is the primary "expand to full game" gesture
            // per user request — long-press kept as a fallback.
            .onTapGesture(count: 2) { openFull() }
            .onAppear { seedBidText() }
            .onChange(of: svc.minNextBid) { _ in seedBidText() }
        }
    }

    /// Compact tab shown when the bubble is docked off-screen — a
    /// vertical capsule with the auction icon. Double-tap still opens
    /// the full screen, single tap (handled by FloatingMini) un-docks.
    @ViewBuilder
    private var dockedTab: some View {
        ZStack {
            Capsule()
                .fill(svc.iAmHighBidder ? Theme.Color.accent : Color.red)
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            Image(systemName: "hammer.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private func timerStrip(auction: UinAuction) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let remaining = max(0, auction.endsAt.timeIntervalSince(ctx.date))
            let inSoftClose = remaining > 0 && remaining <= 10
            HStack(spacing: 5) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(inSoftClose ? 1.0 : 0.85))
                Text(formatRemaining(remaining))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(inSoftClose ? 1.0 : 0.92))
                if inSoftClose {
                    Text("•")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer(minLength: 0)
                Button {
                    svc.hideMini()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 0.5)
            }
            .clipShape(
                .rect(
                    topLeadingRadius: 14, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 14
                )
            )
        }
    }

    @ViewBuilder
    private func mainRow(auction: UinAuction) -> some View {
        HStack(spacing: 8) {
            statusContent(auction: auction)
                .layoutPriority(1)

            Spacer(minLength: 2)

            bidInput(enabled: !svc.iAmHighBidder)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func formatRemaining(_ s: TimeInterval) -> String {
        if s >= 60 {
            let total = Int(s)
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return String(format: "%ds", Int(s.rounded()))
    }

    @ViewBuilder
    private func statusContent(auction: UinAuction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // fixedSize so the UIN doesn't get squeezed to "UIN 12345…".
            Text(verbatim: "UIN \(auction.uin)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(svc.iAmHighBidder
                  ? String(format: "auction.mini.leading".localized, auction.highBid)
                  : "auction.mini.outbid".localized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func bidInput(enabled: Bool) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 14, height: 14)
                    .opacity(enabled ? 1 : 0.55)
                TextField("", text: $bidText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .tint(.white)
                    .frame(width: 50, height: 18)
                    .disabled(!enabled)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(enabled ? 0.18 : 0.10)))
            Button {
                guard let amount = Int(bidText), amount >= svc.minNextBid else { return }
                Task { _ = await svc.placeBid(amount: amount) }
            } label: {
                Text("auction.mini.bid_cta".localized)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(enabled ? .red : Color.red.opacity(0.6))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(enabled ? 1 : 0.7)))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
    }

    private func seedBidText() {
        if bidText.isEmpty || (Int(bidText) ?? 0) < svc.minNextBid {
            bidText = String(svc.minNextBid)
        }
    }
}
