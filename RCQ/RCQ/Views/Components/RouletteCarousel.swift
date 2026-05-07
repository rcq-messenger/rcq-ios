import AudioToolbox
import SwiftUI
import UIKit

/// Horizontal slot-machine carousel — port of IX's RouletteCarousel
/// with RCQ palette + asset rendering.
///
/// Rendering is windowed: only the ~9 tiles visible in the viewport
/// are placed via `.position(x:y:)` each frame. Two phases:
///   - **Idle** — continuous slow leftward drift (~30 pt/s).
///   - **Spinning** — 3-segment slot-ease (ease-in / cruise /
///     ease-out) totalling ~3.6s, deterministically lands on
///     `landingKindIndex`.
///
/// Per-tile haptic + system "Tock" ticks are fired during the spin,
/// rate-modulated by the live ease velocity so it slows toward the
/// end like a real slot machine. Tap anywhere on the carousel during
/// a spin to skip straight to the reveal.
struct RouletteCarousel: View {
    let kinds: [ItemKind]
    let landingKindIndex: Int
    @Binding var spinTrigger: Int
    let onSpinComplete: () -> Void

    @State private var idleAnchor: Date = Date()
    @State private var idleStartOffset: CGFloat = 0

    @State private var spinStartDate: Date? = nil
    @State private var spinStartOffset: CGFloat = 0
    @State private var spinTargetOffset: CGFloat = 0
    @State private var hasFiredCompletion: Bool = false
    @State private var pendingTick: DispatchWorkItem? = nil

    // MARK: - Tunables

    private static let tileSize: CGFloat = 80
    private static let spacing: CGFloat = 20
    private static var pitch: CGFloat { tileSize + spacing }

    private static let centerScale: CGFloat = 1.18
    private static let scaleFalloff: CGFloat = 50

    private static let idleSpeed: CGFloat = 30
    private static let spinDuration: TimeInterval = 3.6
    private static let baseSpinPitches: Int = 50

