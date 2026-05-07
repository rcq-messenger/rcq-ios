import SwiftUI

/// Lootbox / Open-box surface — port of IX `PullView` repainted in
/// RCQ's palette.
///
/// Layout:
///   1. Header: kicker + "View pool" link → PoolBrowserView sheet.
///   2. Edge-to-edge RouletteCarousel (negates the parent's
///      horizontal padding so it spans the full screen width).
///   3. Token availability row + "Buy more" CTA.
///   4. Big "Open box" pull button.
///   5. Recent pulls list — taps open ItemDetailSheet.
///
/// Reveal: full-screen cover with tap-bg-to-dismiss, ~110pt asset,
/// `open.wav` on appear, repeat-pull / to-inventory CTAs.
struct LootboxView: View {
    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showShop = false
    @State private var showPool = false
    @State private var detailItem: Item?
    /// Single reveal target — either an item bubble or a scroll
    /// drop. Two separate `fullScreenCover` modifiers (one for item,
    /// one for scroll) racing on the same view caused a known
    /// SwiftUI bug where the second cover would silently fail to
    /// present after the first dismissed: e.g. user pulls a scroll,
    /// hits "open another", gets an item — but the item reveal
    /// never appears because the scroll cover is still mid-dismiss
    /// when the item binding flips. Symptom from the user: "I only
    /// get gems, items don't open." Consolidating both into one
    /// binding sidesteps the race entirely.
    @State private var revealTarget: RevealTarget?
    @State private var rolling = false

    @State private var spinTrigger = 0
    @State private var landingKindIndex = 0
    @State private var pendingOutcome: PullOutcome?
    /// Spin-time order — shuffled once per cover open so the drift
    /// doesn't always show the same kind on the centre tile.
    @State private var carouselKinds: [ItemKind] = []
    /// Persistent "skip the spin" preference. When on, `rollOnce()`
    /// goes straight from the server response to the reveal cover —
    /// no carousel animation, no 3.6s wait. The toggle lives in the
    /// header next to "View pool" so power users can flip it once
    /// and burn through tokens without re-tapping each spin.
    @AppStorage("rcq.lootbox.skip_spin") private var skipSpin: Bool = false

