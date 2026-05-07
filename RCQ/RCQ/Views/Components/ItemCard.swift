import SwiftUI

/// Inventory grid tile. Square frame, kind asset on a neutral
/// background, rarity rendered as a small coloured dot in the
/// top-right corner — same idiom the pool browser uses. No coloured
/// border, no bottom stripe; the dot carries the rarity signal.
///
/// Mint badge (`#42`) sits at bottom-left when capped. Temper level
/// (`+N`) sits top-left. Equipped flag — small accent dot stacked
/// next to the rarity dot in the top-right.
struct ItemCard: View {
    let item: Item
    @StateObject private var items = ItemsService.shared

    private var kind: ItemKind? {
        items.catalog?.kind(by: item.kindID)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.Color.bgSecondary)
            Group {
                if let kind {
                    if kind.section == .voices {
                        // Voice packs ship as bare audio files; rendering
                        // the .mp3 as an image would just hit the cube
                        // placeholder. Music note glyph tinted by rarity
                        // reads as "this is a sound" without wasting a
                        // sprite slot per pack.
                        Image(systemName: "music.note")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(item.rarity.color)
                            .padding(8)
                    } else {
                        ItemAssetImage(
                            bundleSubdir: assetSubdir(for: kind),
                            filename: assetStem(for: kind),
                            ext: assetExt(for: kind),
                        )
                        .padding(8)
                    }
                } else {
                    Image(systemName: "cube")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(Theme.Color.divider)
                }
            }
            // Equipped state is communicated by dimming the entire
            // tile rather than stacking a second dot — the rarity
            // dot in the corner is already the visual anchor, a
            // green dot next to it competed with it. Owner sees
            // their equipped packs as the "in use elsewhere"
            // visual texture.
            .opacity(item.equipped ? 0.55 : 1.0)
            // Rarity dot — top-right corner.
            VStack {
                HStack {
                    Spacer()
                    Circle()
                        .fill(item.rarity.color)
                        .frame(width: 7, height: 7)
                }
                Spacer()
            }
            .padding(4)
            // Mint badge — bottom-left.
            if let badge = item.mintBadge {
                VStack {
                    Spacer()
                    HStack {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(item.rarity.color)
                            .cornerRadius(2)
                            .padding(4)
                        Spacer()
                    }
                }
            }
            // +N temper level — top-left. `.thinMaterial` plus a
            // black 25%-tint underlay reads as a slightly tinted
            // glass pill — darker than ultraThin but still legible
            // over both light and dark icons.
            if item.level > 0 {
                VStack {
                    HStack {
                        Text("+\(item.level)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                ZStack {
                                    Rectangle().fill(.thinMaterial)
                                    Rectangle().fill(Color.black.opacity(0.25))
                                }
                            )
                            .cornerRadius(2)
                            .padding(4)
                        Spacer()
                    }
                    Spacer()
                }
            }
            // Marketplace listed indicator. Green dim overlay + small
            // cart pill bottom-right — same shape language as the
            // mint badge bottom-left so the eye groups them as
            // tile-meta. Hidden when not listed; doesn't compete
            // with equipped dimming because items can't be both
            // listed AND equipped (server gates the list call).
            if item.listed {
                Rectangle()
                    .fill(Theme.Color.accent.opacity(0.18))
                    .allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "cart.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.Color.accent)
                            .cornerRadius(2)
                            .padding(4)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func assetSubdir(for kind: ItemKind) -> String {
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let subdir = (trimmed as NSString).deletingLastPathComponent
        return subdir.isEmpty ? "Items" : "Items/\(subdir)"
    }

    private func assetStem(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }

    private func assetExt(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}
