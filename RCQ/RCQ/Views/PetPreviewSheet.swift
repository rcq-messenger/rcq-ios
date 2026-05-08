import SwiftUI

/// Read-only sheet for another user's equipped pet.
struct PetPreviewSheet: View {
    let pet: EquippedPet
    let ownerUIN: Int
    let ownerNickname: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var items = ItemsService.shared
    @State private var showInventory = false

    private var kind: ItemKind? {
        items.catalog?.kind(by: pet.kindID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    petHero
                    title
                    specTable
                    viewInventoryCTA
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showInventory) {
                PublicInventoryView(uin: ownerUIN, nickname: ownerNickname)
            }
        }
    }

    private var petHero: some View {
        ZStack {
            Circle()
                .fill(pet.rarity.color.opacity(0.45))
                .frame(width: 180, height: 180)
                .blur(radius: 32)
            if let basename = petBasename {
                GIFImage(name: basename)
                    .frame(width: 144, height: 144)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 58))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 144, height: 144)
            }
        }
    }

    private var title: some View {
        VStack(spacing: 4) {
            Text(ItemDisplay.name(for: pet.kindID))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
            if let lore = ItemDisplay.lore(for: pet.kindID) {
                Text(lore)
                    .font(.footnote)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
        }
    }

    private var specTable: some View {
        VStack(spacing: 0) {
            specRow(label: "market.spec.owner".localized) {
                Text(ownerNickname)
                    .font(.callout.weight(.medium))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            specDivider
            specRow(label: "market.spec.tier".localized) {
                Text(pet.rarity.label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(pet.rarity.color)
            }
            if pet.level > 0 {
                specDivider
                specRow(label: "market.spec.level".localized) {
                    Text("+\(pet.level)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            if let purity = pet.purity, purity != 1.0 {
                specDivider
                specRow(label: "market.spec.purity".localized) {
                    Text(String(format: "%.2f×", purity))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            if let mint = pet.mintNumber {
                specDivider
                specRow(label: "item.stat.mint".localized) {
                    Text(verbatim: "#\(mint)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            if let essence = pet.baseEssence {
                specDivider
                specRow(label: "market.spec.essence".localized) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                        Text("\(essence)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(Theme.Color.accent)
                }
            }
        }
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
    }

    private func specRow<Content: View>(
        label: String, @ViewBuilder value: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
            value()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var specDivider: some View {
        Rectangle()
            .fill(Theme.Color.divider.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    private var viewInventoryCTA: some View {
        Button { showInventory = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                Text(String(format: "pet_preview.cta.see_more".localized, ownerNickname))
            }
            .font(.system(.callout, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.Color.accent)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private var petBasename: String? {
        guard let kind else { return nil }
        let base = (kind.assetRef as NSString).lastPathComponent
        return (base as NSString).deletingPathExtension
    }
}
