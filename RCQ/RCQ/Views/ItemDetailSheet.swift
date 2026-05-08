import SwiftUI
import UIKit

/// Full per-item detail sheet — kind name + lore + rarity + mint
/// badge + purity + level + acquired-at + ownership history (Session 4
/// will populate the chain via `GET /items/{id}`). Equip / temper
/// buttons live here too; in Session 1 they are visible-but-disabled
/// placeholders so the layout solidifies.
struct ItemDetailSheet: View {
    let item: Item
    /// `true` when shown from someone else's public inventory — hides
    /// the action row entirely (no Temper / Equip / Disassemble for
    /// items you don't own).
    var readOnly: Bool = false
    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showTemper = false
    @State private var showDisassemble = false
    @State private var showSell = false
    @State private var cancellingListing = false
    @State private var sellGateAlert: String?
    @State private var history: [ItemHistoryEvent] = []
    @State private var historyLoading = true
    /// Shows a transient "Copied" toast above the history block
    /// when the user taps a UIN chip — so the action has visible
    /// feedback beyond the haptic.
    @State private var copiedUIN: Int? = nil

    private var kind: ItemKind? {
        items.catalog?.kind(by: item.kindID)
    }

    /// Live item — `item` is the snapshot at sheet-open time, but
    /// after a successful temper / equip the canonical row lives in
    /// `items.items`. Re-resolve by id so state changes (level bump,
    /// equipped flag) reflect immediately without dismissing.
    private var live: Item {
        items.items.first(where: { $0.id == item.id }) ?? item
    }

