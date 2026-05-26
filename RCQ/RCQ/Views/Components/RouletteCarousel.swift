import AudioToolbox
import SwiftUI
import UIKit

/// Horizontal slot-machine carousel. Idle drift, then 3-segment slot-ease that lands on `landingKindIndex`.
/// Tap during spin to skip to reveal. Haptic + tick rate modulated by ease velocity.
struct RouletteCarousel: View {
    let kinds: [ItemKind]
    /// Atomic spin trigger AND target index in one binding. Non-nil =
    /// the caller wants the carousel to spin and land on this index in
    /// `kinds`. The carousel resets to nil immediately after kicking
    /// off the spin so the next non-nil assignment fires a new spin
    /// even if the value is the same as the previous one.
    ///
    /// Replaces the old `landingKindIndex: Int` + `spinTrigger: Int`
    /// pair. The two-binding approach raced when SwiftUI processed
    /// them in separate ticks: `startSpin()` could read a stale
    /// `landingKindIndex` and compute a spin target for the previous
    /// roll's item. Carrying the target in the trigger eliminates that
    /// race because there's exactly one signal.
    @Binding var landingTrigger: Int?
    let onSpinComplete: () -> Void

    @State private var idleAnchor: Date = Date()
    @State private var idleStartOffset: CGFloat = 0

    @State private var spinStartDate: Date? = nil
    @State private var spinStartOffset: CGFloat = 0
    @State private var spinTargetOffset: CGFloat = 0
    @State private var hasFiredCompletion: Bool = false
    @State private var pendingTick: DispatchWorkItem? = nil
    /// Snapshot of `kinds.count` captured at startSpin time. Used by
    /// `currentSpinKindIdx` to verify the actual landing kind matches
    /// the requested one, even if `kinds` mutates mid-animation.
    @State private var spinTargetIndex: Int? = nil

    // MARK: - Tunables

    private static let tileSize: CGFloat = 80
    private static let spacing: CGFloat = 20
    private static var pitch: CGFloat { tileSize + spacing }

    private static let centerScale: CGFloat = 1.18
    private static let scaleFalloff: CGFloat = 50

    private static let idleSpeed: CGFloat = 30
    private static let spinDuration: TimeInterval = 3.6
    private static let baseSpinPitches: Int = 50

    // 1104 = iOS keyboard click; reads as a slot tick.
    private static let tickSystemSoundID: SystemSoundID = 1104

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TimelineView(.animation) { ctx in
                    renderFrame(geo: geo, at: ctx.date)
                }
                centerIndicator(in: geo)
            }
        }
        .frame(height: 110)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { skipSpinIfRunning() }
        .onChange(of: landingTrigger) { newValue in
            guard let target = newValue else { return }
            startSpin(landingKindIndex: target, kindsSnapshot: kinds)
            // Reset to nil so the next assignment fires regardless of
            // whether it has the same integer value. Done on the next
            // runloop so this state mutation doesn't fight with the
            // caller's set.
            DispatchQueue.main.async { landingTrigger = nil }
        }
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
        // Key tiles by stable strip index `i` (not slot index) so visible centre tiles keep identity during drift.
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

    private func startSpin(landingKindIndex: Int, kindsSnapshot: [ItemKind]) {
        let now = Date()
        let from = currentOffset(at: now)

        let count = kindsSnapshot.count
        guard count > 0 else { return }
        // Clamp into the snapshot range — defensive against a caller
        // passing an out-of-bounds index after a kinds mutation.
        let safeLanding = ((landingKindIndex % count) + count) % count
        let approxFutureI = Int(floor((-from - Self.tileSize / 2) / Self.pitch)) + Self.baseSpinPitches
        let baseKindAtFuture = ((approxFutureI % count) + count) % count
        let alignDelta = ((safeLanding - baseKindAtFuture) % count + count) % count
        let targetI = approxFutureI + alignDelta
        let target = -CGFloat(targetI) * Self.pitch - Self.tileSize / 2

        spinStartOffset = from
        spinTargetOffset = target
        spinStartDate = now
        spinTargetIndex = safeLanding
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
        // Cap at 40ms — haptic engine collapses anything faster than ~25 Hz.
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