    /// ID of the item that's been pulled but not yet revealed (carousel
    /// still spinning, or reveal up). Filtered out of the history list
    /// so the brother can't peek before the reveal lands. Mirrors IX.
    private var inFlightID: String? {
        if let outcome = pendingOutcome, case .item(let i) = outcome { return i.id }
        if case .item(let i) = revealTarget { return i.id }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        pullPanel
                        historySection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 60)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // No title — the screen's content is its own header
                // ("OPEN A BOX" kicker + "Inside" Georgia heading).
                // X close on the leading edge so the swipe-out + tap-
                // close affordances live on the same side; bare
                // `xmark` glyph because the system toolbar already
                // renders the touch target.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
                // Pool browser moved out of the body header into the
                // trailing toolbar slot — same vertical row as the
                // close X, frees up the kicker line for the skip
                // toggle without crowding.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPool = true } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
        }
        .fullScreenCover(item: $revealTarget) { target in
            switch target {
            case .item(let item):
                RevealOverlay(
                    item: item,
                    catalog: items.catalog,
                    canRepeat: items.wallet.tokens > 0,
                    onDismiss: { revealTarget = nil },
                    onCloseToInventory: {
                        revealTarget = nil
                        dismiss()
                    },
                    onRepeat: { repeatPull() },
                )
            case .scroll(let count):
                ScrollRevealOverlay(
                    count: count,
                    canRepeat: items.wallet.tokens > 0,
                    onDismiss: { revealTarget = nil },
                    onCloseToInventory: {
                        revealTarget = nil
                        dismiss()
                    },
                    onRepeat: { repeatPull() },
                )
            }
        }
        .sheet(isPresented: $showShop) {
            BuyTokensSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPool) {
            PoolBrowserView()
                .presentationDetents([.large])
        }
        .sheet(item: $detailItem) { item in
            ItemDetailSheet(item: item)
                .presentationDetents([.large])
        }
        .task {
            // Hard reset of the per-view spin / reveal state on every
            // (re-)open. Without this, a previous session that got
            // wedged with `rolling = true` (e.g. crash mid-await,
            // backgrounding during a request) would render the Open
            // box button permanently disabled — re-entering the cover
            // wouldn't help because @State survives re-presentation
            // when the parent owns the cover binding.
            rolling = false
            pendingOutcome = nil
            if items.catalog == nil { await items.refreshCatalog() }
            await items.refreshInventory()
            if carouselKinds.isEmpty, let kinds = items.catalog?.kinds, !kinds.isEmpty {
                carouselKinds = kinds.shuffled()
            }
        }
    }

    // MARK: - Header (kicker + pool link)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("lootbox.kicker".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .tracking(2.5)
                Spacer()
                Button { skipSpin.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: skipSpin ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                        Text("lootbox.skip_spin".localized)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Theme.Color.accent)
                }
                .buttonStyle(.plain)
            }
            Text("lootbox.heading".localized)
                .font(.custom("Georgia", size: 26))
                .foregroundColor(Theme.Color.textPrimary)
            Text("lootbox.subhead".localized)
                .font(.callout.italic())
                .foregroundColor(Theme.Color.textSecondary)
                .lineSpacing(2)
        }
    }

    // MARK: - Pull panel

    private var pullPanel: some View {
        VStack(spacing: 14) {
            // Edge-to-edge carousel — negate the parent's horizontal
            // padding so it bleeds to the screen edges. Same trick as
            // IX `PullView`'s `padding(.horizontal, -Spacing.inner)`.
            if !carouselKinds.isEmpty {
                RouletteCarousel(
                    kinds: carouselKinds,
                    landingKindIndex: landingKindIndex,
                    spinTrigger: $spinTrigger,
                    onSpinComplete: { revealPending() },
                )
                .frame(height: 132)
                .padding(.horizontal, -18)
            } else {
                Color.clear.frame(height: 132)
            }

            availabilityRow

            VStack(spacing: 4) {
                Button {
                    Task { await rollOnce() }
                } label: {
                    let canAfford = items.wallet.tokens >= (items.catalog?.pullCost ?? 2)
                    Text((rolling ? "lootbox.button.pulling" : "lootbox.button.pull").localized)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(canAfford && !rolling
                                    ? Theme.Color.accent
                                    : Theme.Color.divider)
                        .cornerRadius(8)
                }
                .disabled(items.wallet.tokens < (items.catalog?.pullCost ?? 2) || rolling)
                // Per-open price caption beneath the CTA — small
                // mono digits next to the coin gif so the user sees
                // the spend without it eating CTA real estate.
                HStack(spacing: 4) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 14, height: 14)
                    Text(String(format: "lootbox.cost.per_open".localized, items.catalog?.pullCost ?? 2))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                    Spacer()
                }
                .padding(.leading, 4)
            }
        }
    }

    private var availabilityRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("lootbox.remaining".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .tracking(2)
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 16, height: 16)
                Text("×\(items.wallet.tokens)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
            }
            Spacer(minLength: 4)
            Button {
                showShop = true
            } label: {
                Text("lootbox.buy_more".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .tracking(2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("lootbox.recent".localized)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .tracking(2)
            if items.items.isEmpty {
                Text("lootbox.recent.empty".localized)
                    .font(.callout.italic())
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.vertical, 6)
            } else {
                let recent = Array(
                    items.items
                        .filter { $0.id != inFlightID }
                        .prefix(12),
                )
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            detailItem = item
                        } label: {
                            historyRow(item)
                        }
                        .buttonStyle(.plain)
                        if idx < recent.count - 1 {
                            Divider()
                                .background(Theme.Color.divider)
                                .padding(.leading, 50)
                        }
                    }
                }
                .background(Theme.Color.bgSecondary)
                .cornerRadius(8)
            }
        }
    }

    /// Compact 36pt-thumb row — same shape as IX historyRow.
    private func historyRow(_ item: Item) -> some View {
        HStack(spacing: 10) {
            ItemCard(item: item)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(ItemDisplay.name(for: item.kindID))
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.rarity.label.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(item.rarity.color)
                        .tracking(1.5)
                    if let cap = items.catalog?.kind(by: item.kindID)?.limit,
                       let mint = item.mintNumber {
                        Text("·").foregroundColor(Theme.Color.textMono)
                        Text(String(format: "item.mint.of".localized, mint, cap))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundColor(Theme.Color.textMono)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Roll

    @MainActor
    private func rollOnce() async {
        let cost = items.catalog?.pullCost ?? 2
        guard items.wallet.tokens >= cost, !rolling else { return }
        guard !carouselKinds.isEmpty else { return }
        rolling = true
        let outcome = await items.openPull()
        switch outcome {
        case .item(let item):
            // Land the carousel on the rolled kind — the spin
            // promise is "ends on the kind you actually got".
            if let idx = carouselKinds.firstIndex(where: { $0.id == item.kindID }) {
                landingKindIndex = idx
            } else if let kind = items.catalog?.kind(by: item.kindID) {
                // Pulled kind isn't in the shuffled local strip yet —
                // can happen if the catalog grew between session
                // start and the pull (server redeploy). Append the
                // missing kind so the carousel CAN land on it
                // instead of falling back to a random tile that
                // doesn't match the reveal.
                carouselKinds.append(kind)
                landingKindIndex = carouselKinds.count - 1
            } else {
                // True orphan: server returned a kind we don't know
                // at all. Random tile keeps the spin from stalling
                // — the reveal sheet will still show the correct
                // item via the catalog-by-id lookup.
                landingKindIndex = Int.random(in: 0..<carouselKinds.count)
            }
            pendingOutcome = .item(item)
            // Power-user shortcut: skip the 3.6s spin and go straight
            // to the reveal. We hop one runloop tick before flipping
            // `revealItem` so SwiftUI commits the wallet-update +
            // rolling-flag state changes BEFORE presenting the
            // fullScreenCover. Without this hop, all three mutations
            // collapse into the same render cycle and the cover
            // sometimes silently fails to present (which is what made
            // the lootbox look "stuck": tokens spent server-side, no
            // reveal shown, button disabled because rolling stuck
            // until the next iteration cleared it).
            if skipSpin {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    revealPending()
                }
            } else {
                spinTrigger += 1
            }
        case .scroll(let count):
            // No spin for scrolls — the scroll reveal lands directly,
            // the carousel stays idle. The user opted in to a token;
            // they shouldn't have to wait 3.6s extra for a scroll bundle.
            rolling = false
            pendingOutcome = nil
            revealTarget = .scroll(count: count)
        case .none:
            rolling = false
        }
    }

    @MainActor
    private func revealPending() {
        rolling = false
        guard let outcome = pendingOutcome else { return }
        pendingOutcome = nil
        switch outcome {
        case .item(let item): revealTarget = .item(item)
        case .scroll(let count): revealTarget = .scroll(count: count)
        }
    }

    @MainActor
    private func repeatPull() {
        revealTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            Task { await rollOnce() }
        }
    }
}

