import SwiftUI

/// Memorial of pets that fell on Pet Hunt — surfaced from the
/// inventory ellipsis menu so users can mourn their dead from
/// the most natural surface (where the pet would have lived).
/// Identical content shape to the MemorialSheet inside
/// PetHuntView; shares the same `PetHuntService.memorial` source.
struct PetMemorialFromInventorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = PetHuntService.shared
    @StateObject private var items = ItemsService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if svc.memorial.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("pet_hunt.memorial.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
            .task { await svc.refreshMemorial() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 48))
                .foregroundColor(Theme.Color.divider)
            Text("pet_hunt.memorial.empty.title".localized)
                .font(.system(.headline, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("pet_hunt.memorial.empty.body".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(svc.memorial) { entry in
                    memorialRow(entry)
                }
            }
            .padding(16)
        }
    }

    private func memorialRow(_ entry: MemorialEntry) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle()
                    .fill(Theme.Color.bgSecondary)
                if let kind = items.catalog?.kind(by: entry.kindID) {
                    ItemAssetImage(
                        bundleSubdir: subdir(for: kind),
                        filename: stem(for: kind),
                        ext: ext(for: kind),
                    )
                    .padding(8)
                    .saturation(0.0)
                    .opacity(0.6)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(ItemDisplay.name(for: entry.kindID))
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(entry.rarity.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(entry.rarity.color)
                if let zone = entry.diedZone {
                    Text(String(format: "pet_hunt.memorial.died_in".localized,
                                zone.displayName))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Text(DateFormatter.itemAcquired.string(from: entry.diedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.Color.bgSecondary.opacity(0.55))
        .cornerRadius(10)
    }

    private func subdir(for kind: ItemKind) -> String {
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let s = (trimmed as NSString).deletingLastPathComponent
        return s.isEmpty ? "Items" : "Items/\(s)"
    }
    private func stem(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private func ext(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}
