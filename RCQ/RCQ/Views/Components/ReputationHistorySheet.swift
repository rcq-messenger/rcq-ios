import SwiftUI

/// History of reputation grants — segmented between "received" and
/// "sent". Anonymous received grants render with an "Anonymous"
/// pill instead of a donor row. Tapping a non-anonymous row opens
/// the counterparty's profile.
struct ReputationHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var direction: Direction = .received
    @State private var received: [HistoryEntry] = []
    @State private var sent: [HistoryEntry] = []
    @State private var loading: Bool = false
    @State private var viewInfoForUIN: Int?

    enum Direction: String, CaseIterable, Identifiable {
        case received, sent
        var id: String { rawValue }
        var localizedLabel: String {
            switch self {
            case .received: return "reputation.history.tab_received".localized
            case .sent:     return "reputation.history.tab_sent".localized
            }
        }
    }

    private var entries: [HistoryEntry] {
        direction == .received ? received : sent
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $direction) {
                        ForEach(Direction.allCases) { d in
                            Text(d.localizedLabel).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    if loading && entries.isEmpty {
                        Spacer()
                        ProgressView().tint(Theme.Color.accent)
                        Spacer()
                    } else if entries.isEmpty {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "tray")
                                .font(.system(size: 32))
                                .foregroundColor(Theme.Color.textSecondary)
                            Text(direction == .received
                                 ? "reputation.history.empty_received".localized
                                 : "reputation.history.empty_sent".localized)
                                .font(.callout)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(entries, id: \.id) { entry in
                                row(entry)
                                    .listRowBackground(Theme.Color.bgSecondary)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("reputation.history.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task(id: direction) { await reload() }
            .sheet(item: Binding(
                get: { viewInfoForUIN.map { HistoryProfileWrap(uin: $0) } },
                set: { viewInfoForUIN = $0?.uin }
            )) { wrap in
                NavigationStack {
                    UserInfoView(uin: wrap.uin, isOwn: false)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("common.close".localized) {
                                    viewInfoForUIN = nil
                                }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: HistoryEntry) -> some View {
        let openable = entry.counterpartyUIN != nil
        Button {
            if let uin = entry.counterpartyUIN {
                viewInfoForUIN = uin
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.Color.accent.opacity(0.14))
                        .frame(width: 34, height: 34)
                    ItemAssetImage(bundleSubdir: "Items", filename: "rep", ext: "gif")
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("+\(entry.amount)")
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                        Text("reputation.history.amount_suffix".localized)
                            .font(.caption)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    Text(counterpartyLabel(entry))
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(LastSeenFormatter.shared.relative(from: entry.grantedAt))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!openable)
    }

    private func counterpartyLabel(_ entry: HistoryEntry) -> String {
        if direction == .received && entry.anonymous {
            return "reputation.history.anonymous".localized
        }
        if let nick = entry.counterpartyNickname {
            return nick
        }
        if let uin = entry.counterpartyUIN {
            return String(uin)
        }
        return "—"
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let rows: [HistoryEntry] = try await APIClient.shared.request(
                "GET", "/reputation/history",
                query: ["direction": direction.rawValue, "limit": "50"],
            )
            if direction == .received {
                received = rows
            } else {
                sent = rows
            }
        } catch {
            // Soft-fail — keep whatever we last loaded; user can
            // flip tabs to retry.
        }
    }
}

struct HistoryEntry: Decodable {
    let id: Int
    let amount: Int
    let grantedAt: Date
    let counterpartyUIN: Int?
    let counterpartyNickname: String?
    let anonymous: Bool

    enum CodingKeys: String, CodingKey {
        case id, amount, anonymous
        case grantedAt = "granted_at"
        case counterpartyUIN = "counterparty_uin"
        case counterpartyNickname = "counterparty_nickname"
    }
}

private struct HistoryProfileWrap: Identifiable {
    let uin: Int
    var id: Int { uin }
}
