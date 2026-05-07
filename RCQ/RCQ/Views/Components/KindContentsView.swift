import SwiftUI

/// Horizontal preview of a cosmetic pack's contents. Renders one
/// thumbnail per pack entry — animated GIF tiles play live so users
/// see exactly what they're getting before they equip / open. Used
/// in:
///   - PoolBrowserView's pack-detail sheet
///   - ItemDetailSheet (over the action row, when the item is a
///     cosmetic pack)
///
/// Edge-to-edge layout: this view assumes its parent has applied
/// `.padding(.horizontal, horizontalInset)` to peer content, then
/// negated that padding around this view (`.padding(.horizontal,
/// -horizontalInset)`) so the scroll content can bleed past the
/// gutter. The inner HStack re-applies that same inset so the first
/// and last tiles still line up with peer rows. Title text is
/// padded the same way.
///
/// Empty for non-pack kinds (relics, founders) — caller should
/// branch on `appliesAs` and not render this for them.
struct KindContentsView: View {
    let kindID: String
    let entries: [CosmeticPacks.Entry]
    /// Match the caller's outer `.padding(.horizontal, …)` so the
    /// title + first tile align with peer content while the scroll
    /// itself can drift past the screen edges.
    var horizontalInset: CGFloat = 18

    init(kindID: String, horizontalInset: CGFloat = 18) {
        self.kindID = kindID
        self.entries = CosmeticPacks.entries(for: kindID)
        self.horizontalInset = horizontalInset
    }

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("PACK CONTENTS · \(entries.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .tracking(2)
                    .padding(.leading, horizontalInset)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(entries, id: \.asset) { entry in
                            tile(entry)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
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
        .frame(width: 64)
    }
}
