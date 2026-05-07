import SwiftUI

/// Standalone Bug Bounty sheet — surfaced as its OWN row in Settings,
/// next to (not inside) the "About RCQ" entry. Reads as a feature
/// rather than a footnote: contributors get tokens for accepted reports,
/// and the program is the project's only public support / disclosure
/// channel (the security model documents this; see /security on the
/// landing).
///
/// Three sections:
///   1. How it works — terse explanation of the bounty model.
///   2. Severity tiers — how the token reward scales with impact.
///   3. Submit — single text-field + Send. Posts to /reports with
///      context = "bug_bounty" so the admin queue can sort by
///      report-vs-bounty in the same table.
struct BugBountySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var description: String = ""
    @State private var sending: Bool = false
    @State private var sentOK: Bool = false
    @State private var errorMessage: String?

    /// Hard cap matches the backend's `MAX_REASON_LEN` so a typed-out
    /// report fits in one POST without surprise truncation.
    private static let maxLength: Int = 1000
    /// Min so a careless tap doesn't fire an empty submission.
    private static let minLength: Int = 20

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    howItWorks
                    severityTiers
                    submitForm
                    Text("bug_bounty.disclosure".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("bug_bounty.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .alert("bug_bounty.alert.title".localized,
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(errorMessage ?? "") })
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 28))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 56, height: 56)
                .background(Theme.Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("bug_bounty.heading".localized)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("bug_bounty.subheading".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("bug_bounty.section.how")
            bulletParagraph("bug_bounty.how.b1")
            bulletParagraph("bug_bounty.how.b2")
            bulletParagraph("bug_bounty.how.b3")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    private var severityTiers: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("bug_bounty.section.tiers")
            tierRow(label: "bug_bounty.tier.critical", reward: "50 000", color: .red)
            tierRow(label: "bug_bounty.tier.high",     reward: "20 000", color: .orange)
            tierRow(label: "bug_bounty.tier.medium",   reward: "5 000",  color: .yellow)
            tierRow(label: "bug_bounty.tier.low",      reward: "500",    color: Theme.Color.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    private func tierRow(label: String, reward: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label.localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textPrimary)
            Spacer()
            HStack(spacing: 4) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 14, height: 14)
                Text(reward)
                    .font(.system(.callout, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.Color.textPrimary)
            }
        }
    }

    private var submitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("bug_bounty.section.submit")
            Text("bug_bounty.submit.hint".localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text("bug_bounty.submit.placeholder".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $description)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 140)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .background(Theme.Color.bgSecondary)
            .cornerRadius(8)
            .onChange(of: description) { _ in
                if description.count > Self.maxLength {
                    description = String(description.prefix(Self.maxLength))
                }
            }

            HStack {
                Text("\(description.count) / \(Self.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                if sentOK {
                    Label("bug_bounty.submit.sent".localized, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(sending ? "bug_bounty.submit.sending".localized
                                     : "bug_bounty.submit.cta".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(canSubmit ? Theme.Color.accent : Theme.Color.divider)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit || sending)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary.opacity(0.6))
        .cornerRadius(8)
    }

    private var canSubmit: Bool {
        description.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minLength
    }

    private func sectionLabel(_ key: String) -> some View {
        Text(key.localized)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.Color.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func bulletParagraph(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.Color.accent).frame(width: 5, height: 5).padding(.top, 7)
            Text(key.localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() async {
        // Bug-bounty submissions ride the same /reports endpoint as
        // user reports — context tag lets the admin filter the
        // queue. Target is self (server cleanly accepts that for
        // bounty context); the real signal is the body text.
        struct Body: Encodable {
            let target_uin: Int
            let reason: String
            let context: String
        }
        guard let me = AuthService.shared.ownUIN else {
            errorMessage = "bug_bounty.error.no_identity".localized
            return
        }
        sending = true
        defer { sending = false }
        do {
            struct Out: Decodable { let id: Int }
            let _: Out = try await APIClient.shared.request(
                "POST", "/reports",
                body: Body(
                    target_uin: me,
                    reason: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: "bug_bounty"
                )
            )
            sentOK = true
            description = ""
        } catch {
            errorMessage = String(format: "bug_bounty.error.generic".localized,
                                  error.localizedDescription)
        }
    }
}
