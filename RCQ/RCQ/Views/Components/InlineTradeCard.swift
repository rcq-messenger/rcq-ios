import SwiftUI

/// Inline "trade as a chat message" card. Pure renderer — caller wraps in a Button to make interactive.
struct InlineTradeCard: View {
    let trade: Trade
    let isFromMe: Bool
    var onItemTap: ((Item) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                leadingGlyph
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerLabel)
                        .font(Theme.Font.nickname)
                        .foregroundColor(Theme.Color.textPrimary)
                    if let counterpartyName {
                        Text(counterpartyName)
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                Spacer(minLength: 4)
                Text(relativeTime(trade.createdAt))
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            summaryLine
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.accent.opacity(0.10))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        let myUIN = AuthService.shared.ownUIN ?? -1
        let peerUIN = isFromMe ? trade.toUIN : trade.fromUIN
        if peerUIN != myUIN,
           let contact = ContactService.shared.contacts.first(where: { $0.uin == peerUIN }) {
            StatusIcon(status: contact.status, size: 24)
        } else {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(Theme.Color.accent)
        }
    }

    private var counterpartyName: String? {
        let myUIN = AuthService.shared.ownUIN ?? -1
        let peerUIN = isFromMe ? trade.toUIN : trade.fromUIN
        if peerUIN == myUIN { return nil }
        if let contact = ContactService.shared.contacts.first(where: { $0.uin == peerUIN }) {
            return "\(contact.nickname) · #" + String(peerUIN)
        }
        return "#" + String(peerUIN)
    }

    private var headerLabel: String {
        if trade.isGift {
            return (isFromMe ? "trade.gift.sent" : "trade.gift.received").localized
        }
        if trade.isBuyOnly {
            return (isFromMe ? "trade.buy.sent" : "trade.buy.received").localized
        }
        return (isFromMe ? "trade.offer.sent" : "trade.offer.received").localized
    }

    private var summaryLine: some View {
        HStack(alignment: .center, spacing: 10) {
            sideBlock(
                items: trade.offeredItems,
                uins: trade.offeredUins,
                tokens: trade.offeredTokens,
                scrolls: trade.offeredScrolls,
            )
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Color.textMono)
            sideBlock(
                items: trade.requestedItems,
                uins: trade.requestedUins,
                tokens: trade.requestedTokens,
                scrolls: trade.requestedScrolls,
            )
            Spacer(minLength: 0)
        }
    }

    private func sideBlock(items: [Item], uins: [TradeUinChip], tokens: Int, scrolls: Int) -> some View {
        HStack(spacing: 6) {
            if items.isEmpty && uins.isEmpty && tokens == 0 && scrolls == 0 {
                Text("—")
                    .font(.callout)
                    .foregroundColor(Theme.Color.textMono)
            } else {
                if !items.isEmpty {
                    HStack(spacing: -10) {
                        ForEach(items.prefix(3)) { item in
                            Group {
                                if let onItemTap {
                                    Button { onItemTap(item) } label: {
                                        ItemCard(item: item, showMintOverlay: false)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    ItemCard(item: item, showMintOverlay: false)
                                }
                            }
                            .frame(width: 36, height: 36)
                        }
                    }
                    if items.count > 3 {
                        Text("+\(items.count - 3)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                if !uins.isEmpty {
                    ForEach(uins.prefix(2)) { u in
                        uinPill(u)
                    }
                    if uins.count > 2 {
                        Text("+\(uins.count - 2)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                if tokens > 0 {
                    HStack(spacing: 3) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 18, height: 18)
                        Text("\(tokens)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                if scrolls > 0 {
                    HStack(spacing: 3) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                            .frame(width: 18, height: 18)
                        Text("\(scrolls)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
            }
        }
    }

    // Text(verbatim:) — UIN is an identifier, default Text would thousands-separate it.
    private func uinPill(_ chip: TradeUinChip) -> some View {
        let tint: Color = {
            switch chip.tier {
            case "legendary": return Color(hex: 0xC8442A)
            case "mid":       return Color(hex: 0x8E5BD4)
            default:          return Color(hex: 0x6BB12C)
            }
        }()
        return Text(verbatim: "#\(chip.uin)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
