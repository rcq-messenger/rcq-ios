import SwiftUI

/// Pool browser — every catalog kind with its per-pull chance,
/// grouped by section. Shown as a sheet from the LootboxView header.
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
                // Sort by base per-pull drop weight (descending). The
                // catalog row carries a `rarity` field but it's a
                // legacy default — the actual rarity is rolled
                // INDEPENDENTLY per pull (see `RARITY_ROLL_WEIGHTS`
                // backend-side), so sorting by it would mislead.
                return (sec, list.sorted { $0.perPullChance > $1.perPullChance })
            }
    }

    // Catalog's sectionWeights / perPullChance assume every pull yields
    // an item; scale by this so percentages sum to 100 with the gems row.
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
                        if let cat = items.catalog {
                            rarityDistributionSection(catalog: cat)
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
                    Button {
                        SoundService.shared.preview(kindID: kind.id)
                    } label: {
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.Color.textSecondary)
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
                // The previous per-row rarity dot + LEGENDARY/EPIC/...
                // label implied "this kind drops at this rarity only".
                // It doesn't — rarity is rolled independently per
                // drop (see `rarityDistributionSection`). Removed
                // both visuals so users don't lock into the wrong
                // mental model.
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(ItemDisplay.name(for: kind.id))
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
                if let cap = kind.limit {
                    Text(String(format: "pool.cap".localized, cap))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                }
            }
            Spacer(minLength: 0)
            // perPullChance is conditional on an item dropping; multiply
            // by itemShare for overall (post-gem-roll) probability.
            Text(String(format: "%.1f%%", kind.perPullChance * itemShare))
                .font(Theme.Font.monoSmall)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Theme.Color.bgSecondary.opacity(0.5))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func rarityDistributionSection(catalog: ItemCatalog) -> some View {
        // Rarity is rolled independently of the kind that dropped, so
        // surface that as its own section. Without this users assumed
        // each kind only dropped at its catalog-default rarity (the
        // old per-row badge), which was wrong.
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("pool.rarity.section".localized.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .tracking(2)
                Spacer()
            }
            Text("pool.rarity.hint".localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.bottom, 2)
            VStack(spacing: 4) {
                ForEach(ItemRarity.allCases, id: \.self) { rarity in
                    let weight = catalog.rarityWeights[rarity.rawValue] ?? 0
                    HStack(spacing: 8) {
                        Circle()
                            .fill(rarity.color)
                            .frame(width: 8, height: 8)
                        Text(rarity.label.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(rarity.color)
                            .tracking(1.5)
                        Spacer()
                        Text(String(format: "%.1f%%", weight))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Theme.Color.bgSecondary.opacity(0.5))
                    .cornerRadius(6)
                }
            }
        }
    }

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