/// Single discriminator for the lootbox reveal cover. Identifiable so
/// `fullScreenCover(item:)` can latch onto it; `id` deliberately
/// includes the case marker so flipping from a scroll bundle to an
/// item drop forces a fresh present (rather than reusing the cover
/// instance, which would render the wrong overlay).
enum RevealTarget: Identifiable {
    case item(Item)
    case scroll(count: Int)

    var id: String {
        switch self {
        case .item(let it):     return "item-\(it.id)"
        case .scroll(let n):    return "scroll-\(n)"
        }
    }
}

// MARK: - Reveal overlays

private struct RevealOverlay: View {
    let item: Item
    let catalog: ItemCatalog?
    let canRepeat: Bool
    let onDismiss: () -> Void
    let onCloseToInventory: () -> Void
    let onRepeat: () -> Void

    @State private var appeared = false

    private var kind: ItemKind? { catalog?.kind(by: item.kindID) }
    private var displayValue: Int {
        guard let catalog else { return item.baseEssence }
        return item.showcaseValue(catalog: catalog)
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 18) {
                Spacer()
                Text("lootbox.reveal.you_pulled".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .tracking(3)
                if let kind {
                    if kind.section == .voices {
                        // Voice drops auto-play their sound on reveal
                        // so the user hears what they pulled. Tap the
                        // glyph to replay before dismissing.
                        Button {
                            SoundService.shared.preview(kindID: item.kindID)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(item.rarity.color.opacity(0.15))
                                    .frame(width: 110, height: 110)
                                Image(systemName: "music.note")
                                    .font(.system(size: 50, weight: .semibold))
                                    .foregroundColor(item.rarity.color)
                            }
                            .scaleEffect(appeared ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // Slight delay so the reveal-overlay
                            // entrance animation completes before the
                            // sound fires; otherwise the chime feels
                            // disconnected from the visual pop.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                SoundService.shared.preview(kindID: item.kindID)
                            }
                        }
                    } else {
                        ItemAssetImage(
                            bundleSubdir: "Items",
                            filename: stem(kind),
                            ext: ext(kind),
                        )
                        .frame(width: 110, height: 110)
                        .scaleEffect(appeared ? 1 : 0.6)
                    }
                }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(item.rarity.color).frame(width: 7, height: 7)
                        Text(item.rarity.label.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(item.rarity.color)
                            .tracking(2.5)
                    }
                    Text(ItemDisplay.name(for: item.kindID))
                        .font(.custom("Georgia", size: 24))
                        .foregroundColor(Theme.Color.textPrimary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        Text("lootbox.reveal.essence".localized)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                            .tracking(2.5)
                        Text("\(displayValue)")
                            .font(.custom("Georgia", size: 18))
                            .foregroundColor(Theme.Color.accent)
                        if let pur = item.purityTier {
                            Text("·").foregroundColor(Theme.Color.textMono)
                            Text(pur.uppercased())
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(item.rarity.color)
                                .tracking(2)
                        }
                    }
                    if let cap = kind?.limit, let mint = item.mintNumber {
                        Text(String(format: "item.mint.of".localized, mint, cap))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
                .opacity(appeared ? 1 : 0)
                Spacer()
                ctaStack
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onAppear {
            // The lootbox-open SFX waits for the reveal so it doesn't
            // tip off the outcome during the carousel spin — the
            // tick stream owns the spin's soundtrack.
            SoundService.shared.play(.lootboxOpen)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private var ctaStack: some View {
        VStack(spacing: 10) {
            if canRepeat {
                Button(action: onRepeat) {
                    Text("lootbox.reveal.repeat".localized)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Theme.Color.accent)
                        .cornerRadius(8)
                }
            }
            Button(action: onCloseToInventory) {
                Text("lootbox.reveal.to_inventory".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.Color.accent, lineWidth: 1))
            }
        }
    }

    private func stem(_ k: ItemKind) -> String {
        let basename = (k.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private func ext(_ k: ItemKind) -> String {
        let basename = (k.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}

private struct ScrollRevealOverlay: View {
    let count: Int
    let canRepeat: Bool
    let onDismiss: () -> Void
    let onCloseToInventory: () -> Void
    let onRepeat: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 18) {
                Spacer()
                HStack(spacing: 8) {
                    Text("lootbox.reveal.you_pulled".localized)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                        .tracking(3)
                    Text("×\(count)")
                        .font(.custom("Georgia-Bold", size: 14))
                        .foregroundColor(Theme.Color.accent)
                }
                ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                    .frame(width: 90, height: 90)
                    .scaleEffect(appeared ? 1 : 0.6)
                Text("lootbox.reveal.gems".localized)
                    .font(.custom("Georgia", size: 24))
                    .foregroundColor(Theme.Color.textPrimary)
                    .opacity(appeared ? 1 : 0)
                Spacer()
                VStack(spacing: 10) {
                    if canRepeat {
                        Button(action: onRepeat) {
                            Text("lootbox.reveal.repeat".localized)
                                .font(.system(.body, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Theme.Color.accent)
                                .cornerRadius(8)
                        }
                    }
                    Button(action: onCloseToInventory) {
                        Text("lootbox.reveal.to_inventory".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.Color.accent, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onAppear {
            SoundService.shared.play(.lootboxOpen)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}
