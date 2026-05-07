import SwiftUI

/// Token shop. Three packs from `/catalog`'s token_packs list, tap →
/// `/tokens/buy-pack` → server credits the wallet. Mock IAP for now;
/// real StoreKit lands in Session 5.
struct BuyTokensSheet: View {
    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var purchasingID: String?
    @State private var purchasedID: String?

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 10) {
                        if let packs = items.catalog?.tokenPacks {
                            ForEach(packs) { pack in
                                packRow(pack)
                            }
                        } else {
                            ProgressView()
                                .padding(.top, 40)
                        }
                        Text("shop.balance".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 60)
                }
            }
        }
        .task {
            if items.catalog == nil { await items.refreshCatalog() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("shop.kicker".localized)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.accent)
                .tracking(3)
            Text("shop.title".localized)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("shop.subtitle".localized)
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: - Pack row

    private func packRow(_ pack: TokenPack) -> some View {
        let isBest = pack.id == "rcq.tokens.100"
        let isBusy = purchasingID == pack.id
        let isDone = purchasedID == pack.id
        return Button {
            Task { await buy(pack) }
        } label: {
            HStack(spacing: 14) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "shop.tokens_n".localized, pack.tokens))
                        .font(Theme.Font.nickname)
                        .foregroundColor(Theme.Color.textPrimary)
                    if isBest {
                        Text("shop.best_value".localized)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.accent)
                            .tracking(2)
                    } else {
                        Text(pricePerToken(pack))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                Spacer()
                if isBusy {
                    ProgressView()
                } else if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Text(pack.priceLabel)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundColor(Theme.Color.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isDone)
    }

    private func pricePerToken(_ pack: TokenPack) -> String {
        let stripped = pack.priceLabel.replacingOccurrences(of: "$", with: "")
        guard let price = Double(stripped) else { return "" }
        let cents = (price * 100) / Double(pack.tokens)
        return String(format: "shop.per_token".localized, Int(cents))
    }

    @MainActor
    private func buy(_ pack: TokenPack) async {
        purchasingID = pack.id
        let ok = await items.buyTokenPack(pack)
        purchasingID = nil
        if ok {
            purchasedID = pack.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dismiss()
            }
        }
    }
}
