import SwiftUI

/// Premium-UIN auction surface. Server runs the round loop and broadcasts WS events.
struct UinAuctionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = UinAuctionService.shared
    @StateObject private var items = ItemsService.shared

    @State private var bidInput: String = ""
    @State private var showShop: Bool = false
    @State private var showRecent: Bool = false
    @State private var showOwned: Bool = false
    @State private var showRules: Bool = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
            }
            // Insufficient-balance pill rides above the toolbar as a
            // free-floating chrome element. Putting it inside the
            // bottomBar `ToolbarItemGroup` makes iOS 26 wrap it in a
            // system bubble (the toolbar item background style).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if svc.active != nil && !walletCoversMinBid {
                    insufficientBottomPill
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.clear)
                }
            }
            // simultaneousGesture coexists with ScrollView pan; plain onTapGesture gets swallowed.
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            )
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("games.uin_auction.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { showRules = true } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        walletBadge
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showOwned = true } label: {
                        Label("uin_auction.owned.title".localized,
                              systemImage: "tray.full.fill")
                    }
                    Spacer()
                    Button { showRecent = true } label: {
                        Label("uin_auction.recent.title".localized,
                              systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
            .sheet(isPresented: $showShop) {
                BuyTokensSheet().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showRules) {
                UinAuctionRulesSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showRecent) {
                RecentWinnersSheet().presentationDetents([.large])
            }
            .sheet(isPresented: $showOwned) {
                OwnedUINsSheet().presentationDetents([.large])
            }
            .task { await svc.refresh() }
            .refreshable { await svc.refresh() }
            .onAppear { svc.expand() }
            .onDisappear { svc.minimize() }
            .alert("uin_auction.alert.title".localized,
                   isPresented: Binding(
                       get: { alertMessage != nil },
                       set: { if !$0 { alertMessage = nil } }),
                   actions: {
                       Button("common.ok".localized, role: .cancel) {}
                   }, message: {
                       Text(alertMessage ?? "")
                   })
            .onChange(of: svc.lastError) { msg in
                if let m = msg, !m.isEmpty {
                    alertMessage = m
                    svc.acknowledgeError()
                }
            }
            .onChange(of: svc.celebrateWonUIN) { uin in
                if let uin {
                    alertMessage = String(format: "uin_auction.celebrate.won".localized, uin)
                    svc.acknowledgeCelebration()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let auction = svc.active {
                    heroBlock(auction)
                    timerBlock(auction)
                    highBidBlock(auction)
                    bidComposerBlock(auction)
                    bidsHistory
                } else {
                    waitingBlock
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    // MARK: - blocks

    private func heroBlock(_ a: UinAuction) -> some View {
        VStack(spacing: 8) {
            Text("uin_auction.hero.kicker".localized)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.Color.textSecondary)
            // `verbatim:` skips LocalizedStringKey so the UIN doesn't get a thousands separator.
            Text(verbatim: "\(a.uin)")
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
            tierBadge(a.tier)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(14)
    }

    private func tierBadge(_ tier: String) -> some View {
        let (label, color): (String, Color) = {
            switch tier {
            case "legendary": return ("uin_auction.tier.legendary".localized, .orange)
            case "mid":       return ("uin_auction.tier.mid".localized, .purple)
            default:          return ("uin_auction.tier.common".localized, Theme.Color.accent)
            }
        }()
        return Text(label.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color)
            .cornerRadius(4)
    }

    private func timerBlock(_ a: UinAuction) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let remaining = max(0, a.endsAt.timeIntervalSince(ctx.date))
            let inSoftClose = remaining <= 30 && remaining > 0
            timerBlockContent(remaining: remaining, inSoftClose: inSoftClose)
        }
    }

    @ViewBuilder
    private func timerBlockContent(remaining: TimeInterval, inSoftClose: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: inSoftClose ? "bolt.fill" : "timer")
                    .foregroundColor(inSoftClose ? .red : Theme.Color.accent)
                Text(formatRemaining(remaining))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(inSoftClose ? .red : Theme.Color.textPrimary)
                Spacer()
                if inSoftClose {
                    softCloseBadge
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if inSoftClose {
                Text("uin_auction.soft_close.note".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .background(Theme.Color.bgSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(inSoftClose ? Color.red.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }

    private var softCloseBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.system(size: 10))
            Text("uin_auction.soft_close.badge".localized)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .tracking(1.5)
        .foregroundColor(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.red)
        .cornerRadius(4)
    }

    private func highBidBlock(_ a: UinAuction) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("uin_auction.high_bid".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                HStack(spacing: 4) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 18, height: 18)
                    Text("\(a.highBid > 0 ? a.highBid : a.startingBid)")
                        .font(.system(.title2, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.Color.textPrimary)
                }
                if a.highBid == 0 {
                    Text("uin_auction.no_bids_yet".localized)
                        .font(.caption.italic())
                        .foregroundColor(Theme.Color.textSecondary)
                } else if let nick = a.highBidderNickname {
                    let isMe = a.highBidderUIN == AuthService.shared.ownUIN
                    Text(isMe ? "uin_auction.you_lead".localized : String(format: "uin_auction.lead_by".localized, nick))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isMe ? Theme.Color.accent : Theme.Color.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("uin_auction.min_next".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                Text("\(svc.minNextBid)")
                    .font(.system(.body, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(10)
    }

    private func bidComposerBlock(_ a: UinAuction) -> some View {
        let canAfford = walletCoversMinBid
        let parsedBid = Int(bidInput.trimmingCharacters(in: .whitespaces)) ?? 0
        let validBid = parsedBid >= svc.minNextBid && parsedBid <= items.wallet.tokens
        return HStack(spacing: 10) {
            TextField(String(format: "uin_auction.bid_placeholder".localized, svc.minNextBid),
                      text: $bidInput)
                .keyboardType(.numberPad)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(8)
            if canAfford {
                Button {
                    Task { await place(bid: parsedBid) }
                } label: {
                    Text("uin_auction.cta.bid".localized)
                        .font(.system(.callout, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(validBid ? Theme.Color.accent : Theme.Color.divider)
                        .cornerRadius(8)
                }
                .disabled(!validBid)
                .buttonStyle(.plain)
            } else {
                Button { showShop = true } label: {
                    Text("uin_auction.cta.topup".localized)
                        .font(.system(.callout, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Theme.Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var walletCoversMinBid: Bool {
        items.wallet.tokens >= svc.minNextBid
    }

    private var insufficientBottomPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text("uin_auction.insufficient_hint".localized)
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.red)
        .cornerRadius(6)
    }

    private var bidsHistory: some View {
        let visibleBids: [UinAuctionBid] = Array(svc.bids.prefix(20))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("uin_auction.history.title".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
            if visibleBids.isEmpty {
                HStack {
                    Text("uin_auction.history.empty".localized)
                        .font(.caption.italic())
                        .foregroundColor(Theme.Color.textSecondary)
                        .padding(.vertical, 4)
                    Spacer()
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(visibleBids, id: \UinAuctionBid.id) { (b: UinAuctionBid) in
                        HStack {
                            Text(b.bidderNickname)
                                .font(.system(.callout, weight: .semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                            Spacer()
                            HStack(spacing: 3) {
                                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                    .frame(width: 12, height: 12)
                                Text("\(b.amount)")
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    private var waitingBlock: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 80)
            Text("uin_auction.waiting.title".localized)
                .font(.title3.bold())
                .foregroundColor(Theme.Color.textPrimary)
            Text("uin_auction.waiting.body".localized)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - actions

    private func place(bid: Int) async {
        let result = await svc.placeBid(amount: bid)
        switch result {
        case .success:
            bidInput = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .bidTooLow(let min):
            alertMessage = String(format: "uin_auction.error.bid_too_low".localized, min)
        case .insufficientTokens(let req, let have):
            alertMessage = String(format: "uin_auction.error.insufficient".localized, req, have)
        case .alreadyHighBidder:
            alertMessage = "uin_auction.error.already_lead".localized
        case .ended:
            alertMessage = "uin_auction.error.ended".localized
        case .other(let m):
            alertMessage = m
        }
    }

    @ViewBuilder
    private var walletBadge: some View {
        let tokens = items.wallet.tokens
        HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                .frame(width: 18, height: 18)
            Text(verbatim: "\(tokens)")
                .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.Color.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.35), value: tokens)
        }
        .padding(.trailing, 8)
    }

    private func formatRemaining(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

// MARK: - Recent winners sheet

private struct RecentWinnersSheet: View {
    @StateObject private var svc = UinAuctionService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if svc.recentWinners.isEmpty {
                    Text("uin_auction.recent.empty".localized)
                        .font(.callout.italic())
                        .foregroundColor(Theme.Color.textSecondary)
                } else {
                    ForEach(svc.recentWinners, id: \UinAuctionRecentWinner.id) { (w: UinAuctionRecentWinner) in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(w.uin)")
                                    .font(.system(.headline, design: .monospaced))
                                    .foregroundColor(Theme.Color.textPrimary)
                                if let nick = w.winnerNickname {
                                    Text(String(format: "uin_auction.recent.won_by".localized, nick))
                                        .font(.caption)
                                        .foregroundColor(Theme.Color.textSecondary)
                                }
                            }
                            Spacer()
                            HStack(spacing: 3) {
                                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                                    .frame(width: 12, height: 12)
                                Text("\(w.winningBid)")
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("uin_auction.recent.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task { await svc.refreshRecent() }
        }
    }
}

// MARK: - Owned UINs sheet (inventory)

/// Not `private` — `InventoryView`'s toolbar menu reuses this sheet so
/// the user can manage their won UINs without having to navigate to
/// the auction screen.
struct OwnedUINsSheet: View {
    @StateObject private var svc = UinAuctionService.shared
    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmActivateUIN: Int?
    @State private var activating: Bool = false
    @State private var alertMessage: String?
    @State private var sellTarget: OwnedUIN?
    @State private var removeTarget: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("uin_auction.owned.body".localized)
                        .font(.footnote)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                if svc.owned.isEmpty {
                    Section {
                        Text("uin_auction.owned.empty".localized)
                            .font(.callout.italic())
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                } else {
                    Section {
                        ForEach(svc.owned, id: \OwnedUIN.id) { (o: OwnedUIN) in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(o.uin)")
                                        .font(.system(.headline, design: .monospaced))
                                        .foregroundColor(Theme.Color.textPrimary)
                                    Text(tierLabel(o.tier))
                                        .font(.caption)
                                        .foregroundColor(Theme.Color.textSecondary)
                                }
                                Spacer()
                                Menu {
                                    Button {
                                        sellTarget = o
                                    } label: {
                                        Label(
                                            "uin_auction.owned.sell".localized,
                                            systemImage: "tag"
                                        )
                                    }
                                    Button(role: .destructive) {
                                        removeTarget = o.uin
                                    } label: {
                                        Label(
                                            "uin_auction.owned.remove".localized,
                                            systemImage: "trash"
                                        )
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(Theme.Color.textSecondary)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button {
                                    confirmActivateUIN = o.uin
                                } label: {
                                    Text("uin_auction.owned.activate".localized)
                                        .font(.system(.caption, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Theme.Color.accent)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("uin_auction.owned.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task { await svc.refreshOwned() }
            .confirmationDialog(
                String(format: "uin_auction.owned.confirm.title".localized, confirmActivateUIN ?? 0),
                isPresented: Binding(
                    get: { confirmActivateUIN != nil },
                    set: { if !$0 { confirmActivateUIN = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(format: "uin_auction.owned.confirm.button".localized, 99)) {
                    if let target = confirmActivateUIN {
                        Task { await activate(target) }
                    }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("uin_auction.owned.confirm.message".localized)
            }
            .confirmationDialog(
                String(format: "uin_auction.owned.remove.confirm.title".localized, removeTarget ?? 0),
                isPresented: Binding(
                    get: { removeTarget != nil },
                    set: { if !$0 { removeTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("uin_auction.owned.remove.confirm.button".localized, role: .destructive) {
                    if let target = removeTarget {
                        Task {
                            let ok = await svc.removeOwned(uin: target)
                            if !ok {
                                alertMessage = "uin_auction.owned.remove.error".localized
                            }
                            removeTarget = nil
                        }
                    }
                }
                Button("common.cancel".localized, role: .cancel) { removeTarget = nil }
            } message: {
                Text("uin_auction.owned.remove.confirm.message".localized)
            }
            .alert("uin_auction.alert.title".localized,
                   isPresented: Binding(
                       get: { alertMessage != nil },
                       set: { if !$0 { alertMessage = nil } }),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
            .sheet(item: $sellTarget) { target in
                SellOwnedUinSheet(uin: target.uin, tier: target.tier) {
                    Task { await svc.refreshOwned() }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func activate(_ uin: Int) async {
        activating = true
        let result = await svc.activate(uin: uin)
        activating = false
        switch result {
        case .success(let newUIN):
            alertMessage = String(format: "uin_auction.owned.activated".localized, newUIN)
            confirmActivateUIN = nil
        case .insufficientTokens(let req, let have):
            alertMessage = String(format: "uin_auction.error.insufficient".localized, req, have)
        case .cooldown:
            alertMessage = "settings.migrate.error.cooldown".localized
        case .other(let msg):
            alertMessage = msg.isEmpty ? "settings.migrate.error.generic".localized : msg
        }
    }

    private func tierLabel(_ tier: String) -> String {
        switch tier {
        case "legendary": return "uin_auction.tier.legendary".localized
        case "mid":       return "uin_auction.tier.mid".localized
        default:          return "uin_auction.tier.common".localized
        }
    }
}


// MARK: - Rules sheet

private struct UinAuctionRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        icon: "number.circle.fill",
                        title: "uin_auction.rules.what.title".localized,
                        body: "uin_auction.rules.what.body".localized,
                    )
                    section(
                        icon: "hammer.fill",
                        title: "uin_auction.rules.bidding.title".localized,
                        body: "uin_auction.rules.bidding.body".localized,
                    )
                    section(
                        icon: "bolt.fill",
                        title: "uin_auction.rules.softclose.title".localized,
                        body: "uin_auction.rules.softclose.body".localized,
                    )
                    section(
                        icon: "tray.full.fill",
                        title: "uin_auction.rules.win.title".localized,
                        body: "uin_auction.rules.win.body".localized,
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("uin_auction.rules.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
        }
    }

    private func section(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Color.accent)
                Text(title)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            Text(body)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .lineSpacing(2)
        }
    }
}

// MARK: - Sell owned UIN on marketplace

struct SellOwnedUinSheet: View {
    let uin: Int
    let tier: String
    let onListed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var market = MarketService.shared
    @State private var priceText: String = ""
    @State private var busy: Bool = false
    @State private var alertMessage: String?

    private var price: Int? { Int(priceText) }
    private var validPrice: Bool {
        guard let p = price else { return false }
        return p >= 1 && p <= 9_999_999
    }

    private var payoutHint: String? {
        guard let p = price, validPrice else { return nil }
        // 5% house fee, floor-rounded — must match backend `_seller_payout()`.
        let payout = p - (p * 500 / 10_000)
        return String(format: "market.sell.payout_hint".localized) + ": \(payout)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text(verbatim: "#\(uin)")
                            .font(.system(.title, design: .monospaced).weight(.bold))
                            .foregroundColor(Theme.Color.textPrimary)
                        Text(tierLabel(tier).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(12)

                    Text("market.sell.body".localized)
                        .font(.footnote)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 20, height: 20)
                        TextField("market.sell.price_placeholder".localized, text: $priceText)
                            .keyboardType(.numberPad)
                            .font(.body.monospacedDigit())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(8)

                    if let hint = payoutHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundColor(Theme.Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await listIt() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text((busy ? "market.sell.busy" : "market.sell.cta").localized)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(validPrice ? Theme.Color.accent : Theme.Color.divider)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(!validPrice || busy)

                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("market.sell.title".localized)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("market.alert.title".localized,
                   isPresented: Binding(
                       get: { alertMessage != nil },
                       set: { if !$0 { alertMessage = nil } }),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
        }
    }

    private func listIt() async {
        guard let p = price, validPrice else { return }
        busy = true
        defer { busy = false }
        let result = await market.listUin(uin: uin, priceTokens: p)
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onListed()
            dismiss()
        case .notInInventory:
            alertMessage = "market.error.uin_not_in_inventory".localized
        case .alreadyListed:
            alertMessage = "market.error.already_listed".localized
        case .tooManyListings(let max):
            alertMessage = String(format: "market.error.too_many".localized, max)
        case .other(let m):
            alertMessage = m
        }
    }

    private func tierLabel(_ tier: String) -> String {
        switch tier {
        case "legendary": return "uin.tier.legendary".localized
        case "mid":       return "uin.tier.mid".localized
        default:          return "uin.tier.common".localized
        }
    }
}

private struct NoBounceWhenFits: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}
