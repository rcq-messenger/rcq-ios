import SwiftUI

/// Compose-a-trade screen — port of IX `TradeView` repainted in
/// RCQ's palette. Two stacked sections:
///   - "Your offer" — your items + tokens / scrolls
///   - "Their side" — their items + tokens / scrolls
/// At least one side must have something on it. The trade-kind chip
/// auto-detects gift / sale / purchase / trade based on what's
/// filled.
///
/// Recipient items are pulled from the public-inventory endpoint —
/// gated by their `InventorySettings.public`. A private inventory
/// shows an "inventory hidden" empty state with the currency fields
/// still usable (so token-only gifts / buys still work).
struct TradeProposeView: View {
    let recipientUIN: Int
    let recipientNickname: String

    @StateObject private var items = ItemsService.shared
    @StateObject private var trades = TradesService.shared
    @StateObject private var uinAuction = UinAuctionService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMine: Set<String> = []
    @State private var selectedTheirs: Set<String> = []
    /// UIN selections per side. Tracks the raw BigInt uin values
    /// (parallel to the item id sets above). Server validates that
    /// each picked UIN sits in the right party's `OwnedUin`
    /// inventory, isn't on a marketplace listing, and isn't on
    /// another pending trade.
    @State private var selectedMyUins: Set<Int> = []
    @State private var selectedTheirUins: Set<Int> = []
    @State private var offeredTokens = ""
    @State private var offeredScrolls = ""
    @State private var requestedTokens = ""
    @State private var requestedScrolls = ""
    @State private var note = ""

    @State private var theirItems: [Item] = []
    /// UINs from the recipient's public inventory. Comes back from
    /// `/users/{uin}/inventory` alongside items + privacy flag.
    @State private var theirUins: [TradeInvUin] = []
    @State private var theirInventoryPublic: Bool = true
    @State private var loadingTheirs = true
    @State private var sending = false
    @State private var sentBanner = false
    @State private var errorMessage: String?
    /// Drives the "are you sure this is a gift?" alert. Send tap
    /// for a gift-shape (something offered, nothing requested)
    /// flips this true; the alert's confirm action calls the real
    /// `send()`. Stops the user from accidentally one-way-gifting
    /// when they meant to ask for something in return but forgot
    /// to fill the requested side.
    @State private var showGiftConfirm: Bool = false

    /// True iff the current form represents a one-way transfer:
    /// something on offer, nothing requested back. Mirrors the
    /// backend's `is_gift` flag, kept on the client so we can
    /// gate the confirmation prompt without round-tripping.
    private var isGiftShape: Bool {
        hasOffered && !hasRequested
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 5,
    )

    private var myItems: [Item] {
        items.items.sorted { $0.rarity.rollWeight < $1.rarity.rollWeight }
    }

    private var offeredTok: Int { Int(offeredTokens) ?? 0 }
    private var offeredScr: Int { Int(offeredScrolls) ?? 0 }
    private var requestedTok: Int { Int(requestedTokens) ?? 0 }
    private var requestedScr: Int { Int(requestedScrolls) ?? 0 }

    private var hasOffered: Bool {
        !selectedMine.isEmpty
            || !selectedMyUins.isEmpty
            || offeredTok > 0
            || offeredScr > 0
    }
    private var hasRequested: Bool {
        !selectedTheirs.isEmpty
            || !selectedTheirUins.isEmpty
            || requestedTok > 0
            || requestedScr > 0
    }

    private var canSend: Bool {
        guard !sending else { return false }
        if !(hasOffered || hasRequested) { return false }
        if offeredTok > items.wallet.tokens { return false }
        if offeredScr > items.wallet.scrolls { return false }
        return true
    }

    private var tradeKind: String {
        switch (hasOffered, hasRequested) {
        case (true, false):  return "trade.kind.gift".localized
        case (false, true):  return "trade.kind.buy".localized
        case (true, true):
            if !selectedMine.isEmpty || !selectedTheirs.isEmpty { return "trade.kind.trade".localized }
            return "trade.kind.swap".localized
        default: return "trade.kind.empty".localized
        }
    }

