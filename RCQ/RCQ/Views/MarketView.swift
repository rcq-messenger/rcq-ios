import SwiftUI

/// Item marketplace. Browse + My listings tabs; 5% fee is server-computed.
struct MarketView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var market = MarketService.shared
    @StateObject private var items = ItemsService.shared

    enum Tab: String, CaseIterable, Identifiable {
        case browse, mine
        var id: String { rawValue }
        var label: String {
            (self == .browse
                ? "market.tab.browse"
                : "market.tab.mine").localized
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        case items, uins
        var id: String { rawValue }
        var label: String {
            (self == .items
                ? "market.category.items"
                : "market.category.uins").localized
        }
    }

    @State private var category: Category = .items
    @State private var tab: Tab = .browse
    @State private var rarityFilter: ItemRarity?
    @State private var sectionFilter: ItemSection?
    @State private var sort: MarketSort = .newest
    @State private var tierFilter: String?
    @State private var selected: MarketplaceListing?
    @State private var selectedUin: UinMarketplaceListing?
    @State private var alertMessage: String?
    @State private var refreshing: Bool = false

    private static let visibleSections: [ItemSection] = [.pets, .voices, .smileys]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    categoryPicker
                    tabPicker
                    if tab == .browse {
                        if category == .items {
                            filterStrip
                        } else {
                            uinFilterStrip
                        }
                    }
                    if category == .items {
                        contentScroll
                    } else {
                        uinContentScroll
                    }
                }
            }
            .navigationTitle("market.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    walletBadge
                }
            }
            .task {
                await reload()
            }
            .onChange(of: rarityFilter)  { _ in Task { await reload() } }
            .onChange(of: sectionFilter) { _ in Task { await reload() } }
            .onChange(of: tierFilter)    { _ in Task { await reload() } }
            .onChange(of: sort)          { _ in Task { await reload() } }
            .onChange(of: category)      { _ in Task { await reload() } }
            .onChange(of: tab) { newTab in
                Task {
                    if newTab == .mine {
                        if category == .items { await market.refreshMine() }
                        else { await market.refreshMyUinListings() }
                    } else {
                        await reload()
                    }
                }
            }
            .sheet(item: $selected) { listing in
                MarketListingDetailSheet(
                    listing: listing,
                    onBought: { await reload() },
                    onCancelled: { await market.refreshMine() },
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedUin) { listing in
                UinMarketListingDetailSheet(
                    listing: listing,
                    onBought: { await reload() },
                    onCancelled: { await market.refreshMyUinListings() },
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert("market.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
            .onChange(of: market.lastError) { msg in
                if let m = msg, !m.isEmpty {
                    alertMessage = m
                    market.acknowledgeError()
                }
            }
        }
    }

    private var categoryPicker: some View {
        Picker("", selection: $category.animation(.easeInOut(duration: 0.18))) {
            ForEach(Category.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Header chrome

    private var tabPicker: some View {
        Picker("", selection: $tab.animation(.easeInOut(duration: 0.18))) {
            ForEach(Tab.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                sectionChip(nil, label: "market.filter.all".localized)
                ForEach(Self.visibleSections, id: \.self) { s in
                    sectionChip(s, label: s.displayName)
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                rarityChip(nil, label: "market.filter.all".localized)
                ForEach(ItemRarity.allCases, id: \.self) { r in
                    rarityChip(r, label: r.label)
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                Menu {
                    ForEach(MarketSort.allCases) { s in
                        Button(s.label) { sort = s }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption)
                        Text(sort.label)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundColor(Theme.Color.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 36)
        .padding(.bottom, 4)
    }

    private func sectionChip(_ section: ItemSection?, label: String) -> some View {
        let active = sectionFilter == section
        return Button {
            sectionFilter = section
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? .white : Theme.Color.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule().fill(active ? Theme.Color.accent : Theme.Color.bgSecondary)
                )
        }
        .buttonStyle(.plain)
    }

    private func rarityChip(_ rarity: ItemRarity?, label: String) -> some View {
        let active = rarityFilter == rarity
        return Button {
            rarityFilter = rarity
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(active ? .white : Theme.Color.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        active
                            ? (rarity?.color ?? Theme.Color.accent)
                            : Theme.Color.bgSecondary
                    )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - UIN browse strip + list

    private var uinFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tierChip(nil, label: "market.filter.all".localized)
                tierChip("common", label: "uin.tier.common".localized)
                tierChip("mid", label: "uin.tier.mid".localized)
                tierChip("legendary", label: "uin.tier.legendary".localized)
                Divider().frame(height: 16).padding(.horizontal, 4)
                Menu {
                    ForEach(MarketSort.allCases) { s in
                        Button(s.label) { sort = s }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.caption)
                        Text(sort.label).font(.caption.weight(.semibold))
                    }
                    .foregroundColor(Theme.Color.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 36)
        .padding(.bottom, 4)
    }

    private func tierChip(_ tier: String?, label: String) -> some View {
        let active = tierFilter == tier
        return Button {
            tierFilter = tier
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? .white : Theme.Color.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule().fill(active ? Theme.Color.accent : Theme.Color.bgSecondary)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var uinContentScroll: some View {
        let rows = (tab == .browse ? market.uinListings : market.myUinListings)
        let canPage = tab == .browse && market.uinListings.count < market.uinListingsTotal
        ScrollView {
            LazyVStack(spacing: 8) {
                if rows.isEmpty && !refreshing {
                    uinEmptyState
                        .padding(.top, 60)
                } else {
                    ForEach(rows) { l in
                        Button { selectedUin = l } label: {
                            UinListingRow(listing: l, isMine: tab == .mine)
                        }
                        .buttonStyle(.plain)
                    }
                    if canPage {
                        ProgressView()
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .task { await market.loadMoreUins() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .refreshable {
            await reload()
        }
    }

    private var uinEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: tab == .browse ? "number.circle" : "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text((tab == .browse
                  ? "market.uin.empty.browse"
                  : "market.uin.empty.mine").localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Item list body

    @ViewBuilder
    private var contentScroll: some View {
        let rows = (tab == .browse ? market.listings : market.myListings)
        let canPage = tab == .browse && market.listings.count < market.total
        ScrollView {
            LazyVStack(spacing: 8) {
                if rows.isEmpty && !refreshing {
                    emptyState
                        .padding(.top, 60)
                } else {
                    ForEach(rows) { l in
                        Button { selected = l } label: {
                            ListingRow(listing: l, isMine: tab == .mine)
                        }
                        .buttonStyle(.plain)
                    }
                    if canPage {
                        ProgressView()
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .task { await market.loadMoreItems() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .refreshable {
            await reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: tab == .browse ? "tag.slash" : "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text((tab == .browse
                  ? "market.empty.browse"
                  : "market.empty.mine").localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var walletBadge: some View {
        let tokens = items.wallet.tokens
        return HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                .frame(width: 16, height: 16)
            Text("\(tokens)")
                .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.Color.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.35), value: tokens)
        }
        .padding(.trailing, 6)
    }

    // MARK: - Reload

    private func reload() async {
        refreshing = true
        market.wipe()
        switch category {
        case .items:
            await market.refresh(
                rarity: rarityFilter,
                section: sectionFilter,
                sort: sort,
            )
            if tab == .mine { await market.refreshMine() }
        case .uins:
            await market.refreshUinListings(
                tier: tierFilter,
                sort: sort,
            )
            if tab == .mine { await market.refreshMyUinListings() }
        }
        refreshing = false
    }

}

// MARK: - Listing row

private struct ListingRow: View {
    let listing: MarketplaceListing
    let isMine: Bool
    @StateObject private var items = ItemsService.shared

    private var kind: ItemKind? {
        items.catalog?.kind(by: listing.kindID)
    }

    private var essence: Int {
        listing.showcaseValue(catalog: items.catalog)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.Color.bgSecondary)
                if let kind {
                    if kind.section == .voices {
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(listing.rarity.color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ItemAssetImage(
                            bundleSubdir: assetSubdir(kind),
                            filename: assetStem(kind),
                            ext: assetExt(kind),
                        )
                        .padding(6)
                    }
                } else {
                    Image(systemName: "cube")
                        .foregroundColor(Theme.Color.divider)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if listing.level > 0 {
                    Text("+\(listing.level)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(3)
                }
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(listing.rarity.color)
                            .frame(width: 6, height: 6)
                    }
                    Spacer()
                }
                .padding(3)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(ItemDisplay.name(for: listing.kindID))
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                rarityBadge
                if essence > 0 {
                    HStack(spacing: 2) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "essence", ext: "png")
                            .frame(width: 11, height: 11)
                        Text("\(essence)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(Theme.Color.accent)
                }
                if isMine { statusBadge }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 14, height: 14)
                    Text("\(listing.priceTokens)")
                        .font(.system(.body, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.Color.textPrimary)
                }
                if isMine {
                    Text(String(format: "market.row.payout".localized, listing.sellerPayoutTokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.Color.bgSecondary.opacity(0.65))
        .cornerRadius(10)
    }

    private var rarityBadge: some View {
        Text(listing.rarity.label.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(listing.rarity.color))
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch listing.status {
            case "active":    return ("market.status.active".localized, Theme.Color.accent)
            case "sold":      return ("market.status.sold".localized, Color(hex: 0xD9923A))
            case "cancelled": return ("market.status.cancelled".localized, Theme.Color.textSecondary)
            default:          return (listing.status, Theme.Color.textSecondary)
            }
        }()
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.6), lineWidth: 0.8))
    }

    private func assetSubdir(_ kind: ItemKind) -> String {
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let subdir = (trimmed as NSString).deletingLastPathComponent
        return subdir.isEmpty ? "Items" : "Items/\(subdir)"
    }
    private func assetStem(_ kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private func assetExt(_ kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}

// MARK: - Listing detail sheet

/// Listing detail sheet. Not `private` — `ContactListView` presents
/// this standalone (without the surrounding `MarketView`) when a
/// share-to-chat deep link lands, so the user sees just the item's
/// shutter slide up rather than the full market shutter + the item
/// shutter on top of it.
struct MarketListingDetailSheet: View {
    let listing: MarketplaceListing
    let onBought: () async -> Void
    let onCancelled: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var market = MarketService.shared
    @StateObject private var auth = AuthService.shared
    @StateObject private var items = ItemsService.shared
    @State private var busy: Bool = false
    @State private var alertMessage: String?
    @State private var showForwardPicker: Bool = false
    @State private var shareAlertMessage: String?

    private var isMine: Bool { listing.sellerUIN == auth.ownUIN }
    private var canAfford: Bool { items.wallet.tokens >= listing.priceTokens }

    private var essence: Int {
        listing.showcaseValue(catalog: items.catalog)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    artwork
                    titleBlock
                    specTable
                    actionRow
                    if isMine && listing.status == "sold" {
                        Text(String(
                            format: "market.detail.sold_to".localized,
                            listing.soldToNickname ?? "#\(listing.soldToUIN ?? 0)"
                        ))
                        .font(.footnote)
                        .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Both share buttons cluster on the leading edge so
                // they read as one "share" intent split between
                // in-app and OS share. Paperplane first (in-app
                // send → main use case among RCQ contacts), then
                // ShareLink for the universal-link path.
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        Button { showForwardPicker = true } label: {
                            Image(systemName: "paperplane")
                        }
                        if let shareURL = Self.webShareURL(for: listing) {
                            ShareLink(item: shareURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .sheet(isPresented: $showForwardPicker) {
                ForwardPickerSheet(
                    message: Self.sharePreviewMessage(for: listing),
                    onPick: { destination in
                        showForwardPicker = false
                        Task { await shareTo(destination) }
                    },
                    onCancel: { showForwardPicker = false },
                )
            }
            .alert("market.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
            .alert("market.share.toast.title".localized,
                   isPresented: Binding(
                    get: { shareAlertMessage != nil },
                    set: { if !$0 { shareAlertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(shareAlertMessage ?? "") })
        }
    }

    /// Universal-link form of the listing URL. Returned as `URL?`
    /// because the rare construction failure (malformed listing id)
    /// shouldn't crash the sheet.
    private static func webShareURL(for listing: MarketplaceListing) -> URL? {
        URL(string: "https://rcq.app/m/\(listing.id)")
    }

    /// Custom-scheme variant — what we paste into the chat text body
    /// when shared via the Forward picker. The receiver's parser
    /// matches this exact shape, so anything tweaked here MUST be
    /// kept in lockstep with `MarketLinkParser.parse(_:)`.
    private static func chatShareBody(for listing: MarketplaceListing) -> String {
        "rcq://market/\(listing.id)"
    }

    /// Synthetic `Message` for the forward-picker's header preview.
    /// The picker only uses this for the "Forward this message to…"
    /// title — its body / list logic doesn't read message kind.
    private static func sharePreviewMessage(for listing: MarketplaceListing) -> Message {
        Message(
            thread: .peer(uin: 0),
            senderUIN: 0,
            isFromMe: true,
            kind: .text,
            text: chatShareBody(for: listing),
        )
    }

    private func shareTo(_ destination: ForwardPickerSheet.Destination) async {
        let body = Self.chatShareBody(for: listing)
        do {
            switch destination {
            case .contact(let c):
                try await MessageService.shared.send(text: body, to: c)
            case .group(let g):
                try await MessageService.shared.send(text: body, to: g)
            }
            shareAlertMessage = "market.share.toast.sent".localized
        } catch {
            shareAlertMessage = String(
                format: "market.share.toast.error".localized,
                error.localizedDescription,
            )
        }
    }

    private var kindName: String {
        ItemDisplay.name(for: listing.kindID)
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(kindName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.Color.textPrimary)
                if let mint = listing.mintNumber {
                    Text("#\(mint)")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            if let kind = items.catalog?.kind(by: listing.kindID) {
                Text(sectionLabel(kind.section))
                    .font(.subheadline)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var specTable: some View {
        VStack(spacing: 0) {
            specRow(label: "market.spec.owner".localized) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(listing.sellerUIN)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                    if let nick = listing.sellerNickname, !nick.isEmpty {
                        Text(nick)
                            .font(.callout.weight(.medium))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
            }
            specDivider
            specRow(label: "market.spec.tier".localized) {
                HStack(spacing: 6) {
                    Text(rarityPercentLabel(for: listing.rarity))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.Color.bgPrimary)
                        .cornerRadius(4)
                    Text(listing.rarity.label)
                        .font(.callout.weight(.medium))
                        .foregroundColor(listing.rarity.color)
                }
            }
            if listing.level > 0 {
                specDivider
                specRow(label: "market.spec.level".localized) {
                    Text("+\(listing.level)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            if listing.purity > 1.0 {
                specDivider
                specRow(label: "market.spec.purity".localized) {
                    Text(String(format: "%.2f×", listing.purity))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            if essence > 0 {
                specDivider
                specRow(label: "market.spec.essence".localized) {
                    HStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "essence", ext: "png")
                            .frame(width: 14, height: 14)
                        Text("\(essence)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(Theme.Color.accent)
                }
            }
            specDivider
            specRow(label: "market.spec.value".localized) {
                HStack(spacing: 4) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 16, height: 16)
                    Text("\(listing.priceTokens)")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            if isMine {
                specDivider
                specRow(label: "market.spec.payout".localized) {
                    HStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 14, height: 14)
                        Text("\(listing.sellerPayoutTokens)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
        }
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
    }

    private func specRow<Content: View>(
        label: String, @ViewBuilder value: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
            value()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var specDivider: some View {
        Rectangle()
            .fill(Theme.Color.divider.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    private func rarityPercentLabel(for rarity: ItemRarity) -> String {
        switch rarity {
        case .common:    return "60%"
        case .uncommon:  return "25%"
        case .rare:      return "10%"
        case .epic:      return "4%"
        case .legendary: return "1%"
        }
    }

    private func sectionLabel(_ section: ItemSection) -> String {
        switch section {
        case .smileys: return "market.section.smileys".localized
        case .pets:    return "market.section.pets".localized
        case .voices:  return "market.section.voices".localized
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let kind = items.catalog?.kind(by: listing.kindID) {
            if kind.section == .voices {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundColor(listing.rarity.color)
                        .frame(width: 110, height: 110)
                    Button {
                        SoundService.shared.preview(kindID: listing.kindID)
                    } label: {
                        Label("item.action.preview_sound".localized, systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ZStack {
                    if kind.section == .pets {
                        Circle()
                            .fill(listing.rarity.color.opacity(0.45))
                            .frame(width: 150, height: 150)
                            .blur(radius: 28)
                    }
                    ItemAssetImage(
                        bundleSubdir: subdir(kind),
                        filename: stem(kind),
                        ext: ext(kind),
                    )
                    .frame(width: 110, height: 110)
                }
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if listing.status != "active" {
            Text(statusLabel)
                .font(.callout.weight(.semibold))
                .foregroundColor(Theme.Color.textSecondary)
        } else if isMine {
            // Avoid `.destructive` role; it overrides the red fill with system grey on dark sheets.
            Button {
                Task { await cancel() }
            } label: {
                Text("market.detail.cancel_listing".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        } else {
            Button {
                Task { await buy() }
            } label: {
                Text(canAfford
                     ? "market.detail.buy".localized
                     : "market.detail.insufficient".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(canAfford ? Theme.Color.accent : Theme.Color.divider)
                    .cornerRadius(8)
            }
            .disabled(busy || !canAfford)
        }
    }

    private var statusLabel: String {
        switch listing.status {
        case "sold":      return "market.detail.sold".localized
        case "cancelled": return "market.detail.cancelled".localized
        default:          return listing.status
        }
    }

    private func buy() async {
        busy = true
        defer { busy = false }
        let result = await market.buy(listingID: listing.id)
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onBought()
            dismiss()
        case .insufficientTokens(let req, let have):
            alertMessage = String(format: "market.error.insufficient".localized, req, have)
        case .notActive:
            alertMessage = "market.error.not_active".localized
        case .selfBuy:
            alertMessage = "market.error.self_buy".localized
        case .ownershipDrift:
            alertMessage = "market.error.ownership_drift".localized
        case .itemGone:
            alertMessage = "market.error.item_gone".localized
        case .other(let m):
            alertMessage = m
        }
    }

    private func cancel() async {
        busy = true
        defer { busy = false }
        let result = await market.cancel(listingID: listing.id)
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onCancelled()
            dismiss()
        case .notActive:
            alertMessage = "market.error.not_active".localized
        case .other(let m):
            alertMessage = m
        }
    }

    private func subdir(_ kind: ItemKind) -> String {
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let s = (trimmed as NSString).deletingLastPathComponent
        return s.isEmpty ? "Items" : "Items/\(s)"
    }
    private func stem(_ kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private func ext(_ kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}

// MARK: - Sell sheet

/// Set-price flow opened from `ItemDetailSheet`; lists via `MarketService.list`.
struct SellOnMarketSheet: View {
    let item: Item
    var onListed: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var market = MarketService.shared
    @StateObject private var items = ItemsService.shared

    @State private var priceText: String = ""
    @State private var busy: Bool = false
    @State private var alertMessage: String?

    private var price: Int? {
        let trimmed = priceText.trimmingCharacters(in: .whitespaces)
        guard let p = Int(trimmed) else { return nil }
        return p
    }

    private var validPrice: Bool {
        guard let p = price else { return false }
        return p >= 1 && p <= 999_999
    }

    // 5% fee mirror of server math; render-only, server is canonical.
    private var localPayout: Int {
        guard let p = price else { return 0 }
        return p - (p * 5 / 100)
    }

    private var kindName: String {
        ItemDisplay.name(for: item.kindID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(kindName)
                        .font(.title3.bold())
                        .foregroundColor(Theme.Color.textPrimary)
                        .padding(.top, 8)
                    Text("market.sell.body".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    HStack(spacing: 8) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 22, height: 22)
                        TextField("market.sell.price_placeholder".localized, text: $priceText)
                            .keyboardType(.numberPad)
                            .font(.system(.title3, weight: .semibold).monospacedDigit())
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                    .padding(14)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(10)
                    if let _ = price {
                        HStack {
                            Text("market.sell.payout_hint".localized)
                                .font(.caption)
                                .foregroundColor(Theme.Color.textSecondary)
                            Spacer()
                            Text(String(format: "≈ %d", localPayout))
                                .font(.system(.callout, weight: .semibold).monospacedDigit())
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .padding(.horizontal, 4)
                    }
                    Button {
                        Task { await listIt() }
                    } label: {
                        Text(busy
                             ? "market.sell.busy".localized
                             : "market.sell.cta".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(validPrice ? Theme.Color.accent : Theme.Color.divider)
                            .cornerRadius(8)
                    }
                    .disabled(!validPrice || busy)
                    Spacer()
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("market.sell.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("market.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
        }
    }

    private func listIt() async {
        guard let p = price, validPrice else { return }
        busy = true
        defer { busy = false }
        let result = await market.list(itemID: item.id, priceTokens: p)
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onListed()
            dismiss()
        case .alreadyListed:
            alertMessage = "market.error.already_listed".localized
        case .equipped:
            alertMessage = "market.error.equipped".localized
        case .tooManyListings(let max):
            alertMessage = String(format: "market.error.too_many".localized, max)
        case .other(let m):
            alertMessage = m
        }
    }
}

// MARK: - UIN listing row + detail

private struct UinListingRow: View {
    let listing: UinMarketplaceListing
    let isMine: Bool

    private var tierColor: Color {
        switch listing.tier {
        case "legendary": return Color(hex: 0xC8442A)
        case "mid":       return Color(hex: 0x8E5BD4)
        default:          return Color(hex: 0x6BB12C)
        }
    }

    private var tierLabel: String {
        switch listing.tier {
        case "legendary": return "uin.tier.legendary".localized
        case "mid":       return "uin.tier.mid".localized
        default:          return "uin.tier.common".localized
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Theme.Color.bgSecondary)
                Image(systemName: "number")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(tierColor)
                VStack {
                    HStack {
                        Spacer()
                        Circle().fill(tierColor).frame(width: 6, height: 6)
                    }
                    Spacer()
                }
                .padding(3)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                // `Text(verbatim:)` so the UIN renders without a thousands separator.
                HStack(spacing: 8) {
                    Text(verbatim: "\(listing.uin)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(tierLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(tierColor))
                }
                if !isMine, let nick = listing.sellerNickname {
                    Text(nick)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                } else if isMine, listing.status != "active" {
                    Text(listing.status.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }

            Spacer()

            HStack(spacing: 3) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 14, height: 14)
                Text(verbatim: "\(listing.priceTokens)")
                    .font(.system(.body, weight: .bold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
            }
        }
        .padding(10)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(10)
    }
}

struct UinMarketListingDetailSheet: View {
    let listing: UinMarketplaceListing
    let onBought: () async -> Void
    let onCancelled: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var market = MarketService.shared
    @StateObject private var items = ItemsService.shared
    @State private var busy: Bool = false
    @State private var alertMessage: String?
    @State private var showForwardPicker: Bool = false
    @State private var shareAlertMessage: String?

    private var isMine: Bool {
        listing.sellerUIN == AuthService.shared.ownUIN
    }

    private var canBuy: Bool {
        !isMine && listing.status == "active"
    }

    private var canCancel: Bool {
        isMine && listing.status == "active"
    }

    private var tierColor: Color {
        switch listing.tier {
        case "legendary": return Color(hex: 0xC8442A)
        case "mid":       return Color(hex: 0x8E5BD4)
        default:          return Color(hex: 0x6BB12C)
        }
    }

    private var tierLabel: String {
        switch listing.tier {
        case "legendary": return "uin.tier.legendary".localized
        case "mid":       return "uin.tier.mid".localized
        default:          return "uin.tier.common".localized
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 6) {
                            // `Text(verbatim:)` so the UIN doesn't get a thousands separator.
                            Text(verbatim: "\(listing.uin)")
                                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                                .foregroundColor(Theme.Color.textPrimary)
                            Text(tierLabel.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(tierColor))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(14)

                        VStack(spacing: 8) {
                            HStack {
                                Text("market.detail.price".localized)
                                    .foregroundColor(Theme.Color.textSecondary)
                                Spacer()
                                HStack(spacing: 4) {
                                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                        .frame(width: 16, height: 16)
                                    Text("\(listing.priceTokens)")
                                        .font(.body.weight(.semibold).monospacedDigit())
                                        .foregroundColor(Theme.Color.textPrimary)
                                }
                            }
                            HStack {
                                Text("market.detail.seller_gets".localized)
                                    .foregroundColor(Theme.Color.textSecondary)
                                Spacer()
                                Text("\(listing.sellerPayoutTokens)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                            if let nick = listing.sellerNickname {
                                HStack {
                                    Text("market.detail.seller_label".localized)
                                        .foregroundColor(Theme.Color.textSecondary)
                                    Spacer()
                                    Text(nick)
                                        .foregroundColor(Theme.Color.textPrimary)
                                }
                            }
                        }
                        .padding(14)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(10)

                        if canBuy {
                            Button {
                                Task { await buyIt() }
                            } label: {
                                HStack {
                                    if busy { ProgressView().tint(.white) }
                                    Text(String(format: "market.detail.buy".localized, listing.priceTokens))
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.Color.accent)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .disabled(busy)
                        } else if canCancel {
                            Button(role: .destructive) {
                                Task { await cancelIt() }
                            } label: {
                                HStack {
                                    if busy { ProgressView().tint(.white) }
                                    Text("market.detail.cancel".localized)
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.85))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .disabled(busy)
                        } else {
                            Text(listing.status.uppercased())
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Theme.Color.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.Color.bgSecondary)
                                .cornerRadius(10)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        Button { showForwardPicker = true } label: {
                            Image(systemName: "paperplane")
                        }
                        if let shareURL = Self.webShareURL(for: listing) {
                            ShareLink(item: shareURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .sheet(isPresented: $showForwardPicker) {
                ForwardPickerSheet(
                    message: Self.sharePreviewMessage(for: listing),
                    onPick: { destination in
                        showForwardPicker = false
                        Task { await shareTo(destination) }
                    },
                    onCancel: { showForwardPicker = false },
                )
            }
            .alert("uin_listing.share.toast.title".localized,
                   isPresented: Binding(
                    get: { shareAlertMessage != nil },
                    set: { if !$0 { shareAlertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(shareAlertMessage ?? "") })
            .alert("market.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
        }
    }

    private func buyIt() async {
        busy = true
        defer { busy = false }
        let result = await market.buyUin(listingID: listing.id)
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onBought()
            dismiss()
        case .insufficientTokens(let req, let have):
            alertMessage = String(format: "market.error.insufficient".localized, req, have)
        case .selfBuy:
            alertMessage = "market.error.self_buy".localized
        case .ownershipDrift:
            alertMessage = "market.error.ownership_drift".localized
        case .uinGone:
            alertMessage = "market.error.uin_gone".localized
        case .notActive:
            alertMessage = "market.error.not_active".localized
        case .other(let m):
            alertMessage = m
        }
    }

    private func cancelIt() async {
        busy = true
        defer { busy = false }
        let result = await market.cancelUin(listingID: listing.id)
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onCancelled()
            dismiss()
        case .notActive:
            alertMessage = "market.error.not_active".localized
        case .other(let m):
            alertMessage = m
        }
    }

    private static func webShareURL(for listing: UinMarketplaceListing) -> URL? {
        URL(string: "https://rcq.app/ul/\(listing.id)")
    }

    private static func chatShareBody(for listing: UinMarketplaceListing) -> String {
        "rcq://uin-listing/\(listing.id)"
    }

    private static func sharePreviewMessage(for listing: UinMarketplaceListing) -> Message {
        Message(
            thread: .peer(uin: 0),
            senderUIN: 0,
            isFromMe: true,
            kind: .text,
            text: chatShareBody(for: listing),
        )
    }

    private func shareTo(_ destination: ForwardPickerSheet.Destination) async {
        let body = Self.chatShareBody(for: listing)
        do {
            switch destination {
            case .contact(let c):
                try await MessageService.shared.send(text: body, to: c)
            case .group(let g):
                try await MessageService.shared.send(text: body, to: g)
            }
            shareAlertMessage = "uin_listing.share.toast.sent".localized
        } catch {
            shareAlertMessage = String(
                format: "uin_listing.share.toast.error".localized,
                error.localizedDescription,
            )
        }
    }
}
