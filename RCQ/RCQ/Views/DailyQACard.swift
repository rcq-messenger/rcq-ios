import SwiftUI

/// Daily QA smoke-test gamification.
///
/// Each UTC day, the server picks 12 items from a fixed catalog and
/// surfaces them here as a tickable checklist. Completing all 12
/// mints a `BountyCredit(source="daily_qa", amount=20)` that joins
/// the launch-day redemption sweep alongside bug-bounty grants.
///
/// MVP behaviour: ticks are manual — the user taps a row to mark
/// it done after performing the action elsewhere in the app. Future
/// work will auto-tick from event hooks on the relevant action
/// paths (send-message / open-lootbox / drop-banner / etc.), but
/// trusted closed-beta testers ticking off honestly is fine for v1.
struct DailyQACard: View {
    @State private var items: [SmokeItem] = []
    @State private var completedCount: Int = 0
    @State private var total: Int = 12
    @State private var bountyMinted: Bool = false
    @State private var rewardAmount: Int = 20
    @State private var loading: Bool = true
    @State private var error: String?

    private struct SmokeItem: Identifiable {
        let slug: String
        var completed: Bool
        var id: String { slug }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.Color.accent)
                    Text("smoke.loading".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if error != nil {
                Text("smoke.error".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            } else {
                content
            }
        }
        .task { await load() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            Divider().background(Theme.Color.divider)
            VStack(spacing: 4) {
                ForEach(items) { item in
                    row(item)
                }
            }
            if bountyMinted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(Theme.Color.accent)
                        .font(.caption)
                    Text(String(format: "smoke.minted".localized, rewardAmount))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            } else {
                Text(String(format: "smoke.reward_hint".localized, rewardAmount))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    private var headline: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 18))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 32, height: 32)
                .background(Theme.Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("smoke.title".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(String(format: "smoke.progress".localized, completedCount, total))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            // Tiny progress ring shows at-a-glance how close to 100%.
            ZStack {
                Circle()
                    .stroke(Theme.Color.divider, lineWidth: 3)
                    .frame(width: 28, height: 28)
                Circle()
                    .trim(from: 0, to: total == 0 ? 0 : CGFloat(completedCount) / CGFloat(total))
                    .stroke(Theme.Color.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: completedCount)
            }
        }
    }

    private func row(_ item: SmokeItem) -> some View {
        Button {
            tap(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(item.completed ? Theme.Color.accent : Theme.Color.textSecondary)
                Text(Self.label(for: item.slug))
                    .font(.callout)
                    .foregroundColor(item.completed ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                    .strikethrough(item.completed, color: Theme.Color.textSecondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(item.completed)
    }

    private static func label(for slug: String) -> String {
        // Each catalog slug has a matching localised key under
        // smoke.item.<slug>. Missing keys fall through to the slug
        // itself so dev can spot a gap.
        let key = "smoke.item.\(slug)"
        let localised = key.localized
        return localised == key ? slug.replacingOccurrences(of: "_", with: " ") : localised
    }

    private func tap(_ item: SmokeItem) {
        guard !item.completed else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        // Optimistic flip — server is idempotent so a network blip
        // doesn't lose the tick.
        if let idx = items.firstIndex(where: { $0.slug == item.slug }) {
            items[idx].completed = true
            completedCount = items.filter { $0.completed }.count
        }
        Task { await sendTick(slug: item.slug) }
    }

    private func sendTick(slug: String) async {
        struct In: Encodable { let slug: String }
        struct Out: Decodable {
            let completed_count: Int
            let total: Int
            let bounty_minted: Bool
            let minted_amount: Int
        }
        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/smoke/tick", body: In(slug: slug)
            )
            await MainActor.run {
                completedCount = out.completed_count
                total = out.total
                if out.bounty_minted && !bountyMinted {
                    bountyMinted = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        } catch {
            // Roll back the optimistic flip; surface a soft error.
            await MainActor.run {
                if let idx = items.firstIndex(where: { $0.slug == slug }) {
                    items[idx].completed = false
                    completedCount = items.filter { $0.completed }.count
                }
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        loading = true
        error = nil
        struct ItemOut: Decodable {
            let slug: String
            let completed: Bool
        }
        struct Out: Decodable {
            let date: String
            let items: [ItemOut]
            let completed_count: Int
            let total: Int
            let bounty_minted: Bool
            let reward_amount: Int
        }
        do {
            let out: Out = try await APIClient.shared.request("GET", "/smoke/today")
            await MainActor.run {
                items = out.items.map { SmokeItem(slug: $0.slug, completed: $0.completed) }
                completedCount = out.completed_count
                total = out.total
                bountyMinted = out.bounty_minted
                rewardAmount = out.reward_amount
                loading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}
