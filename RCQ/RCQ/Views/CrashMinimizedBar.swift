import SwiftUI

/// Floating Crash mini-bubble. Hosted by `GameMinisOverlayHost` inside a `FloatingMini`.
/// X-close on leading edge so it remains the peek-tab when docked off-screen right.
struct CrashMiniBubble: View {
    @StateObject private var svc = CrashService.shared

    private static let presets: [Int] = [10, 25, 50, 100, 250, 500]
    @State private var betIndex: Int = 1

    var isDocked: Bool = false
    var openFull: () -> Void = {}

    var body: some View {
        Group {
            if isDocked {
                dockedTab
            } else {
                fullBubble
            }
        }
        .animation(.easeInOut(duration: 0.25), value: svc.phase)
        .onLongPressGesture(minimumDuration: 0.35) { openFull() }
        // Double-tap is the primary expand-to-full-game gesture per
        // user request; long-press kept as a fallback.
        .onTapGesture(count: 2) { openFull() }
    }

    @ViewBuilder
    private var fullBubble: some View {
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

            actionButton
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        // Fill outer FloatingMini frame — keeps bubble dimensions stable across phase changes.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(backgroundTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var dockedTab: some View {
        ZStack {
            Capsule()
                .fill(backgroundTint)
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            // During the running phase, replace the rocket with the
            // live multiplier — keeps the docked tab informative.
            switch svc.phase {
            case .running:
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    let m = svc.projectedMultiplier(at: ctx.date)
                    Text(String(format: "%.1f×", m))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            default:
                Image(systemName: "rocket.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }

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
                if svc.myBetAmount != nil && svc.myCashoutMultiplier == nil {
                    pillButton(label: "crash.mini.cashout_cta".localized, enabled: true) {
                        Task { _ = await svc.cashout() }
                    }
                }
            case .crashed:
                EmptyView()
            }
        }
    }

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
