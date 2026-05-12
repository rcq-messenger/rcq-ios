import SwiftUI

/// Status icon with an optional equipped-pet GIF overlaid on its bottom-right corner.
/// Overlay keeps parent layout stable — pet bleeds past the icon frame without claiming extra width.
struct StatusWithPet: View {
    let status: UserStatus
    let pet: EquippedPet?
    var size: CGFloat = 24

    @StateObject private var items = ItemsService.shared

    private static let petScale: CGFloat = 0.95

    var body: some View {
        StatusIcon(status: status, size: size)
            .overlay(alignment: .bottomTrailing) {
                if let pet, let basename = petBasename(for: pet.kindID) {
                    petGlyph(basename: basename, rarity: pet.rarity)
                        .frame(width: size * Self.petScale,
                               height: size * Self.petScale)
                        .offset(x: size * 0.30, y: size * 0.10)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func petGlyph(basename: String, rarity: ItemRarity) -> some View {
        ZStack {
            Circle()
                .fill(rarity.color.opacity(0.35))
                .blur(radius: size * 0.18)
                .scaleEffect(1.10)
            GIFImage(name: basename)
                .shadow(color: .black.opacity(0.30),
                        radius: size * 0.06, x: 0, y: size * 0.04)
                .breathingPet()
        }
    }

    private func petBasename(for kindID: String) -> String? {
        guard let kind = items.catalog?.kind(by: kindID) else { return nil }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
}
