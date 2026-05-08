import SwiftUI

/// Inventory grid tile: kind asset, rarity dot top-right, mint badge bottom-left, temper +N top-left.
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
                        // Voice packs are .mp3 files; rendering would hit the cube placeholder.
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
            .opacity(item.equipped ? 0.55 : 1.0)
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
