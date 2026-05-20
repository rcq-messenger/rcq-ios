import SwiftUI

/// Vertical grid preview of a cosmetic pack's contents. Renders one
/// thumbnail per pack entry — animated GIF tiles play live so users
/// see exactly what they're getting before they equip / open. Used
/// in:
///   - PoolBrowserView's pack-detail sheet (always expanded)
///   - ItemDetailSheet (collapsible, collapsed by default)
///
/// Grid uses `LazyVGrid` with an adaptive column track so packs of
/// 30+ stickers wrap onto multiple rows instead of trailing off the
/// screen edge in a single horizontal strip.
///
/// Per-entry names are deliberately NOT rendered — the GIF itself is
/// the preview; the `:code:` label was visual noise.
///
/// Empty for non-pack kinds (relics, founders) — caller should
/// branch on `appliesAs` and not render this for them.
struct KindContentsView: View {
    let kindID: String
    let entries: [CosmeticPacks.Entry]
    /// Match the caller's outer `.padding(.horizontal, …)` so the
    /// title + first tile align with peer content.
    var horizontalInset: CGFloat = 18
    /// When true, the header acts as a disclosure toggle and the
    /// grid starts hidden. ItemDetailSheet opts in so a 30-sticker
    /// pack doesn't shove the action buttons + history far down the
    /// scroll. PoolBrowserView leaves it off — there the grid is
    /// the whole point of the screen.
    var collapsible: Bool = false

    @State private var expanded: Bool

    init(kindID: String, horizontalInset: CGFloat = 18, collapsible: Bool = false) {
        self.kindID = kindID
        self.entries = CosmeticPacks.entries(for: kindID)
        self.horizontalInset = horizontalInset
        self.collapsible = collapsible
        // Collapsible callers start collapsed; always-expanded callers
        // render the grid immediately.
        _expanded = State(initialValue: !collapsible)
    }

    private static let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 64, maximum: 80), spacing: 6, alignment: .top),
    ]

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                if expanded {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                        ForEach(entries, id: \.asset) { entry in
                            tile(entry)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let label = Text(String(format: "pool.pack.contents".localized, entries.count))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(Theme.Color.textSecondary)
            .tracking(2)
        if collapsible {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    label
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.Color.textSecondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Spacer()
                }
                .padding(.leading, horizontalInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            label.padding(.leading, horizontalInset)
        }
    }

    private func tile(_ entry: CosmeticPacks.Entry) -> some View {
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
    }
}
