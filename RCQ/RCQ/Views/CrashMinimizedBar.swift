import SwiftUI

/// Floating Crash mini-bubble. Hosted by `GameMinisOverlayHost`
/// inside a `FloatingMini` container — surrounding container
/// owns drag/snap/peek behaviour, this view is just the visual
/// card with the live game controls.
///
/// Layout: **X close on the leading side** so when the bubble
/// is docked off-screen at the right edge, the visible peek tab
/// is the X — user knows they can dismiss right from the peek.
/// The right side of the bubble carries the action button
/// (Bet / Cash-out / disabled placeholder) so the bubble
/// reads "close ← play".
struct CrashMiniBubble: View {
    @StateObject private var svc = CrashService.shared

    private static let presets: [Int] = [10, 25, 50, 100, 250, 500]
    @State private var betIndex: Int = 1

    var openFull: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button {
                svc.hideMini()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)

            Image(systemName: "rocket.fill")
                .foregroundColor(.white)
                .font(.system(size: 13, weight: .semibold))

            content
                .layoutPriority(1)

            Spacer(minLength: 2)

            // Action button always renders (disabled when no
            // valid action) so the right edge of the bubble has
            // consistent visual weight across phases — no width
            // jitter when "Bet" → vanishes after placement.
            actionButton
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        // Expand to fill the outer FloatingMini-proposed frame so
        // the background draws at fixed bubble dimensions instead
        // of shrinking to HStack-intrinsic. Without this, swapping
        // "Поставить" → "Принято" or showing the payout pill (coin
        // gif + amount) made the visible card width / height jitter
        // by a few pt every phase change.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(backgroundTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.25), value: svc.phase)
        .onLongPressGesture(minimumDuration: 0.35) { openFull() }
    }

    /// Tint-by-phase: green-accent during normal play, red while
    /// the round is crashing, smoothly cross-faded by the
    /// `.animation(value: svc.phase)` modifier above.
    private var backgroundTint: Color {
        switch svc.phase {
        case .crashed: return Color.red
        case .betting, .running: return Theme.Color.accent
        }
    }

    @ViewBuilder
    private var content: some View {
        switch svc.phase {
        case .betting:
            amountCarousel
        case .running:
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let m = svc.projectedMultiplier(at: ctx.date)
                Text(String(format: "%.2f×", m))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
            }
        case .crashed:
            Text(String(format: "%.2f×", svc.lastCrashPoint ?? 1.0))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.95))
        }
    }

    private var amountCarousel: some View {
        HStack(spacing: 4) {
            Button {
                betIndex = max(0, betIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .disabled(betIndex == 0)

            // Coin gif + amount as one tight unit. Inner spacing
            // 1pt + leading-aligned text frame hugs the digits to
            // the gif so they read as "🪙 100", not "🪙   100".
            HStack(spacing: 1) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 14, height: 14)
                Text("\(Self.presets[betIndex])")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(minWidth: 24, alignment: .leading)
                    .contentTransition(.numericText())
            }

            Button {
                betIndex = min(Self.presets.count - 1, betIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .disabled(betIndex == Self.presets.count - 1)
        }
    }

    /// Single phase-aware trailing element — always present so the
    /// bubble's width stays steady across phases. Shapes:
    ///
    /// - **Bet** (active, white pill): betting phase, no bet yet.
    /// - **Placed** (disabled placeholder): betting phase after we
    ///   placed our bet — keeps the layout filled until running.
    /// - **Cash-out** (active, white pill): running phase, holding
    ///   a bet that hasn't cashed yet. The big tap target.
    /// - **Cash-out** (disabled placeholder): running phase but we
    ///   never bet this round — read-only state.
    /// - **Payout pill** (coin gif + amount): running OR crashed
    ///   phase after a successful cash-out — replaces the cash-out
    ///   button until the next round resets state.
    @ViewBuilder
    private var actionButton: some View {
        if let payout = svc.myPayout, svc.myCashoutMultiplier != nil {
            payoutPill(amount: payout)
        } else {
            switch svc.phase {
            case .betting:
                if svc.myBetAmount == nil {
                    pillButton(label: "crash.mini.bet_cta".localized, enabled: true) {
                        Task { _ = await svc.placeBet(amount: Self.presets[betIndex]) }
                    }
                } else {
                    pillButton(label: "crash.mini.placed".localized, enabled: false) {}
                }
            case .running:
                // Render the cash-out pill ONLY when we actually have a
                // live bet to cash. Spectating (no stake) used to show
                // a permanently-disabled pill that read as a broken UI
                // element. Empty trailing slot is cleaner — the
                // multiplier in `content` already conveys "round in
                // progress".
                if svc.myBetAmount != nil && svc.myCashoutMultiplier == nil {
                    pillButton(label: "crash.mini.cashout_cta".localized, enabled: true) {
                        Task { _ = await svc.cashout() }
                    }
                }
            case .crashed:
                // No actionable button mid-crash either — keep the
                // trailing slot empty so the bubble doesn't look like
                // it's offering a click that does nothing.
                EmptyView()
            }
        }
    }

    /// Coin-gif + payout amount, rendered in the same white pill
    /// shape as the action buttons so the trailing side stays
    /// visually consistent. Animated coin reuses the lootbox /
    /// inventory `coin.gif` asset.
    private func payoutPill(amount: Int) -> some View {
        HStack(spacing: 3) {
            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                .frame(width: 14, height: 14)
            Text("\(amount)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.accent)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.white))
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    /// White capsule button used uniformly on the trailing side.
    /// `fixedSize(horizontal: true, vertical: false)` prevents
    /// SwiftUI from collapsing the label to "..." when the bubble
    /// is laid out tighter than its intrinsic width. Disabled state
    /// keeps the white background but tints the label with reduced
    /// alpha — text stays clearly visible (just dimmed) so the user
    /// reads "Забрать" / "Cash out" even when nothing's actionable.
    private func pillButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(enabled ? Theme.Color.accent : Theme.Color.accent.opacity(0.7))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(enabled ? 1 : 0.7)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
