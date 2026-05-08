import SwiftUI

/// Games hub. Lists available mini-games — for now just Crash, but
/// Hi-Lo and Limbo can slot in here as additional cards without any
/// nav-bar / routing changes. Mirrors the `InventoryView` /
/// `RouletteView` shape (full-screen cover, close on the leading
/// nav slot).
struct GamesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var items = ItemsService.shared

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
                // Make sure the wallet badge is fresh when this opens.
                await items.refreshInventory()
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

                // ── Solo (один игрок против дома) ─────────
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

                // ── PvP (общие раунды, видишь чужие ставки) ──
                sectionHeader("games.section.pvp".localized)

                // Crash — все игроки в одном раунде, видят ставки
                // и кэшауты друг друга в общем фиде. Multiplayer
                // по сути, поэтому сидит здесь, а не в Solo.
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

                gameCard(
                    icon: "pawprint.fill",
                    title: "games.pets_hunt.title".localized,
                    body: "games.pets_hunt.body".localized,
                    accent: Theme.Color.accent
                ) { showPetHunt = true }

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
        // Standard 4pt spacing between the coin and the digits, with
        // a positive trailing pad so the whole badge sits inset from
        // the right edge instead of jamming against the safe area.
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
