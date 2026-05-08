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

                // ── Pets — отдельная секция со своим hero-tile.
                // Питомцы — особая ветка экономики (passive farm +
                // permadeath ставки), её tile визуально отличается
                // от остальных: pet-portraits разбросаны по углам как
                // декор, gradient-фон, увеличенная высота.
                sectionHeader("games.section.pets".localized)

                petHuntHeroCard
                    .onTapGesture { showPetHunt = true }

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

    /// Hero tile for the Pets section. Tall card with a soft
    /// gradient + 4 pet GIF portraits scattered in the corners as
    /// low-opacity decor — calls out the section visually so it
    /// reads as its own thing, not just another row in PvP.
    /// Pet assets used here are pure decoration (Items/pet1.gif
    /// etc); no semantic link to the user's actual equipped pet.
    private var petHuntHeroCard: some View {
        let petDecor = ["pet1", "pet3", "pet6", "pet9"]
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    Color(hex: 0x6BB12C).opacity(0.20),
                    Color(hex: 0x4FA85F).opacity(0.10),
                    Theme.Color.bgSecondary,
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing,
            )
            .cornerRadius(14)

            // Decorative pet GIFs in 4 corners. `allowsHitTesting(false)`
            // so taps fall through to the parent tap-gesture; opacity
            // 0.55 keeps them as motif, not visual noise. Sizes alternate
            // so the composition doesn't feel grid-aligned.
            VStack {
                HStack {
                    petDecorTile(petDecor[0], size: 38)
                    Spacer()
                    petDecorTile(petDecor[1], size: 30).padding(.top, 12)
                }
                Spacer()
                HStack {
                    petDecorTile(petDecor[2], size: 32).padding(.bottom, 10)
                    Spacer()
                    petDecorTile(petDecor[3], size: 42)
                }
            }
            .padding(10)
            .allowsHitTesting(false)

            // Foreground content — paw icon + title/body + chevron.
            HStack(spacing: 14) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 56, height: 56)
                    .background(Theme.Color.accent.opacity(0.18))
                    .cornerRadius(14)
                VStack(alignment: .leading, spacing: 4) {
                    Text("games.pets_hunt.title".localized)
                        .font(.system(.headline, weight: .bold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("games.pets_hunt.body".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 130)
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func petDecorTile(_ filename: String, size: CGFloat) -> some View {
        ItemAssetImage(bundleSubdir: "Items", filename: filename, ext: "gif")
            .frame(width: size, height: size)
            .opacity(0.55)
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