    /// Send-button copy. Three states:
    /// - sending → "Отправляем…"
    /// - empty (nothing on either side) → plain "Выбери что отправить"
    ///   (button stays disabled — we just don't want the previous
    ///   "Отправить пусто" eyesore the format string produced)
    /// - normal → "Отправить подарок" / "Отправить обмен" / etc.
    private var buttonLabel: String {
        if sending { return "trade.cta.sending".localized }
        if !(hasOffered || hasRequested) { return "trade.cta.empty_prompt".localized }
        return String(format: "trade.cta.send".localized, tradeKind.lowercased())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        kindBanner
                        section(
                            title: "trade.section.your".localized,
                            owner: "trade.section.your.owner".localized,
                            tokensInput: $offeredTokens,
                            scrollsInput: $offeredScrolls,
                            walletTokens: items.wallet.tokens,
                            walletScrolls: items.wallet.scrolls,
                            inventory: myItems,
                            selected: $selectedMine,
                            ownedUins: uinAuction.owned.map {
                                TradeInvUin(uin: $0.uin, tier: $0.tier, listed: false)
                            },
                            selectedUins: $selectedMyUins,
                            emptyText: "trade.section.your.empty".localized,
                        )
                        section(
                            title: "trade.section.theirs".localized,
                            owner: recipientNickname,
                            tokensInput: $requestedTokens,
                            scrollsInput: $requestedScrolls,
                            walletTokens: nil,
                            walletScrolls: nil,
                            inventory: theirItems,
                            selected: $selectedTheirs,
                            ownedUins: theirUins,
                            selectedUins: $selectedTheirUins,
                            emptyText: String(
                                format: (theirInventoryPublic
                                    ? "trade.section.theirs.empty"
                                    : "trade.section.theirs.private").localized,
                                recipientNickname
                            ),
                        )
                        noteField
                        if let err = errorMessage {
                            Text(err)
                                .font(Theme.Font.statusLabel)
                                .foregroundColor(.red)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 100)
                }
                if sentBanner {
                    sentToast
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: sentBanner)
            .safeAreaInset(edge: .bottom) {
                sendBar.background(.ultraThinMaterial)
            }
            .navigationTitle("trade.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.close".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
            }
            .task {
                await items.refreshInventory()
                // Pull my owned UINs so the chip strip on "Your offer"
                // populates immediately. UinAuctionService caches on
                // its own; this is just ensuring the latest snapshot.
                await uinAuction.refreshOwned()
                await loadTheirInventory()
            }
        }
    }

    // MARK: - Kind banner

    private var kindBanner: some View {
        HStack(spacing: 8) {
            Text(tradeKind.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .tracking(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.Color.accent)
                .cornerRadius(4)
            Text(String(format: "trade.with".localized, recipientNickname))
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
    }

    // MARK: - Section block

    @ViewBuilder
    private func section(
        title: String,
        owner: String,
        tokensInput: Binding<String>,
        scrollsInput: Binding<String>,
        walletTokens: Int?,
        walletScrolls: Int?,
        inventory: [Item],
        selected: Binding<Set<String>>,
        ownedUins: [TradeInvUin],
        selectedUins: Binding<Set<Int>>,
        emptyText: String,
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                Text(owner)
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            HStack(spacing: 10) {
                currencyField(
                    image: "coin", ext: "gif",
                    text: tokensInput, walletAmount: walletTokens, kind: "tokens",
                )
                currencyField(
                    image: "gem", ext: "gif",
                    text: scrollsInput, walletAmount: walletScrolls, kind: "scrolls",
                )
            }
            // UIN chip strip — only renders when this side has any
            // UINs in inventory. Tap toggles selection. Listed UINs
            // (active marketplace listing) render greyed out and
            // tapping shows a hint instead of toggling.
            if !ownedUins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ownedUins) { o in
                            uinChip(o, selected: selectedUins)
                        }
                    }
                }
            }
            if inventory.isEmpty {
                Text(emptyText)
                    .font(Theme.Font.statusLabel)
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(inventory) { item in
                        Button {
                            if selected.wrappedValue.contains(item.id) {
                                selected.wrappedValue.remove(item.id)
                            } else {
                                selected.wrappedValue.insert(item.id)
                            }
                        } label: {
                            ItemCard(item: item)
                                .overlay(
                                    selected.wrappedValue.contains(item.id)
                                        ? RoundedRectangle(cornerRadius: 6)
                                            .stroke(Theme.Color.accent, lineWidth: 3)
                                        : nil
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    /// Tier-tinted chip rendering a single tradeable UIN. Tap toggles
    /// selection; listed UINs (active marketplace lot) render with a
    /// reduced opacity + tap is a no-op (user has to cancel the
    /// listing first to free it).
    ///
    /// `Text(verbatim:)` is mandatory for UIN rendering anywhere in
    /// the app — `Text("\(intValue)")` would route through
    /// `LocalizedStringKey` interpolation and add locale-aware
    /// thousands separators (`#123,456` in en, `#123 456` in ru).
    /// UINs are identifiers, not quantities — they should NEVER be
    /// thousands-separated.
    private func uinChip(_ o: TradeInvUin, selected: Binding<Set<Int>>) -> some View {
        let isSelected = selected.wrappedValue.contains(o.uin)
        let tint: Color = {
            switch o.tier {
            case "legendary": return Color(hex: 0xC8442A)
            case "mid":       return Color(hex: 0x8E5BD4)
            default:          return Color(hex: 0x6BB12C)
            }
        }()
        return Button {
            guard !o.listed else { return }
            if isSelected { selected.wrappedValue.remove(o.uin) }
            else { selected.wrappedValue.insert(o.uin) }
        } label: {
            Text(verbatim: "#\(o.uin)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(isSelected ? .white : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? tint : tint.opacity(0.18))
                )
                .opacity(o.listed ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(o.listed)
    }

    private func currencyField(
        image: String,
        ext: String,
        text: Binding<String>,
        walletAmount: Int?,
        kind: String,
    ) -> some View {
        HStack(spacing: 8) {
            ItemAssetImage(bundleSubdir: "Items", filename: image, ext: ext)
                .frame(width: 22, height: 22)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .font(Theme.Font.mono)
                .foregroundColor(Theme.Color.textPrimary)
            if let walletAmount {
                Text("/ \(walletAmount)")
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgPrimary)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Theme.Color.divider, lineWidth: 1))
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("trade.note".localized)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .tracking(2)
            TextField("", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .font(Theme.Font.statusLabel)
                .padding(10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(6)
        }
    }

    private var sendBar: some View {
        HStack(spacing: 10) {
            Button {
                if isGiftShape {
                    // Force a confirm dialog for one-way gifts —
                    // the empty "their side" panel reads as
                    // intentional far too easily, especially when
                    // the user actually wanted a 2-way swap and
                    // forgot to pick anything from the recipient's
                    // inventory.
                    showGiftConfirm = true
                } else {
                    Task { await send() }
                }
            } label: {
                // Three-state label so the disabled-empty case
                // doesn't read as the goofy "Отправить пусто" the
                // generic format string produced. When neither side
                // has anything we surface a plain prompt; once the
                // user picks something we switch to the real
                // tradeKind-based action label.
                Text(buttonLabel)
                    .font(Theme.Font.nickname)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(canSend ? Theme.Color.accent : Theme.Color.divider)
                    .cornerRadius(8)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .alert("trade.gift_confirm.title".localized, isPresented: $showGiftConfirm) {
            Button("trade.gift_confirm.cancel".localized, role: .cancel) {}
            Button("trade.gift_confirm.send".localized) {
                Task { await send() }
            }
        } message: {
            Text(String(
                format: "trade.gift_confirm.body".localized,
                recipientNickname
            ))
        }
    }

    private var sentToast: some View {
        // Same glass-pill shape and slide-down anchor as the
        // inventory bulk-disassemble toast so the "feedback at the
        // top of the screen" pattern is consistent across the app.
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                Text("trade.toast.sent".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
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

    // MARK: - Actions

    @MainActor
    private func loadTheirInventory() async {
        loadingTheirs = true
        defer { loadingTheirs = false }
        struct Resp: Codable {
            let items: [Item]
            // Backend ships an empty array for users with no UINs and
            // omits the field entirely on legacy clients — decoding
            // is defensive (default empty).
            let uins: [TradeInvUin]?
            let `public`: Bool
        }
        do {
            let res: Resp = try await APIClient.shared.request(
                "GET", "/users/\(recipientUIN)/inventory",
            )
            self.theirItems = res.items.sorted { $0.rarity.rollWeight < $1.rarity.rollWeight }
            self.theirUins = res.uins ?? []
            self.theirInventoryPublic = res.public
        } catch {
            // 403 → private inventory; show empty state with the
            // private-inventory label and let the user proceed with
            // currency-only trade if they want.
            self.theirItems = []
            self.theirUins = []
            self.theirInventoryPublic = false
        }
    }

    @MainActor
    private func send() async {
        guard canSend else { return }
        sending = true
        defer { sending = false }
        errorMessage = nil
        let offered = myItems.filter { selectedMine.contains($0.id) }
        let requested = theirItems.filter { selectedTheirs.contains($0.id) }
        let trade = await trades.propose(
            toUIN: recipientUIN,
            offeredItems: offered,
            requestedItems: requested,
            offeredUins: Array(selectedMyUins),
            requestedUins: Array(selectedTheirUins),
            offeredTokens: offeredTok,
            offeredScrolls: offeredScr,
            requestedTokens: requestedTok,
            requestedScrolls: requestedScr,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : note,
        )
        if trade != nil {
            // Mutation triggers the parent's `.animation(value:)`.
            sentBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dismiss()
            }
        } else {
            errorMessage = "trade.send.error".localized
        }
    }
}

/// Compact UIN snapshot used inside the trade composer's chip strip.
/// Shape mirrors the backend's `OwnedUinSummary` from
/// `/me/inventory` and `/users/{uin}/inventory`. `listed` greys out
/// the chip and disables tap when the UIN is currently up on the
/// marketplace (server would reject the trade with `uins_listed`
/// otherwise — preempting in UI keeps the round-trip cleaner).
struct TradeInvUin: Codable, Hashable, Identifiable {
    let uin: Int
    let tier: String
    let listed: Bool

    var id: Int { uin }
}
