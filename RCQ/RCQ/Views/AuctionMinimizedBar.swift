import SwiftUI

/// Floating Auction mini-bubble. Renders only when the user has
/// a bid in the active round (leading or outbid). Two visual
/// modes: green-accent "leading" or red "outbid + re-bid".
///
/// Layout: **X close on the leading side** so when the bubble
/// is docked off-screen at the right edge, the visible peek
/// tab is the X — same convention as `CrashMiniBubble`.
struct AuctionMiniBubble: View {
    @StateObject private var svc = UinAuctionService.shared

    @State private var bidText: String = ""
    var openFull: () -> Void = {}

    var body: some View {
        if let auction = svc.active {
            VStack(spacing: 0) {
                timerStrip(auction: auction)
                mainRow(auction: auction)
            }
            // Same expand-to-fill trick as `CrashMiniBubble` — pins
            // the bg to the outer FloatingMini frame so leading /
            // outbid transitions don't visibly resize the card.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(svc.iAmHighBidder ? Theme.Color.accent : Color.red)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .animation(.easeInOut(duration: 0.2), value: svc.iAmHighBidder)
            .onLongPressGesture(minimumDuration: 0.35) { openFull() }
            .onAppear { seedBidText() }
            .onChange(of: svc.minNextBid) { _ in seedBidText() }
        }
    }

    /// Top "kicker band" — same fill color as the main row but
    /// with a thin white-overlay wash so it reads as one piece
    /// of chrome with a subtle internal divider, not two cards.
    /// Houses the live countdown to round end + the close (X)
    /// affordance now that the band gives us room for it. `TimelineView`
    /// at 1Hz keeps the digit ticking without pulling the whole
    /// bubble through a render.
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
                    // Tiny soft-close badge mirrors the full-screen
                    // view's affordance so an outbid user knows
                    // "snipe window".
                    Text("•")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer(minLength: 0)
                // Close lives top-right now — the timer band gives
                // us a header slot for it, and pinning it here
                // frees the main row's left edge for the status
                // content (UIN + leading/outbid label) to start
                // from the bubble's actual leading edge.
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
            // Subtle white wash so the strip reads as a darker
            // band of the SAME bubble (vs a stacked second pill).
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

            // Bid input + button always rendered — disabled
            // when we're already the high bidder. Same shape
            // pattern as Crash mini's trailing element so the
            // bubble's right edge stays visually consistent
            // across "leading" and "outbid" states.
            bidInput(enabled: !svc.iAmHighBidder)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// "M:SS" while plenty of time remains, plain "SSs" once we're
    /// below a minute. Keeps the strip from blowing up to 4 chars
    /// for a 5-second tail.
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
            // `fixedSize(horizontal: true, vertical: false)` so the
            // UIN never gets squeezed to "UIN 12345…" by sibling
            // layout. Premium UINs go up to ~10 digits and the
            // monospaced 10pt rendering is ~80pt — fits under the
            // bubble's status zone after the hammer icon was
            // removed.
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
                // Shrink-to-fit guards against any localization that
                // overshoots the bubble width (long words in other
                // langs would otherwise truncate mid-letter, like the
                // earlier "Лидируеш…" bug).
                .minimumScaleFactor(0.75)
        }
    }

    /// Coin gif + numeric field bundled in a single capsule (the
    /// "amount badge"), then a separate Bid pill. The coin lives
    /// INSIDE the badge alongside the digits — it reads as one
    /// piece "🪙 1500" rather than "🪙" + "1500". When `enabled`
    /// is false (we're already the high bidder), badge + button
    /// stay visually present but un-tappable, same shape pattern
    /// as Crash's disabled trailing pill.
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
