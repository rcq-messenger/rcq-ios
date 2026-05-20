import SwiftUI

/// Top 100 users by reputation. Visibility-gated server-side —
/// users with `reputation_visibility != 'everyone'` are absent
/// from the list. Tapping a row opens that user's profile sheet.
struct ReputationLeaderboardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LeaderboardEntry] = []
    @State private var loading = true
    @State private var viewInfoForUIN: Int?
    @State private var petPreview: PetPreviewTarget?
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if loading {
                    ProgressView().tint(Theme.Color.accent)
                } else if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "trophy")
                            .font(.system(size: 36))
                            .foregroundColor(Theme.Color.textSecondary)
                        Text("reputation.leaderboard.empty".localized)
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                } else {
                    List {
                        ForEach(Array(entries.enumerated()), id: \.element.uin) { idx, entry in
                            Button {
                                viewInfoForUIN = entry.uin
                            } label: {
                                row(rank: idx + 1, entry: entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                entry.uin == AuthService.shared.ownUIN
                                    ? Theme.Color.accent.opacity(0.10)
                                    : Theme.Color.bgSecondary
                            )
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("reputation.leaderboard.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
            .sheet(isPresented: $showInfo) {
                ReputationLeaderboardInfoSheet()
            }
            .task { await load() }
            .sheet(item: Binding(
                get: { viewInfoForUIN.map { ViewInfoUINWrap(uin: $0) } },
                set: { viewInfoForUIN = $0?.uin }
            )) { wrap in
                NavigationStack {
                    UserInfoView(
                        uin: wrap.uin,
                        isOwn: wrap.uin == AuthService.shared.ownUIN
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.close".localized) { viewInfoForUIN = nil }
                        }
                    }
                }
            }
            .sheet(item: $petPreview) { wrap in
                PetPreviewSheet(
                    pet: wrap.pet,
                    ownerUIN: wrap.uin,
                    ownerNickname: wrap.nickname,
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private func row(rank: Int, entry: LeaderboardEntry) -> some View {
        HStack(spacing: 12) {
            // Numeric rank chip — medal-styled for 1-3, plain for the
            // rest. Compact monospaced digits keep the column edge
            // aligned across two-digit / three-digit positions.
            Text("\(rank)")
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .foregroundColor(rankColor(rank))
                .frame(width: 36, alignment: .center)

            // Status dot + equipped-pet overlay, same component the
            // contact list uses. Status is the server's stored value
            // (snapshot, not a live WS subscription) — precise
            // presence updates when the user opens the profile.
            // Tapping the pet opens its preview (inner button wins
            // over the row's profile-open button).
            if let pet = entry.equippedPet {
                Button {
                    petPreview = PetPreviewTarget(
                        pet: pet, uin: entry.uin, nickname: entry.nickname,
                    )
                } label: {
                    StatusWithPet(status: entry.status, pet: pet, size: 28)
                }
                .buttonStyle(.plain)
            } else {
                StatusWithPet(status: entry.status, pet: nil, size: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.nickname)
                    .font(.body.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(String(entry.uin))
                    .font(Theme.Font.mono)
                    .foregroundColor(Theme.Color.textMono)
            }

            Spacer()

            HStack(spacing: 4) {
                ItemAssetImage(bundleSubdir: "Items", filename: "rep", ext: "gif")
                    .frame(width: 15, height: 15)
                Text(entry.reputation.compactCount)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
            }
        }
        .padding(.vertical, 4)
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(hex: 0xD4AF37)   // gold
        case 2: return Color(hex: 0xC0C0C0)   // silver
        case 3: return Color(hex: 0xCD7F32)   // bronze
        default: return Theme.Color.textPrimary
        }
    }

    private func load() async {
        do {
            let rows: [LeaderboardEntry] = try await APIClient.shared.request(
                "GET", "/reputation/leaderboard",
                query: ["limit": "100"],
            )
            self.entries = rows
        } catch {
            self.entries = []
        }
        self.loading = false
    }
}

/// Small explainer opened from the leaderboard's ⓘ button.
struct ReputationLeaderboardInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let points: [(icon: String, key: String)] = [
        ("rosette", "reputation.info.b1"),
        ("plus.circle.fill", "reputation.info.b2"),
        ("eye.slash", "reputation.info.b3"),
        ("arrow.triangle.2.circlepath", "reputation.info.b4"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("reputation.info.intro".localized)
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(points, id: \.key) { p in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: p.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.Color.accent)
                                    .frame(width: 22)
                                Text(p.key.localized)
                                    .font(.callout)
                                    .foregroundColor(Theme.Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("reputation.info.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct LeaderboardEntry: Decodable {
    let uin: Int
    let nickname: String
    let reputation: Int
    let status: UserStatus
    let equippedPet: EquippedPet?

    enum CodingKeys: String, CodingKey {
        case uin, nickname, reputation, status
        case equippedPet = "equipped_pet"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uin = try c.decode(Int.self, forKey: .uin)
        nickname = try c.decode(String.self, forKey: .nickname)
        reputation = try c.decode(Int.self, forKey: .reputation)
        // Unknown / future status strings fall back to offline rather
        // than failing the whole row's decode.
        let raw = (try? c.decode(String.self, forKey: .status)) ?? "offline"
        status = UserStatus(rawValue: raw) ?? .offline
        equippedPet = try? c.decode(EquippedPet.self, forKey: .equippedPet)
    }
}

/// Identifiable wrapper so `.sheet(item:)` can drive a 1-of-N profile
/// presentation off a bare Int.
private struct ViewInfoUINWrap: Identifiable {
    let uin: Int
    var id: Int { uin }
}
