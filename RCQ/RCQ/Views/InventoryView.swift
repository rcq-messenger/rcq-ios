import SwiftUI

/// Inventory screen — owner side. Wallet readout + Open / Buy CTAs
/// at the top, sectioned grid below.
///
/// Two modes:
///   - **Browse** (default) — tap a tile → ItemDetailSheet.
///   - **Select** (long-press a tile, or "Select" toolbar button) —
///     tap toggles selection, "Select all" + "Disassemble N" CTAs
///     surface, bulk POST to `/items/disassemble-bulk`. Mirrors IX.
///
/// Filter chips above the grid — "All" + one per rarity — narrow
/// the visible items. Selection survives a filter change so the
/// user can flip "All → Common" + "Select" + "Select all" +
/// "Disassemble" to flush all commons in two taps.
struct InventoryView: View {
    @StateObject private var items = ItemsService.shared
    @StateObject private var trades = TradesService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showShop = false
    @State private var showLootbox = false
    @State private var showTrades = false
    @State private var showGames = false
    @State private var showMarket = false
    /// Pet Hunt Memorial sheet — surfaces from the inventory
    /// ellipsis menu so users can browse pets that died on hunts
    /// without going into the Games tab.
    @State private var showMemorial = false
    @State private var detailItem: Item?
    @State private var lastError: String?

    @State private var rarityFilter: ItemRarity?
    @State private var selectMode: Bool = false
    @State private var selected: Set<String> = []
    @State private var confirmingBulk: Bool = false
    @State private var bulkResultBanner: DisassembleYield? = nil
    /// Cold-load gate. Set to false after the first `.task` resolves
    /// — same pattern as `PublicInventoryView.loading`. Without this
    /// the empty-state CTA flashes for one frame on cold open before
    /// the items stream populates.
    @State private var loading: Bool = true
    /// Tile ids whose long-press just fired — the post-longpress
    /// tap that SwiftUI emits on finger-up needs to be swallowed,
    /// otherwise releasing your finger immediately deselects the
    /// tile you just selected.
    @State private var longPressedJustNow: Set<String> = []

