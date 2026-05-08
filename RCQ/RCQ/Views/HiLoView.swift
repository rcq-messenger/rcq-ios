import SwiftUI

/// Hi-Lo — guess if the next card is higher or lower than the
/// current one; cash out anytime to settle.
struct HiLoView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = HiLoService.shared
    @StateObject private var items = ItemsService.shared

    @State private var betAmount: Int = 5
    @State private var showRules = false
    @State private var resultBanner: HiLoOutcome?
    @State private var showShop: Bool = false

    private static let presets: [Int] = [1, 5, 10, 25, 50, 100]
    private static let actionPillHeight: CGFloat = 56
    private static let actionPillRadius: CGFloat = 12

    private var actionKey: String {
        "\(svc.active ? 1 : 0)|\(svc.currentCard)|\(svc.multiplier)|\(svc.lastResult?.won == true ? "w" : (svc.lastResult?.won == false ? "l" : "_"))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
                if let banner = resultBanner {
                    resultOverlay(banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(20)
                }
            }
            .navigationTitle("hilo.title".localized)
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
                HiLoRulesSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showShop) {
                BuyTokensSheet()
                    .presentationDetents([.medium, .large])
            }
            .task { await svc.refresh() }
            .onChange(of: svc.lastResult) { result in
                guard let result else { return }
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
                    svc.lastResult = nil
                    svc.reset()
                }
            }
        }
    }

    // MARK: - body sections

    private var content: some View {
        VStack(spacing: 0) {
            drawsStrip
            Spacer(minLength: 8)
            cardBlock
            Spacer(minLength: 12)
            actionPanel
                .frame(height: 200, alignment: .bottom)
        }
    }

    // ── Draws strip ───────────────────────────────────────────────

    private var drawsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(svc.draws.enumerated()), id: \.offset) { _, card in
                    Text(cardLabel(card))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.accent)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 38)
    }

    // ── Card block ────────────────────────────────────────────────

    private var cardBlock: some View {
        VStack(spacing: 14) {
            multiplierBadge
            cardFace
                .frame(width: 140, height: 200)
            Text(String(format: "hilo.card.label".localized, cardLabel(svc.currentCard)))
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
        }
    }

    @ViewBuilder
    private var multiplierBadge: some View {
        // Fixed-height container so the card below doesn't shift as
        // the badge swaps between GUESS / IDLE / multiplier forms.
        Group {
            if svc.active && svc.multiplier > 1.0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.circle.fill")
                    Text(String(format: "%.2fx", svc.multiplier))
                        .font(.system(.callout, weight: .bold).monospacedDigit())
                }
                .foregroundColor(Theme.Color.accent)
                .padding(.horizontal, 12)
                .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
            } else if svc.active {
                Text("hilo.phase.guess".localized)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
            } else {
                Text("hilo.phase.idle".localized)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Theme.Color.bgSecondary))
            }
        }
        .frame(height: 28)
    }

    private var cardFace: some View {
        let label = cardLabel(svc.currentCard)
        return RoundedRectangle(cornerRadius: 14)
            .fill(Theme.Color.bgSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.Color.divider, lineWidth: 1)
            )
            .overlay(
                VStack {
                    HStack {
                        Text(label)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                        Spacer()
                    }
                    Spacer()
                    Text(label)
                        .font(.system(size: 72, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    HStack {
                        Spacer()
                        Text(label)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                            .rotationEffect(.degrees(180))
                    }
                }
                .padding(12)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .id(svc.currentCard)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private func cardLabel(_ n: Int) -> String {
        switch n {
        case 0: return "—"
        case 1: return "A"
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        default: return String(n)
        }
    }

    // ── Action panel ──────────────────────────────────────────────

    @ViewBuilder
    private var actionPanel: some View {
        VStack(spacing: 10) {
            if svc.active {
                guessRow
                cashoutPill
            } else {
                betPicker
                placeBetPill
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: actionKey)
    }

    private var betPicker: some View {
        VStack(spacing: 6) {
            HStack {
                Text("hilo.bet.label".localized)
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

    // Settling: round resolved but the 2.4s result-banner timer
    // hasn't fired svc.reset() yet. Place-bet must be gated here or
    // a fresh round started in this window gets wiped by the timer.
    private var isSettling: Bool { svc.lastResult != nil }

    private var canPlace: Bool {
        betAmount >= 1 && !isSettling
    }

    private var canAfford: Bool { items.wallet.tokens >= betAmount }

    @ViewBuilder
    private var placeBetPill: some View {
        if !canAfford {
            Button {
                showShop = true
            } label: {
                actionPill(background: Theme.Color.accent) {
                    HStack(spacing: 8) {
                        Image(systemName: "creditcard.fill")
                            .foregroundColor(.white)
                        Text("games.cta.topup".localized)
                            .font(.system(.callout, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                guard canPlace else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await svc.start(bet: betAmount) }
            } label: {
                actionPill(background: canPlace ? Theme.Color.accent : Theme.Color.divider) {
                    if isSettling {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.white)
                            Text("hilo.cta.settling".localized)
                                .font(.system(.callout, weight: .bold))
                                .foregroundColor(.white)
                        }
                    } else {
                        Text(String(format: "hilo.cta.start".localized, betAmount))
                            .font(.system(.callout, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canPlace)
        }
    }

    private var guessRow: some View {
        HStack(spacing: 10) {
            guessButton(
                .higher,
                label: "hilo.cta.higher".localized,
                multiplier: svc.multiplierHigher,
                enabled: svc.canHigher,
            )
            guessButton(
                .lower,
                label: "hilo.cta.lower".localized,
                multiplier: svc.multiplierLower,
                enabled: svc.canLower,
            )
        }
    }

    private func guessButton(
        _ dir: HiLoDirection,
        label: String,
        multiplier: Double,
        enabled: Bool,
    ) -> some View {
        Button {
            guard enabled else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await svc.guess(dir) }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: dir == .higher ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    Text(label)
                        .font(.system(.callout, weight: .bold))
                }
                Text(String(format: "%.2fx", multiplier))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .opacity(0.8)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: Self.actionPillHeight)
            .background(enabled ? Theme.Color.accent : Theme.Color.divider)
            .cornerRadius(Self.actionPillRadius)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var cashoutPill: some View {
        let payout = Int(Double(svc.bet) * svc.multiplier)
        let canCash = svc.multiplier > 1.0
        return Button {
            guard canCash else { return }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            Task { await svc.cashout() }
        } label: {
            actionPill(background: canCash ? Color(hex: 0xD9923A) : Theme.Color.bgSecondary) {
                HStack {
                    Text(String(format: "hilo.cta.cashout".localized, svc.multiplier))
                        .font(.system(.callout, weight: .bold).monospacedDigit())
                    Spacer()
                    HStack(spacing: 4) {
                        Text("+\(payout)")
                            .font(.system(.callout, weight: .bold).monospacedDigit())
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 18, height: 18)
                    }
                }
                .foregroundColor(canCash ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 16)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canCash)
    }

    private func actionPill<Label: View>(
        background: Color,
        @ViewBuilder label: () -> Label,
    ) -> some View {
        label()
            .frame(maxWidth: .infinity, minHeight: Self.actionPillHeight)
            .background(background)
            .cornerRadius(Self.actionPillRadius)
    }

    // ── Result overlay ────────────────────────────────────────────

    private func resultOverlay(_ r: HiLoOutcome) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: r.won ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.system(size: 22))
                Text(
                    r.won
                        ? String(format: "hilo.banner.won".localized, r.multiplier, r.payout)
                        : String(format: "hilo.banner.lost".localized, cardLabel(r.finalCard))
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

private struct HiLoRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        icon: "play.circle.fill",
                        title: "hilo.rules.how.title".localized,
                        body: "hilo.rules.how.body".localized,
                    )
                    section(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "hilo.rules.payout.title".localized,
                        body: "hilo.rules.payout.body".localized,
                    )
                    section(
                        icon: "lock.shield",
                        title: "hilo.rules.fair.title".localized,
                        body: "hilo.rules.fair.body".localized,
                    )
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("hilo.rules.title".localized)
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