    /// Whether the temper button should fire. Mirrors the IX preflight:
    /// at max level → no, no scrolls for the next attempt → no.
    private var canTemper: Bool {
        guard let kind, kind.isTemperable else { return false }
        let level = live.level
        if level >= TemperTables.maxLevel { return false }
        let cost = TemperTables.scrollCost(at: level)
        return items.wallet.scrolls >= cost
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    statsBlock
                    // Pack contents — only for cosmetic packs (the
                    // `forum_classics` row, plus future voice / skin
                    // packs). Renders the animated thumbnail strip
                    // so the user knows what equipping this pack
                    // adds to their chat.
                    if let kind, kind.appliesAs != .none {
                        // Bleed past the parent VStack's 18pt
                        // horizontal padding so the scroll strip
                        // reads edge-to-edge — KindContentsView
                        // re-applies the same inset internally so
                        // peer content (title, first tile) still
                        // aligns with the rest of the sheet.
                        KindContentsView(kindID: kind.id, horizontalInset: 18)
                            .padding(.horizontal, -18)
                    }
                    if !readOnly {
                        actionRow
                    }
                    historyBlock
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
            }
            .sheet(isPresented: $showTemper) {
                TemperConfirmSheet(item: live, onComplete: { outcome in
                    showTemper = false
                    // Burn dismisses the detail sheet — there's no
                    // longer an item to inspect.
                    if outcome == .burned {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            dismiss()
                        }
                    }
                })
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showDisassemble) {
                DisassembleConfirmSheet(item: live, onComplete: { broken in
                    showDisassemble = false
                    if broken {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            dismiss()
                        }
                    }
                })
                // Bump the detent — at .medium the explainer copy was
                // clipped on the smaller phones. A custom fraction
                // gives it the breathing room to render the whole
                // body without forcing .large (which felt overdone for
                // a confirm dialog).
                .presentationDetents([.fraction(0.62), .large])
            }
            .sheet(isPresented: $showSell) {
                SellOnMarketSheet(item: live, onListed: {
                    showSell = false
                    // Listing succeeded — bounce back to inventory
                    // so the user sees the for-sale badge land.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        dismiss()
                    }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert("market.alert.title".localized,
                   isPresented: Binding(
                       get: { sellGateAlert != nil },
                       set: { if !$0 { sellGateAlert = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(sellGateAlert ?? "") })
        }
    }

    // MARK: - Hero

    private var hero: some View {
        // Centred 110pt image on a clean background — no border, no
        // square frame. Mint badge sits as a small monospaced label
        // under the name in the stats block, not overlaid on the
        // image. Mirrors IX's RevealOverlay sizing (90pt + a bit) so
        // detail and reveal feel like the same artifact at different
        // scales.
        VStack(spacing: 8) {
            if let kind {
                if kind.section == .voices {
                    // Voices ship as audio without a thumbnail —
                    // music-note glyph + tap-to-play. Tap the icon
                    // OR the explicit Preview button below it; both
                    // route through SoundService.preview.
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
                    }
                    .buttonStyle(.plain)
                    Button {
                        SoundService.shared.preview(kindID: item.kindID)
                    } label: {
                        Label("item.action.preview_sound".localized, systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    ItemAssetImage(
                        bundleSubdir: subdir(kind),
                        filename: stem(kind),
                        ext: ext(kind),
                    )
                    .frame(width: 110, height: 110)
                }
            }
            Text(displayName)
                .font(.custom("Georgia", size: 22))
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
            // Lore line — small upright caption under the name.
            // nil for kinds we haven't written lore for; just hide.
            if let lore = ItemDisplay.lore(for: item.kindID) {
                Text(lore)
                    .font(.footnote)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var displayName: String {
        kindName(for: item.kindID)
    }

    /// Computed showcase essence — base × mintMul × levelMul × purity.
    /// IX surfaces this as the headline number; we follow suit. No
    /// "(base N)" annotation — purity below 1.0 makes the computed
    /// value drop below `base`, and the parens were just confusing
    /// (looked like a typo). The base roll is still inferable from
    /// the headline + purity stat below if anyone needs it.
    private var essenceDisplay: String {
        guard let catalog = items.catalog else {
            return "\(live.baseEssence)"
        }
        return "\(live.showcaseValue(catalog: catalog))"
    }

    // MARK: - Stats

    /// Telegram-style spec table — same shape as the market detail
    /// sheet's `specTable`. Replaces the chip-strip + key/value rows
    /// for a single consolidated surface that reads cleanly.
    private var statsBlock: some View {
        VStack(spacing: 0) {
            specRow(label: "market.spec.tier".localized) {
                HStack(spacing: 6) {
                    Text(item.rarity.label)
                        .font(.callout.weight(.medium))
                        .foregroundColor(item.rarity.color)
                    if live.equipped {
                        Text("item.equipped".localized)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.Color.accent)
                            .cornerRadius(4)
                    }
                }
            }
            specDivider
            specRow(label: "market.spec.essence".localized) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text(essenceDisplay)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Theme.Color.accent)
            }
            if item.purity != 1.0 {
                specDivider
                specRow(label: "market.spec.purity".localized) {
                    HStack(spacing: 6) {
                        Text(String(format: "%.2f×", item.purity))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                        if let pur = item.purityTier {
                            Text(pur)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(item.rarity.color)
                        }
                    }
                }
            }
            if item.level > 0 {
                specDivider
                specRow(label: "market.spec.level".localized) {
                    Text("+\(item.level)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            if let kind, let cap = kind.limit, let mint = item.mintNumber {
                specDivider
                specRow(label: "item.stat.mint".localized) {
                    HStack(spacing: 6) {
                        Text(String(format: "item.mint.of".localized, mint, cap))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                        if let lucky = item.luckyMintLabel {
                            Text(lucky)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                        }
                    }
                }
            }
            specDivider
            specRow(label: "item.stat.acquired".localized) {
                Text(DateFormatter.itemAcquired.string(from: item.acquiredAt))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.Color.textPrimary)
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

    // MARK: - Actions

    private var actionRow: some View {
        VStack(spacing: 10) {
            // While the item is listed on the marketplace every
            // mutation (temper / equip / disassemble) is gated on the
            // server with a 409 — render only the "Cancel listing"
            // affordance to avoid offering buttons that would 409.
            if live.listed {
                // No `role: .destructive` here — that flag tells the
                // system to apply its default destructive chrome
                // (greyed pill + red label) which OVERRIDES our
                // explicit red background, leaving an unreadable
                // grey-on-white capsule on the dark sheet. The
                // visual treatment below already reads as
                // destructive (red fill + white label) without the
                // role hint.
                Button {
                    Task { await cancelListing() }
                } label: {
                    Text(cancellingListing
                         ? "market.detail.cancelling".localized
                         : "market.detail.cancel_listing".localized)
                        .font(Theme.Font.nickname)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundColor(.white)
                        .background(Color.red)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(cancellingListing)
            } else {
                HStack(spacing: 10) {
                    if let kind = kind, kind.isTemperable {
                        Button {
                            showTemper = true
                        } label: {
                            Text("item.action.enhance".localized)
                                .font(Theme.Font.nickname)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .foregroundColor(.white)
                                .background(canTemper ? Theme.Color.accent : Theme.Color.divider)
                                .cornerRadius(8)
                        }
                        .disabled(!canTemper)
                    }
                    if let kind = kind, kind.isEquippable {
                        Button {
                            Task { await items.toggleEquip(live) }
                        } label: {
                            HStack(spacing: 6) {
                                if live.equipped {
                                    // Checkmark differentiates the two
                                    // accent-green buttons that stack
                                    // when a temperable pet is also
                                    // equipped (Прокачать + Снять).
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                Text((live.equipped ? "item.action.unequip" : "item.action.equip").localized)
                                    .font(Theme.Font.nickname)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            // Theme-stable colours. Earlier the
                            // equipped variant used `Theme.Color.textPrimary`
                            // as the fill, which flipped to white in
                            // dark mode and rendered the button
                            // invisible (white-on-white). Accent
                            // green works in both themes; the check
                            // glyph above keeps it distinguishable
                            // from a green Temper button next to it.
                            .foregroundColor(live.equipped ? .white : Theme.Color.textPrimary)
                            .background(live.equipped ? Theme.Color.accent : Theme.Color.bgSecondary)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        showDisassemble = true
                    } label: {
                        Text("item.action.disassemble".localized)
                            .font(Theme.Font.nickname)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundColor(Theme.Color.textSecondary)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.Color.divider, lineWidth: 1))
                    }
                }
                // Sell — separate row beneath the action cluster so
                // the three-button rhythm above stays consistent.
                // Always rendered; if the item is currently equipped
                // we surface a friendly "unequip first" alert instead
                // of opening the sell sheet (server would 409 anyway,
                // and hiding the button left users hunting for it).
                Button {
                    if live.equipped {
                        sellGateAlert = "market.error.equipped".localized
                    } else {
                        showSell = true
                    }
                } label: {
                    Label("item.action.sell".localized, systemImage: "cart.fill")
                        .font(Theme.Font.nickname)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundColor(.white)
                        .background(live.equipped ? Theme.Color.divider : Theme.Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cancelListing() async {
        // Pull the active listing out of MarketService.myListings;
        // we don't carry the listing id on the Item itself.
        guard let listing = MarketService.shared.myListings.first(where: {
            $0.itemID == item.id && $0.status == "active"
        }) else {
            // Nothing local to cancel — refresh and bail; the badge
            // will clear on the next inventory tick if the server
            // already cleared it.
            await MarketService.shared.refreshMine()
            await items.refreshInventory()
            return
        }
        cancellingListing = true
        defer { cancellingListing = false }
        _ = await MarketService.shared.cancel(listingID: listing.id)
    }

    // MARK: - History

    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("item.history.title".localized)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .tracking(2)
            if historyLoading && history.isEmpty {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("item.history.loading".localized)
                        .font(Theme.Font.statusLabel)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            } else if history.isEmpty {
                Text("item.history.empty".localized)
                    .font(Theme.Font.statusLabel)
                    .foregroundColor(Theme.Color.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.offset) { idx, event in
                        historyRow(event)
                        if idx < history.count - 1 {
                            Divider()
                                .background(Theme.Color.divider)
                                .padding(.leading, 26)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
        .overlay(alignment: .topTrailing) {
            if let uin = copiedUIN {
                Text(String(format: "item.history.copied".localized, uin))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Color.accent)
                    .cornerRadius(4)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .task { await loadHistory() }
        // Re-fetch the journal whenever a temper bumps the level —
        // the success path appends a `temper_success` row server-
        // side, and we want it to surface here without forcing the
        // user to close + reopen the detail sheet.
        .onChange(of: live.level) { _ in
            Task { await loadHistory() }
        }
        .onChange(of: live.equipped) { _ in
            Task { await loadHistory() }
        }
    }

    private func historyRow(_ e: ItemHistoryEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Tighter icon size for the history row — the chrome
            // around it (action title + actor chips) is the visual
            // anchor; the icon just decorates.
            Image(systemName: iconName(for: e.action))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(iconColor(for: e.action))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(actionTitle(e))
                    .font(Theme.Font.statusLabel)
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 6) {
                    actorChips(e)
                    Text(DateFormatter.itemAcquired.string(from: e.at))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// One or two UIN chips per row, depending on the action — the
    /// chip is tappable and copies the UIN to the clipboard with a
    /// light haptic. "you" is rendered for the owner's own UIN
    /// (no copy — there's nothing to look up).
    @ViewBuilder
    private func actorChips(_ e: ItemHistoryEvent) -> some View {
        let myUIN = AuthService.shared.ownUIN
        switch e.action {
        case "drop":
            // No actor — system event.
            EmptyView()
        case "trade", "gift":
            if let from = e.fromUIN {
                actorChip(uin: from, isMe: from == myUIN)
                Text("→")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.Color.textMono)
            }
            if let to = e.toUIN {
                actorChip(uin: to, isMe: to == myUIN)
            }
        case "market_sold":
            // Same from→to shape as a trade, plus a small coin-pill
            // for the price the buyer paid. Shows the full deal in
            // one row without inflating the action title text.
            if let from = e.fromUIN {
                actorChip(uin: from, isMe: from == myUIN)
                Text("→")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.Color.textMono)
            }
            if let to = e.toUIN {
                actorChip(uin: to, isMe: to == myUIN)
            }
            if let price = e.priceTokens {
                HStack(spacing: 2) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 11, height: 11)
                    Text("\(price)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(3)
            }
        case "temper_success", "temper_burn", "disassemble":
            if let from = e.fromUIN {
                Text("item.history.actor.by".localized)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.Color.textMono)
                actorChip(uin: from, isMe: from == myUIN)
            }
        default:
            EmptyView()
        }
    }

    private func actorChip(uin: Int, isMe: Bool) -> some View {
        Button {
            guard !isMe else { return }
            UIPasteboard.general.string = String(uin)
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.15)) {
                copiedUIN = uin
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if copiedUIN == uin {
                    withAnimation { copiedUIN = nil }
                }
            }
        } label: {
            // `Text("#\(Int)")` triggers SwiftUI's locale-aware
            // grouping ("#1,234"). UINs are identifiers, not
            // numbers — interpolate via String() so the digits
            // render raw.
            Text(isMe ? "item.history.actor.you".localized : "#" + String(uin))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(isMe ? Theme.Color.textMono : Theme.Color.accent)
                .underline(!isMe)
        }
        .buttonStyle(.plain)
        .disabled(isMe)
    }

    private func iconName(for action: String) -> String {
        switch action {
        case "drop":            return "shippingbox.fill"
        case "trade":           return "arrow.left.arrow.right"
        case "gift":            return "gift.fill"
        case "market_sold":     return "cart.fill"
        case "temper_success":  return "checkmark.seal.fill"
        case "temper_burn":     return "flame.fill"
        case "disassemble":     return "wrench.adjustable.fill"
        default:                return "circle.fill"
        }
    }

    private func iconColor(for action: String) -> Color {
        switch action {
        case "drop":            return Theme.Color.accent
        case "trade", "gift":   return Theme.Color.accent
        case "market_sold":     return Theme.Color.accent
        case "temper_success":  return Theme.Color.accent
        case "temper_burn":     return .red
        case "disassemble":     return Theme.Color.textSecondary
        default:                return Theme.Color.textMono
        }
    }

    private func actionTitle(_ e: ItemHistoryEvent) -> String {
        switch e.action {
        case "drop":            return "item.history.action.drop".localized
        case "trade":           return "item.history.action.trade".localized
        case "gift":            return "item.history.action.gift".localized
        case "market_sold":     return "item.history.action.market_sold".localized
        case "temper_success":
            if let from = e.levelBefore, let to = e.levelAfter {
                return String(format: "item.history.action.temper_success_levels".localized, from, to)
            }
            return "item.history.action.temper_success".localized
        case "temper_burn":     return "item.history.action.temper_burn".localized
        case "disassemble":     return "item.history.action.disassemble".localized
        default:                return e.action.capitalized
        }
    }

    @MainActor
    private func loadHistory() async {
        // No guard — re-fetched on temper / equip / etc, the row is
        // small and the trip is cheap.
        if history.isEmpty { historyLoading = true }
        defer { historyLoading = false }
        do {
            let res: ItemHistoryResponse = try await APIClient.shared.request(
                "GET", "/items/\(item.id.lowercased())/history",
            )
            self.history = res.events
        } catch {
            // Don't blow away an existing list on a transient failure.
            if history.isEmpty {
                self.history = []
            }
        }
    }

    // MARK: - Helpers

    private func kindName(for slug: String) -> String {
        ItemDisplay.name(for: slug)
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

extension DateFormatter {
    /// Acquired-date formatter — used by the item detail sheet, the
    /// memorial sheet, and the inventory's history list. Promoted
    /// from `fileprivate` so cross-file consumers (PetHuntView,
    /// PetMemorialFromInventorySheet) share the same locale-aware
    /// styling without re-declaring their own.
    static let itemAcquired: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
