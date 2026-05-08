import SwiftUI

/// Crash — multiplayer gambling mini-game on the token wallet. Round state
/// lives in `CrashService.shared`; this view renders + handles taps.
struct CrashView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = CrashService.shared
    @StateObject private var items = ItemsService.shared

    @State private var betAmount: Int = 5
    @State private var cashoutBanner: (multiplier: Double, payout: Int)?
    @State private var errorToast: String?
    @State private var showRules = false
    @State private var showShop: Bool = false

    private static let presets: [Int] = [1, 5, 10, 25, 50, 100]

    private static let actionPillHeight: CGFloat = 56
    private static let actionPillRadius: CGFloat = 12

    private var actionPanelKey: String {
        let bet = svc.myBetAmount.map(String.init) ?? "_"
        let cashout = svc.myCashoutMultiplier.map { String(format: "%.2f", $0) } ?? "_"
        return "\(svc.phase.rawValue)|\(bet)|\(cashout)|\(svc.iLost ? 1 : 0)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
                if let banner = cashoutBanner {
                    cashoutOverlay(multiplier: banner.multiplier, payout: banner.payout)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(20)
                }
            }
            .navigationTitle("crash.title".localized)
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
                CrashRulesSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showShop) {
                BuyTokensSheet()
                    .presentationDetents([.medium, .large])
            }
            .task {
                await svc.refresh()
            }
            .onAppear { svc.expand() }
            .onDisappear { svc.minimize() }
            .onChange(of: svc.lastError) { msg in
                guard let msg else { return }
                errorToast = msg
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    if errorToast == msg { errorToast = nil }
                    if svc.lastError == msg { svc.lastError = nil }
                }
            }
            .onChange(of: svc.myCashoutMultiplier) { mult in
                guard let mult, let payout = svc.myPayout else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    cashoutBanner = (mult, payout)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.4)) { cashoutBanner = nil }
                }
            }
            .onChange(of: svc.iLost) { lost in
                if lost {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    Task { await items.refreshInventory() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = errorToast {
                    errorToastView(toast)
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - body sections

    private var content: some View {
        VStack(spacing: 0) {
            historyStrip
            Spacer(minLength: 8)
            multiplierBlock
            Spacer(minLength: 12)
            cashoutFeed
                .frame(maxHeight: 140)
            // Fixed slot keeps the multiplier block anchored across panel swaps.
            actionPanel
                .frame(height: 170, alignment: .bottom)
        }
    }

    // ── History strip ──────────────────────────────────────────────

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(svc.history) { entry in
                    Text(String(format: "%.2fx", entry.crashPoint))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(historyColor(entry.crashPoint))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(
                            Capsule().fill(historyColor(entry.crashPoint).opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 38)
    }

    private func historyColor(_ x: Double) -> Color {
        if x < 1.50 { return Color(hex: 0xC8442A) }
        if x < 2.00 { return Color(hex: 0xD9923A) }
        return Theme.Color.accent
    }

    // ── Multiplier block ──────────────────────────────────────────

    private var multiplierBlock: some View {
        VStack(spacing: 12) {
            phaseBadge
            ZStack {
                multiplierGraph
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Theme.Color.divider.opacity(0.4), lineWidth: 0.5)
                    )
                    .allowsHitTesting(false)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let display = currentMultiplier(at: ctx.date)
                    Text(String(format: "%.2fx", display))
                        .font(.system(size: 96, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(currentMultiplierColor(display))
                        .shadow(color: Theme.Color.bgPrimary.opacity(0.6), radius: 6)
                }
            }
            .frame(height: 150)
            .padding(.horizontal, 24)
            seedHashLine
        }
    }

    private var multiplierGraph: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            Canvas { gctx, size in
                drawGraph(in: gctx, size: size, at: ctx.date)
            }
        }
    }

    private func drawGraph(in gctx: GraphicsContext, size: CGSize, at date: Date) {
        let elapsed: Double
        let multAtNow: Double
        let isCrashed: Bool
        switch svc.phase {
        case .running:
            elapsed = svc.runningStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
            multAtNow = svc.projectedMultiplier(at: date)
            isCrashed = false
        case .crashed:
            let cp = svc.lastCrashPoint ?? 1.00
            elapsed = max(0.001, log(max(1.0001, cp)) / 0.07)
            multAtNow = cp
            isCrashed = true
        case .betting:
            return
        }
        let xMaxSeconds = max(8.0, elapsed)
        let yPeak = max(1.05, multAtNow * 1.05)
        let yRange = max(0.05, yPeak - 1.0)

        func yFor(_ v: Double) -> Double {
            let frac = min(1.0, max(0.0, (v - 1.0) / yRange))
            return size.height - (frac * size.height * 0.92)
        }

        let steps = 80
        let nowX = (elapsed / xMaxSeconds) * size.width
        var area = Path()
        area.move(to: CGPoint(x: 0, y: size.height))
        for i in 0...steps {
            let frac = Double(i) / Double(steps)
            let t = frac * elapsed
            let v = exp(0.07 * t)
            let x = (t / xMaxSeconds) * size.width
            area.addLine(to: CGPoint(x: x, y: yFor(v)))
        }
        area.addLine(to: CGPoint(x: nowX, y: size.height))
        area.closeSubpath()
        var line = Path()
        for i in 0...steps {
            let frac = Double(i) / Double(steps)
            let t = frac * elapsed
            let v = exp(0.07 * t)
            let x = (t / xMaxSeconds) * size.width
            let p = CGPoint(x: x, y: yFor(v))
            if i == 0 {
                line.move(to: p)
            } else {
                line.addLine(to: p)
            }
        }
        let tint = isCrashed ? Color(hex: 0xC8442A) : Theme.Color.accent
        gctx.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0.28), tint.opacity(0.0)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height),
            )
        )
        gctx.stroke(line, with: .color(tint.opacity(0.7)), lineWidth: 1.5)
    }

    private func multiplierTint(for x: Double) -> Color {
        if x < 1.50 { return Theme.Color.textPrimary }
        if x < 3.00 { return Theme.Color.accent }
        if x < 10.00 { return Color(hex: 0xD9923A) }
        return Color(hex: 0xC8442A)
    }

    private func currentMultiplier(at date: Date) -> Double {
        if svc.phase == .crashed {
            return svc.lastCrashPoint ?? 1.00
        }
        if svc.phase == .running {
            return svc.projectedMultiplier(at: date)
        }
        return 1.00
    }

    private func currentMultiplierColor(_ value: Double) -> Color {
        if svc.phase == .crashed { return Color(hex: 0xC8442A) }
        if svc.phase == .running { return multiplierTint(for: value) }
        return Theme.Color.textSecondary
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch svc.phase {
        case .betting:
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let left = max(0, svc.bettingSeconds - (svc.bettingStartedAt.map { ctx.date.timeIntervalSince($0) } ?? 0))
                Text(String(format: "crash.phase.betting".localized, left))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
            }
        case .running:
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.circle.fill")
                Text("crash.phase.running".localized)
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundColor(Theme.Color.accent)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Theme.Color.accent.opacity(0.12)))
        case .crashed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("crash.phase.crashed".localized)
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color(hex: 0xC8442A)))
        }
    }

    @ViewBuilder
    private var seedHashLine: some View {
        if !svc.seedHash.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9))
                Text(String(svc.seedHash.prefix(16)))
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(Theme.Color.textSecondary)
        }
    }

    // ── Participant feed ───────────────────────────────────────────

    private var cashoutFeed: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("crash.feed.title".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                Text(String(format: "crash.feed.bets".localized, svc.betsCount))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 14)
            ScrollView {
                LazyVStack(spacing: 4) {
                    let sorted = sortedParticipants
                    ForEach(sorted) { p in
                        participantRow(p)
                    }
                    if sorted.isEmpty {
                        Text("crash.feed.empty".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 14)
                .animation(.easeInOut(duration: 0.18), value: svc.participants.map(\.id))
            }
        }
    }

    private var sortedParticipants: [CrashParticipant] {
        svc.participants.sorted { a, b in
            if a.state.sortRank != b.state.sortRank {
                return a.state.sortRank < b.state.sortRank
            }
            switch (a.state, b.state) {
            case (.cashed(let ma, _), .cashed(let mb, _)):
                return ma > mb
            default:
                return a.amount > b.amount
            }
        }
    }

    private func participantRow(_ p: CrashParticipant) -> some View {
        let isMe = p.uin == (AuthService.shared.ownUIN ?? -1)
        let nameLabel: String = {
            if isMe { return "crash.you".localized }
            if let n = p.nickname, !n.isEmpty { return n }
            return String(p.uin)
        }()
        let (tint, statusText, valueText): (Color, String, String) = {
            switch p.state {
            case .cashed(let mult, let payout):
                return (
                    Theme.Color.accent,
                    String(format: "%.2fx", mult),
                    "+\(payout)"
                )
            case .holding:
                return (
                    Color(hex: 0xD9923A),
                    "crash.row.holding".localized,
                    "\(p.amount)"
                )
            case .burned:
                return (
                    Color(hex: 0xC8442A),
                    "crash.row.burned".localized,
                    "−\(p.amount)"
                )
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(nameLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isMe ? Theme.Color.accent : Theme.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(statusText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
            Text(valueText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isMe ? Theme.Color.accent.opacity(0.10) : Theme.Color.bgSecondary.opacity(0.5))
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // ── Action panel (bottom) ─────────────────────────────────────

    private func actionPill<Label: View>(
        background: Color,
        @ViewBuilder label: () -> Label,
    ) -> some View {
        label()
            .frame(maxWidth: .infinity, minHeight: Self.actionPillHeight)
            .background(background)
            .cornerRadius(Self.actionPillRadius)
    }

    @ViewBuilder
    private var actionPanel: some View {
        VStack(spacing: 10) {
            if svc.phase == .betting && svc.myBetAmount == nil {
                betPicker
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            }
            ZStack {
                pillForCurrentState
                    .id(actionPanelKey)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: actionPanelKey)
    }

    @ViewBuilder
    private var pillForCurrentState: some View {
        switch svc.phase {
        case .betting:
            if let bet = svc.myBetAmount {
                placedBetPill(bet)
            } else {
                placeBetPill
            }
        case .running:
            if let bet = svc.myBetAmount, svc.myCashoutMultiplier == nil {
                cashoutPill(bet: bet)
            } else if svc.myCashoutMultiplier != nil {
                infoPill(
                    text: "crash.you_cashed".localized,
                    background: Theme.Color.accent.opacity(0.12),
                    foreground: Theme.Color.accent,
                )
            } else {
                infoPill(
                    text: "crash.spectating".localized,
                    background: Theme.Color.bgSecondary,
                    foreground: Theme.Color.textSecondary,
                )
            }
        case .crashed:
            if svc.iLost, let cp = svc.lastCrashPoint {
                resultPill(
                    text: String(format: "crash.result.lost".localized, cp),
                    background: Color(hex: 0xC8442A),
                )
            } else if let mult = svc.myCashoutMultiplier, let pay = svc.myPayout {
                resultPill(
                    text: String(format: "crash.result.won".localized, mult, pay),
                    background: Theme.Color.accent,
                )
            } else {
                // PAUSE_AFTER_CRASH_SECONDS = 4 on the backend.
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let elapsed = svc.crashedAt.map { max(0, ctx.date.timeIntervalSince($0)) } ?? 0
                    let remaining = max(0, Int(ceil(4.0 - elapsed)))
                    infoPill(
                        text: String(format: "crash.result.next_in".localized, remaining),
                        background: Theme.Color.bgSecondary,
                        foreground: Theme.Color.textSecondary,
                    )
                }
            }
        }
    }

    private func infoPill(text: String, background: Color, foreground: Color) -> some View {
        actionPill(background: background) {
            Text(text)
                .font(.system(.callout, weight: .semibold))
                .foregroundColor(foreground)
        }
    }

    private func resultPill(text: String, background: Color) -> some View {
        actionPill(background: background) {
            Text(text)
                .font(.system(.callout, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
    }

    private var betPicker: some View {
        VStack(spacing: 6) {
            HStack {
                Text("crash.bet.label".localized)
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
                Task {
                    _ = await svc.placeBet(amount: betAmount)
                    await items.refreshInventory()
                }
            } label: {
                actionPill(background: canPlace ? Theme.Color.accent : Theme.Color.divider) {
                    Text(String(format: "crash.bet.cta".localized, betAmount))
                        .font(.system(.callout, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canPlace)
        }
    }

    private var canPlace: Bool { betAmount >= 1 }
    private var canAfford: Bool { items.wallet.tokens >= betAmount }

    private func placedBetPill(_ bet: Int) -> some View {
        actionPill(background: Theme.Color.accent.opacity(0.12)) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.Color.accent)
                Text(String(format: "crash.bet.placed".localized, bet))
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Spacer()
                Text("crash.bet.wait".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 14)
        }
    }

    private func cashoutPill(bet: Int) -> some View {
        // TimelineView re-renders only the label so the parent Button's
        // identity stays stable across multiplier ticks.
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            Task { _ = await svc.cashout() }
        } label: {
            actionPill(background: Theme.Color.accent) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let mult = svc.projectedMultiplier(at: ctx.date)
                    let payout = Int(Double(bet) * mult)
                    HStack {
                        Text(String(format: "crash.cashout.label".localized, mult))
                            .font(.system(.callout, weight: .bold).monospacedDigit())
                        Spacer()
                        HStack(spacing: 4) {
                            Text("+\(payout)")
                                .font(.system(.callout, weight: .bold).monospacedDigit())
                            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                .frame(width: 18, height: 18)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // ── Banners + toasts ──────────────────────────────────────────

    private func cashoutOverlay(multiplier: Double, payout: Int) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                Text(String(format: "crash.banner.cashed".localized, multiplier, payout))
                    .font(.system(.subheadline, weight: .bold))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.Color.accent)
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func errorToastView(_ msg: String) -> some View {
        Text(msg)
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(hex: 0xC8442A))
            .cornerRadius(8)
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

private struct CrashRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        icon: "play.circle.fill",
                        title: "crash.rules.how.title".localized,
                        body: "crash.rules.how.body".localized,
                    )
                    section(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "crash.rules.payout.title".localized,
                        body: "crash.rules.payout.body".localized,
                    )
                    section(
                        icon: "lock.shield",
                        title: "crash.rules.fair.title".localized,
                        body: "crash.rules.fair.body".localized,
                    )
                    section(
                        icon: "exclamationmark.triangle",
                        title: "crash.rules.risk.title".localized,
                        body: "crash.rules.risk.body".localized,
                    )
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("crash.rules.title".localized)
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
