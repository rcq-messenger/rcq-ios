import SwiftUI

/// Limbo — pick a target multiplier, server rolls a number from the
/// same exponential distribution as Crash, you win iff roll ≥ target.
/// Single tap, ~2 seconds per round. Same chrome family as CrashView
/// and HiLoView so the games-hub feels coherent.
struct LimboView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = LimboService.shared
    @StateObject private var items = ItemsService.shared

    @State private var betAmount: Int = 5
    @State private var target: Double = 2.00
    @State private var showRules = false
    @State private var resultBanner: LimboOutcome?
    /// Final rolled value the on-screen number animates TO. Updated
    /// in onChange(of: svc.lastResult). Start value 1.00 so an empty
    /// surface reads as "ready for first roll".
    @State private var displayedRoll: Double = 1.00
    /// Pulse the rolled block once on each result landing so the
    /// number doesn't feel like a static value swap. Toggled in
    /// onChange of `svc.lastResult` and animated via .scaleEffect.
    @State private var rollPulse: Bool = false
    /// Wallclock instant of the last roll. The pill is locked for
    /// `rollCooldown` after that. Without this, a fast-finger user
    /// can mash the button between the time `svc.rolling` flips
    /// false and the next request fires — the server handles it but
    /// the UI froze for a beat under load. Keeps animations + state
    /// transitions sane.
    @State private var lastRollAt: Date?
    /// Top-up sheet binding for the wallet-empty path.
    @State private var showShop: Bool = false

    private static let presets: [Int] = [1, 5, 10, 25, 50, 100]
    /// Minimum gap between consecutive rolls. Half a second is below
    /// the threshold a user would notice as "delayed", but blocks
    /// the rapid-fire mash that previously locked the screen.
    private static let rollCooldown: TimeInterval = 0.5
    private static let actionPillHeight: CGFloat = 56
    private static let actionPillRadius: CGFloat = 12

    /// Win probability for the current target — pure client compute,
    /// matches the server's `(1 - HOUSE_EDGE) / target` formula.
    private var winChancePct: Double {
        max(0.01, min(98.0, (1.0 - 0.03) / target * 100.0))
    }

    private var payoutMultiplier: Double {
        round(target * 0.97 * 100) / 100
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
                if let r = resultBanner {
                    resultOverlay(r)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(20)
                }
            }
            .navigationTitle("limbo.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { showRules = true } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        walletBadge
                    }
                }
            }
            .sheet(isPresented: $showRules) {
                LimboRulesSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showShop) {
                BuyTokensSheet()
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: svc.lastResult) { result in
                guard let result else { return }
                // Snap the number to the rolled value (animated by
                // the .contentTransition + .easeOut on displayedRoll)
                // and pulse the block once for tactile feedback.
                displayedRoll = result.rolled
                rollPulse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                    rollPulse = false
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                    resultBanner = result
                }
                if result.won {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    withAnimation(.easeOut(duration: 0.4)) { resultBanner = nil }
                    svc.clearResult()
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            rolledBlock
            Spacer(minLength: 12)
            targetSlider
            Spacer(minLength: 12)
            actionPanel
                .frame(height: 200, alignment: .bottom)
        }
    }

    // ── Rolled block ─────────────────────────────────────────────

    private var rolledBlock: some View {
        VStack(spacing: 8) {
            phaseBadge
                .frame(height: 24)  // reserved height — content swap below doesn't move slider
            // While the server's RPC is in flight, cycle a rapid
            // random-number reel — slot-machine feel that hides the
            // ~150-300ms network latency. When the result lands we
            // snap to the rolled value with a numeric content
            // transition + scale pulse so the number "punches" in.
            Group {
                if svc.rolling {
                    TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                        let cycled = 1.0 + Double.random(in: 0...max(4.0, target * 0.8))
                        Text(String(format: "%.2fx", cycled))
                            .font(.system(size: 96, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(Theme.Color.textSecondary.opacity(0.55))
                    }
                } else {
                    Text(String(format: "%.2fx", displayedRoll))
                        .font(.system(size: 96, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(rolledTint)
                        // .numericText() is iOS 16+ — the
                        // value-binding overload that animates digit
                        // changes on every Double swap is iOS 17+,
                        // so on 16 we just rely on the .easeOut
                        // .animation(value:) below to fade-cross.
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.45), value: displayedRoll)
                }
            }
            .frame(height: 110)
            .scaleEffect(rollPulse ? 1.08 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: rollPulse)
            Text(String(format: "limbo.target.label".localized, target))
                .font(.caption.monospacedDigit())
                .foregroundColor(Theme.Color.textSecondary)
        }
    }

    private var rolledTint: Color {
        guard let r = svc.lastResult else { return Theme.Color.textSecondary }
        return r.won ? Theme.Color.accent : Color(hex: 0xC8442A)
    }

    /// Phase badge always renders SOMETHING — empty branch was making
    /// the rolled block shrink by ~24pt on result land, which pushed
    /// the slider down and the central digits up. Now the badge swaps
    /// content but its height stays put, so layout is stable across
    /// the full ready → rolling → result cycle.
    @ViewBuilder
    private var phaseBadge: some View {
        if svc.rolling {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("limbo.phase.rolling".localized)
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundColor(Theme.Color.accent)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
        } else if let r = svc.lastResult {
            HStack(spacing: 6) {
                Image(systemName: r.won ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text(r.won ? "limbo.phase.won".localized : "limbo.phase.lost".localized)
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundColor(r.won ? Theme.Color.accent : Color(hex: 0xC8442A))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill((r.won ? Theme.Color.accent : Color(hex: 0xC8442A)).opacity(0.12)))
        } else {
            Text("limbo.phase.ready".localized)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(Theme.Color.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
        }
    }

    // ── Target slider ────────────────────────────────────────────

    private var targetSlider: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("limbo.slider.label".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                    Text(String(format: "%.2fx", target))
                        .font(.system(.title3, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.Color.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("limbo.slider.chance".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                    Text(String(format: "%.1f%%", winChancePct))
                        .font(.system(.title3, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.Color.accent)
                }
            }
            // Slider sweeps a logarithmic range — small targets get
            // more granularity (1.10/1.20/1.50) where most play
            // happens, big targets compress (50/100/500) where rolls
            // are vanishingly rare.
            Slider(value: Binding(
                get: { log(target) },
                set: { target = round(exp($0) * 100) / 100 },
            ), in: log(1.10)...log(100.0))
            .tint(Theme.Color.accent)
        }
        .padding(.horizontal, 16)
    }

    // ── Action panel ─────────────────────────────────────────────

    @ViewBuilder
    private var actionPanel: some View {
        VStack(spacing: 10) {
            betPicker
            rollPill
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var betPicker: some View {
        VStack(spacing: 6) {
            HStack {
                Text("limbo.bet.label".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                HStack(spacing: 4) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 14, height: 14)
                    Text("\(betAmount)")
                        .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        betAmount = preset
                    } label: {
                        Text("\(preset)")
                            .font(.system(.caption, weight: .semibold).monospacedDigit())
                            .foregroundColor(betAmount == preset ? .white : Theme.Color.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(betAmount == preset ? Theme.Color.accent : Theme.Color.bgSecondary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Rolling is gated on three things: positive bet, server not
    /// already mid-roll, AND the half-second cooldown window has
    /// elapsed since the previous roll. The wallet check is no
    /// longer here — when funds are short the button swaps to
    /// "Top up" instead of disabling the roll path (handled in
    /// `actionPill`).
    private var canRoll: Bool {
        guard betAmount >= 1, !svc.rolling else { return false }
        if let last = lastRollAt,
           Date().timeIntervalSince(last) < Self.rollCooldown {
            return false
        }
        return true
    }

    private var canAfford: Bool { items.wallet.tokens >= betAmount }

    @ViewBuilder
    private var rollPill: some View {
        if !canAfford {
            // Wallet < bet → swap to "Top up" CTA, same pattern as
            // UinAuctionView. Opens BuyTokensSheet directly so the
            // user never stares at a disabled button wondering what
            // to do next.
            Button {
                showShop = true
            } label: {
                HStack {
                    Image(systemName: "creditcard.fill")
                    Text("games.cta.topup".localized)
                        .font(.system(.callout, weight: .bold))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: Self.actionPillHeight)
                .background(Theme.Color.accent)
                .cornerRadius(Self.actionPillRadius)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                guard canRoll else { return }
                lastRollAt = Date()
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                Task { await svc.roll(bet: betAmount, target: target) }
            } label: {
                HStack {
                    Text(String(format: "limbo.cta.roll".localized, betAmount))
                        .font(.system(.callout, weight: .bold))
                    Spacer()
                    Text(String(format: "%.2fx", payoutMultiplier))
                        .font(.system(.callout, weight: .bold).monospacedDigit())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: Self.actionPillHeight)
                .background(canRoll ? Theme.Color.accent : Theme.Color.divider)
                .cornerRadius(Self.actionPillRadius)
            }
            .buttonStyle(.plain)
            .disabled(!canRoll)
        }
    }

    // ── Result overlay ───────────────────────────────────────────

    private func resultOverlay(_ r: LimboOutcome) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: r.won ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.system(size: 22))
                Text(
                    r.won
                        ? String(format: "limbo.banner.won".localized, r.rolled, r.payout)
                        : String(format: "limbo.banner.lost".localized, r.rolled, r.target)
                )
                .font(.system(.subheadline, weight: .bold))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(r.won ? Theme.Color.accent : Color(hex: 0xC8442A))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    @ViewBuilder
    private var walletBadge: some View {
        let tokens = items.wallet.tokens
        HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                .frame(width: 18, height: 18)
            Text("\(tokens)")
                .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.Color.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.35), value: tokens)
        }
        .padding(.trailing, 8)
    }
}

private struct LimboRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        icon: "play.circle.fill",
                        title: "limbo.rules.how.title".localized,
                        body: "limbo.rules.how.body".localized,
                    )
                    section(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "limbo.rules.payout.title".localized,
                        body: "limbo.rules.payout.body".localized,
                    )
                    section(
                        icon: "lock.shield",
                        title: "limbo.rules.fair.title".localized,
                        body: "limbo.rules.fair.body".localized,
                    )
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("limbo.rules.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
        }
    }

    private func section(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Color.accent)
                Text(title)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            Text(body)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .lineSpacing(2)
        }
    }
}
