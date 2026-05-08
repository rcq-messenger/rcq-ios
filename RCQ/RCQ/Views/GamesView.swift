import SwiftUI

/// Games hub. Lists available mini-games.
struct GamesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var items = ItemsService.shared
    @StateObject private var petHunt = PetHuntService.shared

    @State private var showCrash = false
    @State private var showHiLo = false
    @State private var showLimbo = false
    @State private var showUinAuction = false
    @State private var showPetHunt = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
            }
            .navigationTitle("games.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    walletBadge
                }
            }
            .fullScreenCover(isPresented: $showCrash) { CrashView() }
            .fullScreenCover(isPresented: $showHiLo) { HiLoView() }
            .fullScreenCover(isPresented: $showLimbo) { LimboView() }
            .fullScreenCover(isPresented: $showUinAuction) { UinAuctionView() }
            .fullScreenCover(isPresented: $showPetHunt) { PetHuntView() }
            .task {
                await items.refreshInventory()
                await petHunt.refreshState()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("games.subtitle".localized)
                    .font(.footnote)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                sectionHeader("games.section.pets".localized)

                petHuntHeroCard
                    .onTapGesture { showPetHunt = true }

                sectionHeader("games.section.solo".localized)

                gameCard(
                    icon: "rectangle.stack",
                    title: "games.hi_lo.title".localized,
                    body: "games.hi_lo.body".localized,
                    accent: Theme.Color.accent
                ) { showHiLo = true }

                gameCard(
                    icon: "arrow.up.forward",
                    title: "games.limbo.title".localized,
                    body: "games.limbo.body".localized,
                    accent: Theme.Color.accent
                ) { showLimbo = true }

                sectionHeader("games.section.pvp".localized)

                gameCard(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "games.crash.title".localized,
                    body: "games.crash.body".localized,
                    accent: Theme.Color.accent
                ) { showCrash = true }

                gameCard(
                    icon: "number.circle.fill",
                    title: "games.uin_auction.title".localized,
                    body: "games.uin_auction.body".localized,
                    accent: Theme.Color.accent
                ) { showUinAuction = true }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
    }

    private var petHuntHeroCard: some View {
        let equipped = items.ownEquippedPet
        return ZStack {
            LinearGradient(
                colors: [
                    Color(hex: 0x6BB12C).opacity(0.20),
                    Color(hex: 0x4FA85F).opacity(0.10),
                    Theme.Color.bgSecondary,
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing,
            )
            .cornerRadius(14)

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 56, height: 56)
                    .background(Theme.Color.accent.opacity(0.18))
                    .cornerRadius(14)
                VStack(alignment: .leading, spacing: 6) {
                    Text("games.pets_hunt.title".localized)
                        .font(.system(.headline, weight: .bold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("games.pets_hunt.body".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let equipped {
                    equippedPetColumn(equipped)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func equippedPetColumn(_ pet: EquippedPet) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 11, height: 11)
                Text("\(petHunt.state?.dailyYield ?? 0)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textPrimary)
                Rectangle()
                    .fill(Theme.Color.divider)
                    .frame(width: 0.5, height: 10)
                    .padding(.horizontal, 1)
                ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                    .frame(width: 11, height: 11)
                Text("\(petHunt.state?.dailyGems ?? 0)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            ItemAssetImage(
                bundleSubdir: petAssetSubdir(for: pet),
                filename: petAssetStem(for: pet),
                ext: petAssetExt(for: pet),
            )
            .frame(width: 64, height: 64)
        }
    }

    private func petAssetSubdir(for pet: EquippedPet) -> String {
        guard let kind = items.catalog?.kind(by: pet.kindID) else { return "Items" }
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let subdir = (trimmed as NSString).deletingLastPathComponent
        return subdir.isEmpty ? "Items" : "Items/\(subdir)"
    }

    private func petAssetStem(for pet: EquippedPet) -> String {
        guard let kind = items.catalog?.kind(by: pet.kindID) else { return "" }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }

    private func petAssetExt(for pet: EquippedPet) -> String {
        guard let kind = items.catalog?.kind(by: pet.kindID) else { return "png" }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }

    private func gameCard(
        icon: String, title: String, body: String, accent: Color,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(accent)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.12))
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(body)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(14)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func comingSoonCard(title: String, body: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 44, height: 44)
                .background(Theme.Color.divider.opacity(0.3))
                .cornerRadius(10)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("games.soon".localized)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.Color.textSecondary.opacity(0.5))
                        .cornerRadius(3)
                }
                Text(body)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.Color.bgSecondary.opacity(0.5))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var walletBadge: some View {
        let tokens = items.wallet.tokens
        HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                .frame(width: 18, height: 18)
            Text("\(tokens)")
                .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.Color.textPrimary)
        }
        .padding(.trailing, 8)
    }
}
