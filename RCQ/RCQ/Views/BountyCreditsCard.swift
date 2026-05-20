import SwiftUI

/// Settings card that surfaces pending bug-bounty + Daily-QA credits.
///
/// Pre-launch, jetons are free and have no perceived monetary value,
/// so granting bounty rewards directly to the wallet feels weightless
/// to testers. Instead, every accepted bounty + completed daily-QA
/// run lands in the server-side `bounty_credits` table. This card
/// tells the tester how many they've accumulated and that the lump
/// sum unlocks on launch — converting goodwill into anticipation.
///
/// Lazy load: card calls `/bounty_credits/me` on first render. If the
/// user has zero pending and zero redeemed credits, the card collapses
/// to a single line ("No bug bounty credits yet — find a bug to earn
/// some") so it doesn't waste vertical space for testers who haven't
/// engaged with the program.
struct BountyCreditsCard: View {
    @State private var pendingTotal: Int = 0
    @State private var redeemedTotal: Int = 0
    @State private var items: [Item] = []
    @State private var loading: Bool = true
    @State private var loadError: String?
    @State private var showFullHistory: Bool = false

    struct Item: Identifiable {
        let id: Int
        let source: String
        let reason: String
        let amount: Int
        let grantedAt: Date
    }

    /// How many rows to show inline in Settings before the
    /// "view all" affordance — the rest live in the history sheet.
    private static let inlineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading {
                HStack {
                    ProgressView().tint(Theme.Color.accent)
                    Text("bounty_credits.loading".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if loadError != nil {
                Text("bounty_credits.error".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            } else if pendingTotal == 0 && redeemedTotal == 0 {
                empty
            } else {
                content
            }
        }
        .task { await load() }
        .sheet(isPresented: $showFullHistory) {
            BountyHistorySheet(items: items)
        }
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "ladybug")
                .foregroundColor(Theme.Color.textSecondary)
            Text("bounty_credits.empty".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            if !items.isEmpty {
                Divider().background(Theme.Color.divider)
                ForEach(items.prefix(Self.inlineLimit)) { item in
                    row(item)
                }
                if items.count > Self.inlineLimit {
                    Button {
                        showFullHistory = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(format: "bounty_credits.see_all".localized, items.count))
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundColor(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("bounty_credits.unlock_hint".localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: some View {
        // Two-row layout: section title + big amount chip on right.
        // The amount chip has a 24×24 coin GIF + bold title-sized
        // number — the previous 14×14 coin next to a body-sized
        // number looked starved (the GIF was smaller than the digit
        // height). Pill background tints the chip so it reads as a
        // value, not just decoration.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 20))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 38, height: 38)
                .background(Theme.Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("bounty_credits.title".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("bounty_credits.pending_suffix".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 22, height: 22)
                Text(pendingTotal.formatted())
                    .font(.system(.title3, weight: .bold).monospacedDigit())
                    .foregroundColor(Theme.Color.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.Color.accent.opacity(0.10))
            .clipShape(Capsule())
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.source == "daily_qa" ? "checkmark.seal.fill" : "ladybug.fill")
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.reason.isEmpty ? labelForSource(item.source) : item.reason)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(Self.dateFormatter.string(from: item.grantedAt))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            HStack(spacing: 3) {
                Text("+\(item.amount.formatted())")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundColor(Theme.Color.accent)
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 14, height: 14)
            }
        }
    }

    private func labelForSource(_ source: String) -> String {
        switch source {
        case "daily_qa": return "bounty_credits.source.daily_qa".localized
        case "bug_bounty": return "bounty_credits.source.bug_bounty".localized
        default: return source
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        struct CreditOut: Decodable {
            let id: Int
            let source: String
            let reason: String
            let amount: Int
            let report_id: Int?
            let granted_at: Date
        }
        struct Out: Decodable {
            let pending_total: Int
            let redeemed_total: Int
            let items: [CreditOut]
        }
        do {
            let out: Out = try await APIClient.shared.request("GET", "/bounty_credits/me")
            pendingTotal = out.pending_total
            redeemedTotal = out.redeemed_total
            items = out.items.map {
                Item(id: $0.id, source: $0.source, reason: $0.reason, amount: $0.amount, grantedAt: $0.granted_at)
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Full bug-bounty / Daily-QA credit history — every row, newest
/// first. Opened from the "view all" button on `BountyCreditsCard`
/// when there are more entries than fit inline.
struct BountyHistorySheet: View {
    let items: [BountyCreditsCard.Item]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                List {
                    ForEach(items) { item in
                        row(item)
                            .listRowBackground(Theme.Color.bgSecondary)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("bounty_credits.history_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
    }

    private func row(_ item: BountyCreditsCard.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.source == "daily_qa" ? "checkmark.seal.fill" : "ladybug.fill")
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.reason.isEmpty ? labelForSource(item.source) : item.reason)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(2)
                Text(BountyCreditsCard.dateFormatter.string(from: item.grantedAt))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            HStack(spacing: 3) {
                Text("+\(item.amount.formatted())")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundColor(Theme.Color.accent)
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.vertical, 2)
    }

    private func labelForSource(_ source: String) -> String {
        switch source {
        case "daily_qa": return "bounty_credits.source.daily_qa".localized
        case "bug_bounty": return "bounty_credits.source.bug_bounty".localized
        default: return source
        }
    }
}
