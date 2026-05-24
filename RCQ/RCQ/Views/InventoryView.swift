import SwiftUI

/// Inventory screen — wallet + sectioned tile grid with select-mode bulk
/// disassemble. Tile long-press enters select mode.
struct InventoryView: View {
    @StateObject private var items = ItemsService.shared
    @StateObject private var trades = TradesService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showShop = false
    @State private var showLootbox = false
    @State private var showTrades = false
    @State private var showGames = false
    @State private var showMarket = false
    @State private var showMemorial = false
    @State private var showOwnedUINs = false
    @State private var showLeaderboard = false
    @State private var detailItem: Item?
    @State private var lastError: String?

    @State private var rarityFilter: ItemRarity?
    @State private var levelFilter: LevelBucket?

    /// Temper-level bucket for the second filter row. Splits the 0-9
    /// range into actionable groups so the chip strip stays short.
    enum LevelBucket: String, CaseIterable, Hashable {
        case base       // +0
        case low        // +1..+3
        case mid        // +4..+6
        case high       // +7..+9

        var label: String {
            switch self {
            case .base: return "+0"
            case .low:  return "+1-3"
            case .mid:  return "+4-6"
            case .high: return "+7-9"
            }
        }
        func contains(_ level: Int) -> Bool {
            switch self {
            case .base: return level == 0
            case .low:  return (1...3).contains(level)
            case .mid:  return (4...6).contains(level)
            case .high: return (7...9).contains(level)
            }
        }
    }
    @State private var selectMode: Bool = false
    @State private var selected: Set<String> = []
    /// Smileys + voices collapsed by default — pets are the headline
    /// section, the others are noise unless the user explicitly drills in.
    @State private var collapsedSections: Set<ItemSection> = [.smileys, .voices]
    @State private var confirmingBulk: Bool = false
    @State private var bulkResultBanner: DisassembleYield? = nil
    @State private var loading: Bool = true
    // Suppresses the post-longpress finger-up tap that would otherwise
    // immediately deselect the just-selected tile.
    @State private var longPressedJustNow: Set<String> = []

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    private var filteredItems: [Item] {
        items.items.filter { item in
            if let r = rarityFilter, item.rarity != r { return false }
            if let l = levelFilter, !l.contains(item.level) { return false }
            return true
        }
    }

