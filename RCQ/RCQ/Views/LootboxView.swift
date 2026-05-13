import SwiftUI

/// Lootbox surface: roulette carousel, pull button, recent history, fullscreen reveal.
struct LootboxView: View {
    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showShop = false
    @State private var showPool = false
    @State private var detailItem: Item?
    // One binding for both item + scroll reveals; two fullScreenCovers race on dismiss.
    @State private var revealTarget: RevealTarget?
    @State private var rolling = false

    @State private var spinTrigger = 0
    @State private var landingKindIndex = 0
    @State private var pendingOutcome: PullOutcome?
    @State private var carouselKinds: [ItemKind] = []
    @AppStorage("rcq.lootbox.skip_spin") private var skipSpin: Bool = false

    // ID of an item pulled but not yet revealed; hidden from history until reveal lands.
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
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
            // Reset spin/reveal state; @State survives re-presentation when parent owns the binding.
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
            // Negative inset bleeds the carousel past the parent's horizontal padding.
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
            if let idx = carouselKinds.firstIndex(where: { $0.id == item.kindID }) {
                landingKindIndex = idx
            } else if let kind = items.catalog?.kind(by: item.kindID) {
                // Catalog grew since session start; append so the spin can land on the new kind.
                carouselKinds.append(kind)
                landingKindIndex = carouselKinds.count - 1
            } else {
                landingKindIndex = Int.random(in: 0..<carouselKinds.count)
            }
            pendingOutcome = .item(item)
            // Hop one runloop tick before presenting the cover so wallet/rolling commits first.
            if skipSpin {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    revealPending()
                }
            } else {
                spinTrigger += 1
            }
        case .scroll(let count):
            rolling = false
            pendingOutcome = nil
            SoundService.shared.play(.lootboxOpen)
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
        // Play the reveal sound HERE rather than in the overlay's
        // .onAppear. With skipSpin + rapid Repeat taps, fullScreenCover
        // sometimes coalesces nil→item back-to-back transitions into
        // a single presentation cycle and .onAppear doesn't refire,
        // dropping the sound. Firing it at state-change time guarantees
        // one play per reveal regardless of cover lifecycle.
        SoundService.shared.play(.lootboxOpen)
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

/// Discriminator for the lootbox reveal cover; `id` includes the case marker.
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
                            // Delay sync the chime to the entrance animation.
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
            // Sound now plays from LootboxView.revealPending() — keeping
            // it here too would double-fire on the path that *does* hit
            // onAppear (normal slow spin).
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
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}
