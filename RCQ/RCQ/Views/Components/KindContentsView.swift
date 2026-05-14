import SwiftUI

/// Vertical grid preview of a cosmetic pack's contents. Renders one
/// thumbnail per pack entry — animated GIF tiles play live so users
/// see exactly what they're getting before they equip / open. Used
/// in:
///   - PoolBrowserView's pack-detail sheet
///   - ItemDetailSheet (over the action row, when the item is a
///     cosmetic pack)
///
/// Grid uses `LazyVGrid` with an adaptive column track so packs of
/// 30+ stickers wrap onto multiple rows instead of trailing off the
/// screen edge in a single horizontal strip.
///
/// Empty for non-pack kinds (relics, founders) — caller should
/// branch on `appliesAs` and not render this for them.
struct KindContentsView: View {
    let kindID: String
    let entries: [CosmeticPacks.Entry]
    /// Match the caller's outer `.padding(.horizontal, …)` so the
    /// title + first tile align with peer content.
    var horizontalInset: CGFloat = 18

    init(kindID: String, horizontalInset: CGFloat = 18) {
        self.kindID = kindID
        self.entries = CosmeticPacks.entries(for: kindID)
        self.horizontalInset = horizontalInset
    }

    private static let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 64, maximum: 80), spacing: 6, alignment: .top),
    ]

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "pool.pack.contents".localized, entries.count))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .tracking(2)
                    .padding(.leading, horizontalInset)
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                    ForEach(entries, id: \.asset) { entry in
                        tile(entry)
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
        }
    }

    private func tile(_ entry: CosmeticPacks.Entry) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(Theme.Color.bgSecondary)
                ItemAssetImage(
                    bundleSubdir: "Items",
                    filename: entry.asset,
                    ext: "gif",
                )
                .padding(8)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(entry.primaryCode)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.Color.textMono)
                .lineLimit(1)
        }
    }
}
