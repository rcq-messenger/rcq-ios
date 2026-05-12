import SwiftUI

/// Renders a shared UIN-marketplace listing as a card inside a chat
/// bubble. Mirror of `MarketLinkBubble` for the UIN market.
struct UinLinkBubble: View {
    let listingID: String
    let rawURL: URL

    @EnvironmentObject private var appState: AppState
    @State private var listing: UinMarketplaceListing?
    @State private var loadFailed: Bool = false

    private static let cardWidth: CGFloat = 260

    var body: some View {
        Group {
            if let listing {
                card(listing)
            } else if loadFailed {
                fallback
            } else {
                placeholder
            }
        }
        .task(id: listingID) { await load() }
    }

    @ViewBuilder
    private func card(_ listing: UinMarketplaceListing) -> some View {
        // No Button wrapper — Button steals touchDown from the parent bubble's swipe-to-reply / long-press.
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Self.tierColor(for: listing.tier).opacity(0.35))
                    .frame(width: 72, height: 72)
                    .blur(radius: 18)
                VStack(spacing: 2) {
                    Text(verbatim: "#\(listing.uin)")
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(Self.tierLabel(for: listing.tier).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Self.tierColor(for: listing.tier)))
                }
            }
            .frame(width: 96, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                if let nick = listing.sellerNickname {
                    Text(nick)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 14, height: 14)
                    Text("\(listing.priceTokens)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
                Text("uin_listing.share.cta_open".localized)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.cardWidth)
        .background(Theme.Color.bgSecondary.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Color.divider, lineWidth: 0.5),
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.handle(deepLink: rawURL)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.Color.bgSecondary)
                .frame(width: 96, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.Color.bgSecondary)
                    .frame(width: 100, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.Color.bgSecondary)
                    .frame(width: 60, height: 10)
                ProgressView().scaleEffect(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.cardWidth, height: 96)
        .background(Theme.Color.bgSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fallback: some View {
        Button {
            appState.handle(deepLink: rawURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundColor(Theme.Color.accent)
                Text(rawURL.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if listing != nil { return }
        if let snap = await MarketService.shared.fetchUinListing(id: listingID) {
            listing = snap
        } else {
            loadFailed = true
        }
    }

    fileprivate static func tierColor(for tier: String) -> Color {
        switch tier {
        case "legendary": return Color(hex: 0xC8442A)
        case "mid":       return Color(hex: 0x8E5BD4)
        default:          return Color(hex: 0x6BB12C)
        }
    }
    fileprivate static func tierLabel(for tier: String) -> String {
        switch tier {
        case "legendary": return "uin.tier.legendary".localized
        case "mid":       return "uin.tier.mid".localized
        default:          return "uin.tier.common".localized
        }
    }
}

/// Compact UIN-listing card for the reply-composer strip.
struct UinReplyMiniCard: View {
    let listingID: String

    @State private var listing: UinMarketplaceListing?

    var body: some View {
        Group {
            if let listing {
                content(listing)
            } else {
                placeholder
            }
        }
        .task(id: listingID) { await load() }
    }

    @ViewBuilder
    private func content(_ listing: UinMarketplaceListing) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(UinLinkBubble.tierColor(for: listing.tier))
                .frame(width: 6, height: 6)
            Text(verbatim: "#\(listing.uin)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
                .lineLimit(1)
            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                .frame(width: 10, height: 10)
            Text("\(listing.priceTokens)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.Color.bgSecondary)
                .frame(width: 6, height: 6)
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.Color.bgSecondary)
                .frame(width: 80, height: 10)
        }
    }

    private func load() async {
        if listing != nil { return }
        if let snap = await MarketService.shared.fetchUinListing(id: listingID) {
            listing = snap
        }
    }
}

/// Parse a chat body for a single UIN-marketplace listing URL.
enum UinLinkParser {
    static func parse(_ body: String) -> (listingID: String, url: URL)? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        if url.scheme == "rcq" && url.host == "uin-listing" {
            let id = url.pathComponents.last ?? ""
            if !id.isEmpty { return (id, url) }
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "ul" {
            return (url.pathComponents[2], url)
        }
        return nil
    }
}