    /// Five columns — IX uses four big tiles which made the grid
    /// feel cramped and the icons oversized. Five gives the relics
    /// room to read as collectibles without dominating the surface.
    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    private var filteredItems: [Item] {
        guard let r = rarityFilter else { return items.items }
        return items.items.filter { $0.rarity == r }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        walletPanel
                            .padding(.horizontal, 16)
                        Divider()
                            .background(Theme.Color.divider)
                            .padding(.horizontal, 16)
                        // Edge-to-edge filter strip — bleeds past the
                        // grid's 16pt gutter so the rightmost chip
                        // doesn't clip when there are five rarities.
                        // Same trick as the carousel.
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
                // Top-of-screen sync pill. Visible whenever the
                // initial `.task` is still running, regardless of
                // whether items are already cached from a previous
                // session — the cold-load ProgressView only fires
                // when items.isEmpty, so a user re-opening the
                // surface saw nothing to indicate the fetch in
                // flight. Pill matches the lightweight feel of
                // pull-to-refresh without claiming the whole grid.
                if loading {
                    syncingPill
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: loading)
            // Animation curves are driven from `commitBulkDisassemble`
            // via explicit `withAnimation` blocks — spring for the
            // slide-in, ease-out for the fade-out. Spring on opacity
            // removal felt jerky (no overshoot to settle on, just
            // collapse), so the curves are split.
            .navigationTitle(selectMode ? "common.confirm".localized : "inventory.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // In select mode this resolves to "Done" (exit);
                    // otherwise normal close. The X-circle close on
                    // the right is reserved for the new IX-style
                    // surfaces — inventory stays with text-leading.
                    Button(selectMode ? "common.done".localized : "common.close".localized) {
                        if selectMode {
                            exitSelectMode()
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(Theme.Color.accent)
                }
                // Top-right: ellipsis menu with the single hide/show
                // inventory toggle (the only option that's been there
                // since the start).
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
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(Theme.Color.accent)
                    }
                }
                // Bottom bar: Games + Market + Trades, centred in the
                // middle of the bar (Spacer on each side, no Spacer
                // between them — they sit as a tight cluster).
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
                    Spacer()
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
            .task {
                if items.catalog == nil { await items.refreshCatalog() }
                await items.refreshInventory()
                await trades.refreshAll()
                loading = false
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
                // Memorial of pets that died on Pet Hunt. Loads
                // its own data via PetHuntService.refreshMemorial
                // on appear.
                PetMemorialFromInventorySheet()
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

    /// Sum the per-item scroll + token yield across the current
    /// selection so the confirmation dialog can show "you'll get N
    /// scrolls + M tokens" *before* the user commits to the burn.
    /// Matches the server-side payout tables exactly (single source of
    /// truth in `Models/TemperTables.swift`, mirrored on the backend).
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

    /// Single ellipsis menu hosting Games entry, Trades shortcut and
    /// the public/private inventory toggle. Replaces the previous
    /// two-icon trailing slot (trades + privacy). The trade pending-
    /// count badge moves onto the ellipsis itself so the affordance
    /// for "you have a trade waiting" stays glance-able from the
    /// closed menu.
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
                        // Solid red — explicit `.opacity(1)` so toolbar
                        // tinting context can't bleed alpha into the
                        // chip. Slightly nudged up + left of the
                        // ellipsis so it sits over the top-right
                        // corner instead of clipping past the dots.
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
                    // No leading glyph — the inventory entry-point in
                    // ContactListView already wears `shippingbox.fill`,
                    // and "Open" + a duplicate box icon in the same
                    // surface read as redundant. Plain text CTA.
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
        // Edge-to-edge horizontal scroll: the inner HStack starts at
        // 16pt and ends at 16pt of slack so the first / last chip
        // line up with the grid columns instead of bleeding into the
        // safe-area edge. Pure ScrollView outside the parent's
        // padding so the rightmost chip can keep scrolling past
        // the screen edge without clipping.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "rarity.all".localized.uppercased(), color: Theme.Color.accent, isOn: rarityFilter == nil) {
                    rarityFilter = nil
                }
                // Common → Legendary order — `rollWeight` puts
                // legendary at index 0, so reverse the sort here so
                // the chip strip reads normal → rare.
                ForEach(ItemRarity.allCases.sorted { $0.rollWeight > $1.rollWeight }, id: \.self) { r in
                    chip(label: r.label.uppercased(), color: r.color, isOn: rarityFilter == r) {
                        rarityFilter = (rarityFilter == r) ? nil : r
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func chip(label: String, color: Color, isOn: Bool, action: @escaping () -> Void) -> some View {
        // Always tinted with the rarity colour so the strip reads as
        // a palette at a glance. Selected = solid + white text;
        // unselected = 22% colour fill + white text. Same shape both
        // ways so the strip doesn't jitter on tap.
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

    /// Floating "Syncing…" pill shown at the top of the inventory
    /// while the initial fetch is in flight. Quiet, glassy capsule —
    /// matches the lightweight feel of iOS's pull-to-refresh chrome
    /// instead of claiming the centre of the grid.
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
            // CTA — straight to the lootbox sheet which already
            // exists at this level (`showLootbox` flag). Without
            // this the empty state was a wall: the user reads
            // "open your first box" with no obvious path to one.
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.displayName)
                            .font(Theme.Font.statusLabel)
                            .foregroundColor(Theme.Color.textSecondary)
                            .textCase(.uppercase)
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

    private func tile(item: Item) -> some View {
        let isSelected = selected.contains(item.id)
        // Plain ZStack instead of Button — SwiftUI's Button swallows
        // long-press inside its tap-recognizer, which is why the
        // previous wiring did nothing on long-press. Pair an
        // onTapGesture with a simultaneous LongPressGesture so both
        // fire reliably on the same tile.
        return ItemCard(item: item)
            .overlay(
                selectMode && isSelected
                    ? RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.accent, lineWidth: 3)
                    : nil
            )
            // Selection check — centered over the tile so it acts
            // as a visual confirmation rather than chrome floating
            // in the corner. Only renders when the tile is actually
            // selected; non-selected tiles in select-mode just sit
            // there waiting to be tapped.
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
                // SwiftUI's `simultaneousGesture(LongPressGesture)`
                // arrangement fires both long-press AND the
                // finger-up tap. Without the guard, releasing right
                // after a successful long-press toggled the tile
                // back off — which is exactly what the user reported.
                if longPressedJustNow.contains(item.id) {
                    longPressedJustNow.remove(item.id)
                    return
                }
                if selectMode {
                    if isSelected {
                        selected.remove(item.id)
                        // Empty selection ⇒ exit select mode
                        // automatically. Mirrors IX.
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
                // Shortened from 0.35 → 0.25 so the press feels
                // responsive — IX's affordance fires before users
                // start wondering if anything's happening.
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
                        // Belt-and-braces: the tap that the gesture
                        // system emits on finger-up should land
                        // within ~250ms; if it doesn't, drop the
                        // guard so a real tap a moment later isn't
                        // also swallowed.
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
        // Buttons sit flush with the bar's edges — no top inset, no
        // horizontal gutter inside the action bar's container. Pure
        // ultraThinMaterial backdrop, full-width buttons, IX-style.
        HStack(spacing: 0) {
            Button {
                let visibleIDs = Set(filteredItems.map { $0.id })
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
        // Glass pill anchored just below the navigation bar with the
        // actual scroll + coin assets so the message reads as "+S
        // scrolls · +T tokens" without text-only chrome. Slide-down
        // + fade-out via the parent `.animation(value:)` modifier;
        // previous version had the `.transition` defined here but
        // no animation driver attached, so the toast just popped.
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
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity,
        ))
        .allowsHitTesting(false)
    }

    @MainActor
    private func commitBulkDisassemble() async {
        let toKill = items.items.filter { selected.contains($0.id) }
        guard !toKill.isEmpty else { return }
        let yield = await items.disassembleBulk(toKill)
        if let yield {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                bulkResultBanner = yield
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.45)) {
                    bulkResultBanner = nil
                }
            }
        }
        // Empty selection ⇒ leave select mode. Mirrors the
        // tile-deselect path.
        exitSelectMode()
    }
}
