import SwiftUI

/// Compact two-sided trade summary used by the incoming sheet, the
/// outgoing list, and the chat-context preview later. Lays out
/// "what they offer" / "what they ask" as two stacked rows with
/// item tiles + currency chips.
struct TradeSummaryView: View {
    let trade: Trade
    /// `true` when rendering from the recipient's POV (incoming).
    /// Flips the offered/requested labels: from the recipient's side
    /// "their offer" is the proposer's offered side.
    let viewedAsRecipient: Bool

    private var offeredLabel: String {
        (viewedAsRecipient ? "trade.summary.they_offer" : "trade.summary.you_offer").localized
    }
    private var requestedLabel: String {
        (viewedAsRecipient ? "trade.summary.they_ask" : "trade.summary.you_ask").localized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(
                label: offeredLabel,
                items: trade.offeredItems,
                uins: trade.offeredUins,
                tokens: trade.offeredTokens,
                scrolls: trade.offeredScrolls,
            )
            Divider().background(Theme.Color.divider)
            row(
                label: requestedLabel,
                items: trade.requestedItems,
                uins: trade.requestedUins,
                tokens: trade.requestedTokens,
                scrolls: trade.requestedScrolls,
            )
        }
        .padding(14)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    private func row(
        label: String,
        items: [Item],
        uins: [TradeUinChip],
        tokens: Int,
        scrolls: Int,
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .tracking(2)
            if items.isEmpty && uins.isEmpty && tokens == 0 && scrolls == 0 {
                Text("nothing")
                    .font(Theme.Font.statusLabel)
                    .foregroundColor(Theme.Color.textSecondary)
                    .italic()
            } else {
                HStack(spacing: 8) {
                    if tokens > 0 {
                        currencyChip(image: "coin", ext: "gif", count: tokens)
                    }
                    if scrolls > 0 {
                        currencyChip(image: "scroll", ext: "png", count: scrolls)
                    }
                    if !uins.isEmpty {
                        // Same chip rendering as the trade composer +
                        // inline card so a UIN reads identically across
                        // every surface where a trade is displayed.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(uins) { u in uinPill(u) }
                            }
                        }
                    }
                    if !items.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(items) { item in
                                    ItemCard(item: item)
                                        .frame(width: 56, height: 56)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func uinPill(_ chip: TradeUinChip) -> some View {
        let tint: Color = {
            switch chip.tier {
            case "legendary": return Color(hex: 0xC8442A)
            case "mid":       return Color(hex: 0x8E5BD4)
            default:          return Color(hex: 0x6BB12C)
            }
        }()
        // `Text(verbatim:)` so the UIN displays as the raw integer
        // identifier — no thousands separator (which would render
        // `#123,456` in en-locale and `#123 456` in ru-locale).
        return Text(verbatim: "#\(chip.uin)")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.18)))
    }

    private func currencyChip(image: String, ext: String, count: Int) -> some View {
        HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: image, ext: ext)
                .frame(width: 18, height: 18)
            Text("\(count)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.Color.bgPrimary)
        .cornerRadius(4)
    }
}