    private func runRefresh(initial: Bool) async {
        if initial || items.items.isEmpty {
            loading = true
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { loading = false }
        }
        if items.catalog == nil { await items.refreshCatalog() }
        await items.refreshInventory()
        await trades.refreshAll()
        watchdog.cancel()
        loading = false
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.Color.bgPrimary.ignoresSafeArea()
                    .onAppear { SmokeTracker.shared.tick(.openInventory) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        walletPanel
                            .padding(.horizontal, 16)
                        Divider()
                            .background(Theme.Color.divider)
                            .padding(.horizontal, 16)
                        filterChips
                        Group {
                            if loading && items.items.isEmpty {
                                ProgressView()
                                    .tint(Theme.Color.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            } else if items.items.isEmpty {
                                emptyState
                            } else {
                                sectionsGrid
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, selectMode ? 100 : 40)
                }
                if selectMode {
                    selectActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let yield = bulkResultBanner {
                    successToast(yield: yield)
                }
                if loading {
                    syncingPill
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: loading)
            // Animate ForEach diffs in the grid so dismantled items
            // fade out + reflow into their neighbours instead of
            // popping. Watches the inventory size (no per-id hashing
            // each body pass) — fires once per add/remove batch.
            .animation(.easeInOut(duration: 0.3), value: items.items.count)
            // Banner enter/exit gets its own animation context so the
            // top yield toast slides + fades smoothly in BOTH
            // directions, even when the clearing happens from an
            // asyncAfter outside a withAnimation block.
            .animation(.easeInOut(duration: 0.4), value: bulkResultBanner)
            .navigationTitle(selectMode ? "common.confirm".localized : "inventory.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectMode ? "common.done".localized : "common.close".localized) {
                        if selectMode {
                            exitSelectMode()
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(Theme.Color.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await items.setInventoryPublic(!items.inventoryPublic) }
                        } label: {
                            Label(
                                items.inventoryPublic
                                    ? "inventory.menu.hide".localized
                                    : "inventory.menu.show".localized,
                                systemImage: items.inventoryPublic ? "eye.slash" : "eye",
                            )
                        }
                        Button {
                            showMemorial = true
                        } label: {
                            Label(
                                "pet_hunt.memorial.title".localized,
                                systemImage: "leaf.fill"
                            )
                        }
                        Button {
                            showOwnedUINs = true
                        } label: {
                            Label(
                                "uin_auction.owned.title".localized,
                                systemImage: "number.circle.fill"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(Theme.Color.accent)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button { showGames = true } label: {
                        Label("inventory.menu.games".localized,
                              systemImage: "gamecontroller.fill")
                    }
                    Button { showMarket = true } label: {
                        Label("inventory.menu.market".localized,
                              systemImage: "cart.fill")
                    }
                    Button { showTrades = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Label("inventory.menu.trades".localized,
                                  systemImage: "arrow.left.arrow.right")
                            if trades.pendingIncomingCount > 0 {
                                Text("\(trades.pendingIncomingCount)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .offset(x: 6, y: -8)
                            }
                        }
                    }
                    Button { showLeaderboard = true } label: {
                        Label("inventory.menu.leaderboard".localized,
                              systemImage: "trophy.fill")
                    }
                    Spacer()
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
            .task {
                await runRefresh(initial: true)
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task { await runRefresh(initial: false) }
                }
            }
            .fullScreenCover(isPresented: $showLootbox) {
                LootboxView()
            }
            .sheet(isPresented: $showShop) {
                BuyTokensSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showTrades) {
                TradesListView()
            }
            .sheet(isPresented: $showMarket) {
                MarketView()
            }
            .fullScreenCover(isPresented: $showGames) {
                GamesView()
            }
            .sheet(isPresented: $showMemorial) {
                PetMemorialFromInventorySheet()
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showOwnedUINs) {
                OwnedUINsSheet()
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showLeaderboard) {
                ReputationLeaderboardView()
                    .presentationDetents([.large])
            }
            .sheet(item: $detailItem) { item in
                ItemDetailSheet(item: item)
                    .presentationDetents([.large])
            }
            .confirmationDialog(
                disassembleConfirmTitle,
                isPresented: $confirmingBulk,
                titleVisibility: .visible,
            ) {
                Button(
                    String(format: "inventory.button.disassemble".localized, selected.count),
                    role: .destructive
                ) {
                    Task { await commitBulkDisassemble() }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                let yield = bulkYieldPreview
                Text(String(
                    format: "inventory.confirm.yield".localized,
                    yield.scrolls, yield.tokens
                ))
            }
        }
    }

    private var disassembleConfirmTitle: String {
        String(
            format: (selected.count == 1
                ? "inventory.confirm.title_one"
                : "inventory.confirm.title_many").localized,
            selected.count
        )
    }

    private var bulkYieldPreview: (scrolls: Int, tokens: Int) {
        let chosen = items.items.filter { selected.contains($0.id) }
        var scrolls = 0
        var tokens = 0
        for it in chosen {
            scrolls += DisassembleTables.scrollYield(rarity: it.rarity, level: it.level)
            tokens += DisassembleTables.tokenYield(rarity: it.rarity, level: it.level)
        }
        return (scrolls, tokens)
    }

    // MARK: - Trailing toolbar menu

    @ViewBuilder
    private var inventoryMenu: some View {
        Menu {
            Button {
                showGames = true
            } label: {
                Label("inventory.menu.games".localized, systemImage: "gamecontroller.fill")
            }
            Button {
                showTrades = true
            } label: {
                let label = trades.pendingIncomingCount > 0
                    ? String(format: "inventory.menu.trades.with_count".localized, trades.pendingIncomingCount)
                    : "inventory.menu.trades".localized
                Label(label, systemImage: "arrow.left.arrow.right")
            }
            Divider()
            Button {
                Task { await items.setInventoryPublic(!items.inventoryPublic) }
            } label: {
                Label(
                    items.inventoryPublic
                        ? "inventory.menu.hide".localized
                        : "inventory.menu.show".localized,
                    systemImage: items.inventoryPublic ? "eye.slash" : "eye",
                )
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .foregroundColor(Theme.Color.accent)
                if trades.pendingIncomingCount > 0 {
                    Text("\(trades.pendingIncomingCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        // Explicit opacity(1) prevents toolbar tint bleed.
                        .background(Color.red.opacity(1))
                        .clipShape(Capsule())
                        .offset(x: 4, y: -6)
                        .zIndex(1)
                }
            }
        }
    }

    // MARK: - Wallet panel

    private var walletPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                walletReadout(image: "coin", isAnimated: true,
                              value: items.wallet.tokens, label: "inventory.tokens".localized)
                walletReadout(image: "gem", isAnimated: true,
                              value: items.wallet.scrolls, label: "inventory.gems".localized)
            }
            HStack(spacing: 10) {
                Button {
                    showLootbox = true
                } label: {
                    let canAfford = items.wallet.tokens >= (items.catalog?.pullCost ?? 2)
                    Text("inventory.button.open".localized)
                        .font(Theme.Font.nickname)
                        .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(canAfford ? Theme.Color.accent : Theme.Color.divider)
                    .cornerRadius(8)
                }
                .disabled(items.wallet.tokens < (items.catalog?.pullCost ?? 2))
                Button {
                    showShop = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("inventory.button.buy_more".localized).font(Theme.Font.nickname)
                    }
                    .foregroundColor(Theme.Color.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.Color.accent, lineWidth: 1))
                }
            }
        }
    }

    private func walletReadout(image: String, isAnimated: Bool, value: Int, label: String) -> some View {
        HStack(spacing: 10) {
            ItemAssetImage(bundleSubdir: "Items", filename: image,
                           ext: isAnimated ? "gif" : "png")
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(label)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filters

    private var filterChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(label: "rarity.all".localized.uppercased(), color: Theme.Color.accent, isOn: rarityFilter == nil) {
                        rarityFilter = nil
                    }
                    ForEach(ItemRarity.allCases.sorted { $0.rollWeight > $1.rollWeight }, id: \.self) { r in
                        chip(label: r.label.uppercased(), color: r.color, isOn: rarityFilter == r) {
                            rarityFilter = (rarityFilter == r) ? nil : r
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(label: "inventory.filter.level_all".localized.uppercased(), color: Theme.Color.accent, isOn: levelFilter == nil) {
                        levelFilter = nil
                    }
                    ForEach(LevelBucket.allCases, id: \.self) { b in
                        chip(label: b.label, color: Theme.Color.textMono, isOn: levelFilter == b) {
                            levelFilter = (levelFilter == b) ? nil : b
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private func chip(label: String, color: Color, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(color.opacity(isOn ? 1.0 : 0.45))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty / sections

    private var syncingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.Color.accent)
            Text("inventory.syncing".localized)
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Theme.Color.divider.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text("inventory.empty.title".localized)
                .font(Theme.Font.nickname)
                .foregroundColor(Theme.Color.textPrimary)
            Text("inventory.empty.body".localized)
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showLootbox = true
            } label: {
                Text("inventory.empty.cta".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: 240)
                    .padding(.vertical, 12)
                    .background(Theme.Color.accent)
                    .cornerRadius(8)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var sectionsGrid: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sortedSections, id: \.self) { section in
                let bucket = filteredItems
                    .filter { itemSection($0) == section }
                    .sorted { $0.rarity.rollWeight < $1.rarity.rollWeight }
                if !bucket.isEmpty {
                    let isCollapsed = collapsedSections.contains(section)
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if isCollapsed {
                                    collapsedSections.remove(section)
                                } else {
                                    collapsedSections.insert(section)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(section.displayName)
                                    .font(Theme.Font.statusLabel)
                                    .foregroundColor(Theme.Color.textSecondary)
                                    .textCase(.uppercase)
                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Theme.Color.textSecondary)
                                Text("(\(bucket.count))")
                                    .font(Theme.Font.statusLabel)
                                    .foregroundColor(Theme.Color.textMono)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !isCollapsed {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(bucket) { item in
                                    tile(item: item)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func tile(item: Item) -> some View {
        let isSelected = selected.contains(item.id)
        // Button swallows long-press inside its tap recognizer; the
        // gesture pair below fires both reliably on the same tile.
        return ItemCard(item: item)
            .overlay(
                selectMode && isSelected
                    ? RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.accent, lineWidth: 3)
                    : nil
            )
            .overlay(alignment: .center) {
                if selectMode && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.Color.accent)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if longPressedJustNow.contains(item.id) {
                    longPressedJustNow.remove(item.id)
                    return
                }
                if selectMode {
                    if isSelected {
                        selected.remove(item.id)
                        if selected.isEmpty {
                            exitSelectMode()
                        }
                    } else {
                        selected.insert(item.id)
                    }
                } else {
                    detailItem = item
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25)
                    .onEnded { _ in
                        longPressedJustNow.insert(item.id)
                        if !selectMode {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectMode = true
                                selected = [item.id]
                            }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } else if !isSelected {
                            selected.insert(item.id)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        // Drop the guard if the finger-up tap never lands.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            longPressedJustNow.remove(item.id)
                        }
                    }
            )
    }

    private func exitSelectMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectMode = false
            selected.removeAll()
        }
    }

    private var sortedSections: [ItemSection] {
        Array(Set(filteredItems.compactMap { itemSection($0) }))
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func itemSection(_ item: Item) -> ItemSection? {
        items.catalog?.kind(by: item.kindID)?.section
    }

    // MARK: - Select mode action bar

    private var selectActionBar: some View {
        HStack(spacing: 0) {
            Button {
                // Skip equipped items — Select All is wired to the
                // bulk-disassemble button, and accidentally disassembling
                // the equipped pet was an easy mistake. Toggle semantics
                // stay the same: a second tap when every candidate is
                // already selected clears it.
                let visibleIDs = Set(
                    filteredItems
                        .filter { !$0.equipped }
                        .map { $0.id }
                )
                if selected.isSuperset(of: visibleIDs) {
                    selected.subtract(visibleIDs)
                } else {
                    selected.formUnion(visibleIDs)
                }
            } label: {
                Text("inventory.button.select_all".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            Rectangle().fill(Theme.Color.divider)
                .frame(width: 1, height: 28)
            Button {
                guard !selected.isEmpty else { return }
                confirmingBulk = true
            } label: {
                Text(String(format: "inventory.button.disassemble".localized, selected.count))
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(selected.isEmpty ? Theme.Color.textSecondary : .red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .disabled(selected.isEmpty)
        }
        .background(.ultraThinMaterial)
    }

    private func successToast(yield: DisassembleYield) -> some View {
        VStack {
            HStack(spacing: 8) {
                ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                    .frame(width: 22, height: 22)
                Text("+\(yield.scrolls)")
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                if yield.tokens > 0 {
                    Rectangle().fill(Theme.Color.divider)
                        .frame(width: 1, height: 16)
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 22, height: 22)
                    Text("+\(yield.tokens)")
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            Spacer()
        }
        .padding(.top, 12)
        // Same transition both ways — toast slides + fades on removal
        // so it doesn't blink out. Plain `.opacity` for removal was the
        // "abrupt disappear" everyone hated.
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    @MainActor
    private func commitBulkDisassemble() async {
        let toKill = items.items.filter { selected.contains($0.id) }
        guard !toKill.isEmpty else { return }
        let yield = await items.disassembleBulk(toKill)
        if let yield {
            // The parent's `.animation(value: bulkResultBanner)` drives
            // both directions of the toast transition, so a plain set
            // is enough — wrapping in `withAnimation` was overriding
            // the parent curve and shipping different ease in/out
            // timings for insertion vs removal.
            bulkResultBanner = yield
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                bulkResultBanner = nil
            }
        }
        exitSelectMode()
    }
}
