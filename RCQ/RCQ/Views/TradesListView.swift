import SwiftUI

/// Clean two-section list of pending trades. Each row uses the same
/// inline-card aesthetic the chat shows (`InlineTradeCard`), with
/// inline action buttons stacked underneath — accept/decline on
/// incoming, single cancel on outgoing.
///
/// Avoids the previous "card-inside-row" look that doubled the
/// summary up unnecessarily; this version is single-card-per-trade,
/// IX-flavoured.
struct TradesListView: View {
    @StateObject private var trades = TradesService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var inspectingTrade: Trade?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if trades.incoming.isEmpty && trades.outgoing.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if !trades.incoming.isEmpty {
                                section("trades.section.incoming".localized, color: Theme.Color.accent) {
                                    ForEach(trades.incoming) { trade in
                                        tradeRow(trade, isFromMe: false)
                                    }
                                }
                            }
                            if !trades.outgoing.isEmpty {
                                section("trades.section.outgoing".localized, color: Theme.Color.textSecondary) {
                                    ForEach(trades.outgoing) { trade in
                                        tradeRow(trade, isFromMe: true)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
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
            }
            .task { await trades.refreshAll() }
            .refreshable { await trades.refreshAll() }
            .sheet(item: $inspectingTrade) { trade in
                SingleTradeSheet(trade: trade)
                    .presentationDetents([.fraction(0.5), .large])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text("trades.empty.title".localized)
                .font(Theme.Font.nickname)
                .foregroundColor(Theme.Color.textPrimary)
            Text("trades.empty.body".localized)
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, color: Color, @ViewBuilder _ content: () -> Content,
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .tracking(2)
            VStack(spacing: 10) {
                content()
            }
        }
    }

    // MARK: - Row

    /// Trade card row — entire card tappable → `SingleTradeSheet`
    /// where Accept / Decline / Cancel + Open-chat actions live.
    /// The list itself is just a navigator now; previous design
    /// had inline action buttons on every row that, combined with
    /// long card content, made the list feel busy.
    private func tradeRow(_ trade: Trade, isFromMe: Bool) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            inspectingTrade = trade
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                InlineTradeCard(trade: trade, isFromMe: isFromMe)
                if let note = trade.note, !note.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                        Text(note)
                            .font(.callout.italic())
                            .foregroundColor(Theme.Color.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
