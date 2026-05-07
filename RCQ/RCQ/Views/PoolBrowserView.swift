import SwiftUI

/// Pool browser — every catalog kind with its per-pull chance,
/// grouped by section. Mirrors IX `PoolBrowserView`. Shown as a
/// sheet from the LootboxView header.
struct PoolBrowserView: View {
    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var packPreview: ItemKind?

    private var kindsBySection: [(ItemSection, [ItemKind])] {
        guard let catalog = items.catalog else { return [] }
        let grouped = Dictionary(grouping: catalog.kinds, by: { $0.section })
        return ItemSection.allCases
            .compactMap { sec in
                guard let list = grouped[sec], !list.isEmpty else { return nil }
                return (sec, list.sorted { $0.rarity.rollWeight < $1.rarity.rollWeight })
            }
    }

    /// Fraction of pulls that land on items rather than gems. The
    /// catalog's `sectionWeights` and `perPullChance` are computed
    /// assuming every pull yields an item; we scale them by this
    /// factor so the Pool view's percentages sum coherently with
    /// the gems row at the top (Gems X% + Sections... = 100%).
    private var itemShare: Double {
        1.0 - (items.catalog?.scrollDropChance ?? 0.0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let cat = items.catalog, cat.scrollDropChance > 0 {
                            gemsSection(catalog: cat)
                        }
                        ForEach(kindsBySection, id: \.0) { (section, kinds) in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(section.displayName.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.Color.textSecondary)
                                        .tracking(2)
                                    Spacer()
                                    Text(String(format: "pool.section_share".localized, (items.catalog?.sectionWeights[section.rawValue] ?? 0) * itemShare))
                                        .font(Theme.Font.monoSmall)
                                        .foregroundColor(Theme.Color.textMono)
                                }
                                ForEach(kinds, id: \.id) { kind in
                                    Button {
                                        // Cosmetic packs ship a list of
                                        // sub-emojis; tapping the pool
                                        // row opens a sheet showing the
                                        // full contents (animated). For
                                        // collectibles (relics / founders)
                                        // the row is informative-only —
                                        // there's nothing else to drill
                                        // into.
                                        if kind.appliesAs != .none {
                                            packPreview = kind
                                        }
                                    } label: {
                                        row(kind: kind)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("pool.title".localized)
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
            .task {
                if items.catalog == nil { await items.refreshCatalog() }
            }
            .sheet(item: $packPreview) { kind in
                PackPreviewSheet(kind: kind)
                    .presentationDetents([.medium])
            }
        }
    }

    private func row(kind: ItemKind) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Theme.Color.bgSecondary)
                if kind.section == .voices {
                    // Voice kind in the pool browser plays its
                    // sound on tap of the row's glyph — lets the
                    // user audition every voice in the loot pool
                    // before deciding to spend tokens on a box.
                    Button {
                        SoundService.shared.preview(kindID: kind.id)
                    } label: {
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(kind.rarity.color)
                    }
                    .buttonStyle(.plain)
                } else {
                    ItemAssetImage(
                        bundleSubdir: "Items",
                        filename: stem(kind),
                        ext: ext(kind),
                    )
                    .padding(6)
                }
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(kind.rarity.color)
                            .frame(width: 6, height: 6)
                            .padding(3)
                    }
                    Spacer()
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(ItemDisplay.name(for: kind.id))
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 6) {
                    Text(kind.rarity.label.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(kind.rarity.color)
                        .tracking(1.5)
                    if let cap = kind.limit {
                        Text("·").foregroundColor(Theme.Color.textMono)
                        Text(String(format: "pool.cap".localized, cap))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
            }
            Spacer(minLength: 0)
            // Server's `perPullChance` is "given that an item drops,
            // chance of THIS kind". Multiply by `itemShare` to surface
            // the overall (post-gem-roll) probability so the row sums
            // correctly with the gems row at the top.
            Text(String(format: "%.1f%%", kind.perPullChance * itemShare))
                .font(Theme.Font.monoSmall)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Theme.Color.bgSecondary.opacity(0.5))
        .cornerRadius(6)
    }

    /// Top-row "Gems" entry — same layout as the kind rows below so
    /// the user can read down a single column of percentages and have
    /// them sum to 100 across all sections + gems.
    @ViewBuilder
    private func gemsSection(catalog: ItemCatalog) -> some View {
        let pct = catalog.scrollDropChance * 100.0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("pool.gems.section".localized.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .tracking(2)
                Spacer()
                Text(String(format: "pool.section_share".localized, pct))
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textMono)
            }
            HStack(spacing: 12) {
                ZStack {
                    Rectangle().fill(Theme.Color.bgSecondary)
                    GIFImage(name: "gem")
                        .frame(width: 30, height: 30)
                        .padding(3)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("pool.gems.title".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(String(format: "pool.gems.range".localized, catalog.scrollDropMin, catalog.scrollDropMax))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                }
                Spacer(minLength: 0)
                Text(String(format: "%.1f%%", pct))
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Theme.Color.bgSecondary.opacity(0.5))
            .cornerRadius(6)
        }
    }

    private func stem(_ k: ItemKind) -> String {
        let basename = (k.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private func ext(_ k: ItemKind) -> String {
        let basename = (k.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}

/// Bottom sheet shown when the user taps a cosmetic pack in the
/// pool browser. Single-page summary: kind name + lore + the full
/// list of contained emoticons rendered as an animated row.
private struct PackPreviewSheet: View {
    let kind: ItemKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(ItemDisplay.name(for: kind.id))
                            .font(.custom("Georgia", size: 22))
                            .foregroundColor(Theme.Color.textPrimary)
                            .padding(.horizontal, 16)
                        if let lore = ItemDisplay.lore(for: kind.id) {
                            Text(lore)
                                .font(.callout.italic())
                                .foregroundColor(Theme.Color.textSecondary)
                                .padding(.horizontal, 16)
                        }
                        // Edge-to-edge — view spans the full sheet
                        // width with its own internal 16pt inset
                        // so peer content lines up.
                        KindContentsView(kindID: kind.id, horizontalInset: 16)
                    }
                    .padding(.vertical, 16)
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
        }
    }
}