    /// iOS keyboard click — short, percussive, reads as a slot click
    /// without us bundling a custom audio file.
    private static let tickSystemSoundID: SystemSoundID = 1104

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TimelineView(.animation) { ctx in
                    renderFrame(geo: geo, at: ctx.date)
                }
                // Centre indicator: top + bottom triangles framing the
                // tile that's currently centred. Without these the
                // 1.18× scale alone wasn't loud enough — users
                // reported the spin "didn't end on" their prize even
                // though the math is exact. The carets make the
                // landing tile unambiguous at a glance.
                centerIndicator(in: geo)
            }
        }
        .frame(height: 110)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { skipSpinIfRunning() }
        .onChange(of: spinTrigger) { _ in startSpin() }
        .onDisappear { pendingTick?.cancel() }
    }

    private func centerIndicator(in geo: GeometryProxy) -> some View {
        VStack {
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(Theme.Color.accent)
                .rotationEffect(.degrees(180))
            Spacer()
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(Theme.Color.accent)
        }
        .padding(.vertical, 6)
        .frame(width: Self.tileSize * Self.centerScale, height: geo.size.height)
        .position(x: geo.size.width / 2, y: geo.size.height / 2)
        .allowsHitTesting(false)
    }

    private func renderFrame(geo: GeometryProxy, at now: Date) -> some View {
        let offset = currentOffset(at: now)
        let centerX = geo.size.width / 2
        let centerY = geo.size.height / 2

        let centerIndex = Int(floor((-offset) / Self.pitch))
        let halfWindow = 4
        // Keying tiles by their stable `i` (position along the strip)
        // instead of the visible-slot index is what makes the idle
        // drift look like motion rather than an in-place asset swap.
        // With slot-keyed tiles, when `centerIndex` ticks from 5→6
        // the SwiftUI view at slot=4 kept its identity but its kind
        // changed (i flipped 5→6) — visually the tile's image
        // mutated in place. Keying by `i` rebuilds only the
        // newcomer/leaver tiles at the edges; the visible centre
        // tiles keep their identity and just animate position.
        let visibleIs = (centerIndex - halfWindow)...(centerIndex + halfWindow)

        return ZStack(alignment: .topLeading) {
            ForEach(Array(visibleIs), id: \.self) { i in
                tileAt(
                    i: i,
                    offset: offset,
                    centerX: centerX,
                    centerY: centerY,
                )
            }
        }
    }

    private func tileAt(
        i: Int,
        offset: CGFloat,
        centerX: CGFloat,
        centerY: CGFloat,
    ) -> some View {
        let kindIdx = ((i % kinds.count) + kinds.count) % kinds.count
        let kind = kinds[kindIdx]

        let tileX = CGFloat(i) * Self.pitch + Self.tileSize / 2 + offset + centerX
        let dist = abs(tileX - centerX)
        let scale = 1 + (Self.centerScale - 1) * max(0, 1 - dist / Self.scaleFalloff)
        let opacity = 0.55 + 0.45 * max(0, 1 - dist / 180)

        return tile(kind: kind)
            .scaleEffect(scale, anchor: .center)
            .opacity(opacity)
            .position(x: tileX, y: centerY)
    }

    private func tile(kind: ItemKind) -> some View {
        ZStack {
            Rectangle().fill(Theme.Color.bgSecondary)
            if kind.section == .voices {
                // Voice packs ship as audio — render the music note
                // glyph tinted by rarity instead of the placeholder
                // cube the .mp3 lookup would fall back to.
                Image(systemName: "music.note")
                    .font(.system(size: Self.tileSize * 0.45, weight: .semibold))
                    .foregroundColor(kind.rarity.color)
            } else {
                ItemAssetImage(
                    bundleSubdir: "Items",
                    filename: assetStem(for: kind),
                    ext: assetExt(for: kind),
                )
                .padding(Self.tileSize * 0.16)
            }
        }
        .frame(width: Self.tileSize, height: Self.tileSize)
    }

    private func assetStem(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private func assetExt(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }

    // MARK: - Offset state machine

    private func currentOffset(at now: Date) -> CGFloat {
        if let spinStart = spinStartDate {
            let elapsed = now.timeIntervalSince(spinStart)
            if elapsed >= Self.spinDuration {
                return spinTargetOffset
            }
            let t = elapsed / Self.spinDuration
            let eased = slotEase(t)
            return spinStartOffset + (spinTargetOffset - spinStartOffset) * CGFloat(eased)
        } else {
            let elapsed = now.timeIntervalSince(idleAnchor)
            return idleStartOffset - CGFloat(elapsed) * Self.idleSpeed
        }
    }

    /// Slot-machine 3-segment easing — quadratic ramp, linear cruise,
    /// cubic deceleration.
    private func slotEase(_ t: Double) -> Double {
        if t < 0.15 {
            let p = t / 0.15
            return p * p * 0.06
        } else if t < 0.7 {
            let p = (t - 0.15) / 0.55
            return 0.06 + p * 0.69
        } else {
            let p = (t - 0.7) / 0.3
            return 0.75 + (1 - pow(1 - p, 3)) * 0.25
        }
    }

    /// Velocity model derivative — feeds the tick scheduler so ticks
    /// space out as the carousel decelerates.
    private func slotEaseDerivative(_ t: Double) -> Double {
        if t < 0.15 {
            return (2 * 0.06 / (0.15 * 0.15)) * t
        } else if t < 0.7 {
            return 0.69 / 0.55
        } else {
            let p = (t - 0.7) / 0.3
            return 3 * (1 - p) * (1 - p) * 0.25 / 0.3
        }
    }

    // MARK: - Spin trigger

    private func startSpin() {
        let now = Date()
        let from = currentOffset(at: now)

        let count = kinds.count
        guard count > 0 else { return }
        let approxFutureI = Int(floor((-from - Self.tileSize / 2) / Self.pitch)) + Self.baseSpinPitches
        let baseKindAtFuture = ((approxFutureI % count) + count) % count
        let alignDelta = ((landingKindIndex - baseKindAtFuture) % count + count) % count
        let targetI = approxFutureI + alignDelta
        let target = -CGFloat(targetI) * Self.pitch - Self.tileSize / 2

        spinStartOffset = from
        spinTargetOffset = target
        spinStartDate = now
        hasFiredCompletion = false

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spinDuration) {
            fireCompletion()
        }
        scheduleNextTick()
    }

    private func fireCompletion() {
        guard !hasFiredCompletion else { return }
        hasFiredCompletion = true
        pendingTick?.cancel()
        pendingTick = nil

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        idleStartOffset = spinTargetOffset
        idleAnchor = Date()
        spinStartDate = nil
        onSpinComplete()
    }

    private func skipSpinIfRunning() {
        guard spinStartDate != nil, !hasFiredCompletion else { return }
        fireCompletion()
    }

    // MARK: - Tick scheduling

    private func scheduleNextTick() {
        pendingTick?.cancel()

        guard let start = spinStartDate else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        if elapsed >= Self.spinDuration { return }

        let normalized = elapsed / Self.spinDuration
        let totalDistance = abs(spinTargetOffset - spinStartOffset)
        let velocity = totalDistance / Self.spinDuration * slotEaseDerivative(normalized)
        let raw = Self.pitch / max(velocity, 1)
        // Cap at 40ms — the iOS haptic engine collapses anything
        // faster than ~25 Hz, and at peak ease velocity the raw
        // interval would push past 60 Hz.
        let interval = max(0.04, min(0.6, raw))

        let item = DispatchWorkItem {
            UISelectionFeedbackGenerator().selectionChanged()
            AudioServicesPlaySystemSound(Self.tickSystemSoundID)
            scheduleNextTick()
        }
        pendingTick = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }
}
