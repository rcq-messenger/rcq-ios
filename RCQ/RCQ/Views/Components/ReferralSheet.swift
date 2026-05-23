import SwiftUI

/// Invite-a-friend screen. Referral code is the UIN; rewards land
/// after the invitee stays active for the configured window.
struct ReferralSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthService.shared

    @State private var status: ReferralStatus?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var showHowItWorks = false

    private var ownUIN: Int { auth.ownUIN ?? 0 }
    private var inviteURL: URL? { URL(string: "https://rcq.app/r/\(ownUIN)") }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        heroCard
                        codeCard
                        actionsRow
                        statsRow
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("referral.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHowItWorks = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundColor(Theme.Color.accent)
                    }
                    .accessibilityLabel("referral.howto.title".localized)
                }
            }
            .sheet(isPresented: $showHowItWorks) {
                ReferralHowItWorksSheet(status: status)
            }
        }
        .task { await load() }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 76, height: 76)
                Image(systemName: "gift.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(headline)
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(subhead)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Theme.Color.accent, Theme.Color.accent.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var headline: String {
        guard let s = status else { return "referral.body.generic".localized }
        return String(format: "referral.headline".localized, s.inviterReward, s.inviteeReward)
    }

    private var subhead: String {
        guard let s = status else { return "referral.subhead.generic".localized }
        return String(format: "referral.subhead".localized, s.activationDays)
    }

    // MARK: - Code card

    private var codeCard: some View {
        VStack(spacing: 8) {
            Text("referral.your_code".localized)
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.Color.textSecondary)
                .tracking(1.2)
            Text("#\(String(ownUIN))")
                .font(.system(size: 32, weight: .heavy, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
            Text("referral.code_hint".localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: 10) {
            if let url = inviteURL {
                ShareLink(
                    item: url,
                    message: Text(String(format: "referral.share.message".localized, ownUIN))
                ) {
                    actionLabel(
                        icon: "square.and.arrow.up",
                        title: "referral.share".localized,
                        filled: true,
                    )
                }
                .buttonStyle(.plain)
            }
            Button {
                if let url = inviteURL { UIPasteboard.general.string = url.absoluteString }
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                actionLabel(
                    icon: "doc.on.doc",
                    title: "referral.copy_link".localized,
                    filled: false,
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func actionLabel(icon: String, title: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(filled ? .white : Theme.Color.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(filled ? Theme.Color.accent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsRow: some View {
        if loading {
            ProgressView().tint(Theme.Color.textSecondary).padding(.top, 4)
        } else if loadFailed {
            Text("referral.load_failed".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
        } else if let s = status {
            HStack(spacing: 10) {
                statTile(value: "\(s.invitedCount)",
                         label: "referral.stat.invited".localized,
                         glyph: "person.fill.badge.plus",
                         useCoin: false)
                statTile(value: "\(s.activatedCount)",
                         label: "referral.stat.activated".localized,
                         glyph: "checkmark.seal.fill",
                         useCoin: false)
                statTile(value: "\(s.creditsEarned)",
                         label: "referral.stat.credits".localized,
                         glyph: "",
                         useCoin: true)
            }
        }
    }

    private func statTile(value: String, label: String, glyph: String, useCoin: Bool) -> some View {
        VStack(spacing: 6) {
            Group {
                if useCoin {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                }
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundColor(Theme.Color.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Network

    private func load() async {
        loading = true
        loadFailed = false
        do {
            status = try await APIClient.shared.fetchReferralStatus()
        } catch {
            loadFailed = true
        }
        loading = false
    }
}

/// Help sheet — three numbered steps describing the flow.
private struct ReferralHowItWorksSheet: View {
    let status: ReferralStatus?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    step(num: 1, text: String(
                        format: "referral.howto.step1".localized,
                        status?.activationDays ?? 3,
                    ))
                    step(num: 2, text: String(
                        format: "referral.howto.step2".localized,
                        status?.inviterReward ?? 0,
                        status?.inviteeReward ?? 0,
                    ))
                    step(num: 3, text: "referral.howto.step3".localized)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Theme.Color.bgPrimary)
            .navigationTitle("referral.howto.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func step(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(num)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Theme.Color.accent)
                .clipShape(Circle())
            Text(text)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
