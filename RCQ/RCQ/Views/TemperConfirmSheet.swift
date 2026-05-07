import SwiftUI

/// Confirmation sheet for a temper attempt — port of IX
/// EnhanceConfirmSheet, repainted in RCQ's palette.
///
/// Behavior:
///   - Sheet stays open after a SUCCESS so the user can chain
///     attempts (each tap → another roll, costs more, lower chance).
///   - On BURN we surface a dedicated burn outcome screen and the
///     parent dismisses the detail sheet (the item is gone).
///   - Pre-flight gates the CTA: max-level, no-scrolls, not-owned.
struct TemperConfirmSheet: View {
    let item: Item
    let onComplete: (TemperOutcome) -> Void

    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var rolling = false
    @State private var lastSuccessLevel: Int? = nil

    /// Re-resolve the live item from the store on each render, so
    /// chained attempts see the new level / wallet without dismiss.
    private var live: Item {
        items.items.first(where: { $0.id == item.id }) ?? item
    }

    private var nextCost: Int {
        TemperTables.scrollCost(at: live.level)
    }
    private var nextChance: Double {
        TemperTables.successChance(at: live.level)
    }
    private var atMax: Bool {
        live.level >= TemperTables.maxLevel
    }
    private var canRoll: Bool {
        !rolling && !atMax && items.wallet.scrolls >= nextCost
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                rollScreen
            }
            .navigationTitle("temper.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.close".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
            }
        }
    }

    // MARK: - Roll screen

    private var rollScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                stats
                successFlash
                rollButton
                tableHint
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            // ItemCard already renders the +N badge in its top-right
            // corner — duplicating it next to the rarity label was
            // visual noise.
            ItemCard(item: live)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(ItemDisplay.name(for: live.kindID))
                    .font(Theme.Font.nickname)
                    .foregroundColor(Theme.Color.textPrimary)
                Text(live.rarity.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(live.rarity.color)
            }
            Spacer()
        }
    }

    private var stats: some View {
        VStack(spacing: 8) {
            statRow("temper.stat.level_arrow".localized, value: "+\(live.level) → +\(live.level + 1)")
            statRow("temper.stat.cost".localized) { scrollChip(nextCost) }
            statRow("temper.stat.success".localized,
                    value: String(format: "%.0f%%", nextChance * 100))
            statRow("temper.stat.burn".localized,
                    value: String(format: "%.0f%%", (1 - nextChance) * 100),
                    valueColor: .red)
            statRow("temper.stat.your_gems".localized) { scrollChip(items.wallet.scrolls) }
        }
        .padding(14)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    /// Plain text right-aligned value row.
    private func statRow(_ k: String, value v: String, valueColor: Color = Theme.Color.textPrimary) -> some View {
        HStack {
            Text(k).font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
            Text(v).font(Theme.Font.mono)
                .foregroundColor(valueColor)
        }
    }

    /// Generic-content row — inline view on the right (used for the
    /// scroll-icon×N chips so cost / wallet read visually instead of
    /// "1 scr." text strings).
    private func statRow<Content: View>(_ k: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(k).font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
            content()
        }
    }

    private func scrollChip(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                .frame(width: 18, height: 18)
            Text("×\(count)")
                .font(Theme.Font.mono)
                .foregroundColor(Theme.Color.textPrimary)
        }
    }

    @ViewBuilder
    private var successFlash: some View {
        if let lvl = lastSuccessLevel {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(Theme.Color.accent)
                Text(String(format: "temper.success.flash".localized, lvl))
                    .font(Theme.Font.statusLabel)
                    .foregroundColor(Theme.Color.textPrimary)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.accent.opacity(0.12))
            .overlay(Rectangle().fill(Theme.Color.accent).frame(width: 2),
                     alignment: .leading)
            .transition(.opacity)
        }
    }

    private var rollButton: some View {
        Button {
            Task { await roll() }
        } label: {
            Text(rolling
                 ? "temper.cta.enhancing".localized
                 : (atMax ? "temper.cta.max_level".localized
                          : items.wallet.scrolls < nextCost
                              ? "temper.cta.no_gems".localized
                              : "temper.cta.enhance".localized))
                .font(Theme.Font.nickname)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(canRoll ? Theme.Color.accent : Theme.Color.divider)
                .cornerRadius(8)
        }
        .disabled(!canRoll)
    }

    private var tableHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("temper.odds_by_level".localized)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .tracking(2)
            ForEach(0..<TemperTables.maxLevel, id: \.self) { lvl in
                HStack(spacing: 6) {
                    Text("+\(lvl) → +\(lvl + 1)")
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(lvl == live.level
                                         ? Theme.Color.textPrimary
                                         : Theme.Color.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f%%", TemperTables.successChance(at: lvl) * 100))
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(lvl == live.level
                                         ? Theme.Color.accent
                                         : Theme.Color.textSecondary)
                    HStack(spacing: 2) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                            .frame(width: 14, height: 14)
                        Text("×\(TemperTables.scrollCost(at: lvl))")
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    // MARK: - Roll

    @MainActor
    private func roll() async {
        guard canRoll else { return }
        rolling = true
        let outcome = await items.temper(live)
        rolling = false
        switch outcome {
        case .success(let lvl, _):
            SoundService.shared.play(.temperSuccess)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.25)) {
                lastSuccessLevel = lvl
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if lastSuccessLevel == lvl {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        lastSuccessLevel = nil
                    }
                }
            }
        case .burned:
            // No burn screen — IX just dismisses everything and the
            // detail sheet collapses with the row gone. The fail
            // sound + heavy haptic is the entire feedback.
            SoundService.shared.play(.temperFail)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            onComplete(.burned)
            dismiss()
        case .none:
            break
        }
    }
}
