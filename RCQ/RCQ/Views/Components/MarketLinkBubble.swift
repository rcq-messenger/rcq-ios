import SwiftUI

/// Renders a marketplace listing as a rich card inside a chat bubble.
/// Used when the message body is a `rcq://market/{id}` or
/// `https://rcq.app/m/{id}` deep-link — `TextBubble` detects the
/// pattern and swaps its rendering to this card.
///
/// Async-fetches the listing from `MarketService` on appear. Tap →
/// routes the link through `AppState.handle(deepLink:)` so the same
/// path opens the listing whether the user got here from a chat,
/// notification, or external share.
struct MarketLinkBubble: View {
    let listingID: String
    /// Pasted along so a fallback render (network-failed / 404) still
    /// has a tappable plain-text URL the user can long-press to copy.
    let rawURL: URL

    @EnvironmentObject private var appState: AppState
    @StateObject private var items = ItemsService.shared
    @State private var listing: MarketplaceListing?
    @State private var loadFailed: Bool = false

    private static let cardWidth: CGFloat = 260
    private static let cardHeight: CGFloat = 96

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
    private func card(_ listing: MarketplaceListing) -> some View {
        let kind = items.catalog?.kind(by: listing.kindID)
        // No Button wrapper — using `.onTapGesture` on a regular
        // View instead. Button intercepts touchDown which steals it
        // from the parent message bubble's swipe-to-reply / long-
        // press-for-context-menu (Delete, Forward, Reply). User
        // reported the share-bubble was un-deletable + caused
        // open-on-swipe. Plain tap gesture defers to parent
        // gestures correctly.
        HStack(spacing: 10) {
                ZStack {
                    // Rarity-colored glow behind the asset — mirrors
                    // the detail sheet / inventory / pet-hunt look so
                    // the chat preview reads as the same item, not a
                    // stripped-down border-only variant.
                    if let kind, kind.section != .voices {
                        Circle()
                            .fill(listing.rarity.color.opacity(0.45))
                            .frame(width: 80, height: 80)
                            .blur(radius: 20)
                    }
                    if let kind {
                        if kind.section == .voices {
                            Image(systemName: "music.note")
                                .resizable()
                                .scaledToFit()
                                .fontWeight(.semibold)
                                .foregroundColor(listing.rarity.color)
                                .padding(16)
                        } else {
                            ItemAssetImage(
                                bundleSubdir: Self.assetSubdir(kind),
                                filename: Self.assetStem(kind),
                                ext: Self.assetExt(kind),
                            )
                            .padding(6)
                        }
                    } else {
                        Image(systemName: "cube")
                            .foregroundColor(Theme.Color.divider)
                    }
                }
                .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ItemDisplay.name(for: listing.kindID))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(listing.rarity.label)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(listing.rarity.color)
                    HStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 14, height: 14)
                        Text("\(listing.priceTokens)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                Spacer(minLength: 0)
            }
        .padding(8)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(Theme.Color.bgSecondary.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Color.divider, lineWidth: 0.5),
        )
        // Top-right stat badges (level + essence). HStack so they sit
        // on the same row without pushing the price/name column.
        .overlay(alignment: .topTrailing) {
            let essence = listing.showcaseValue(catalog: items.catalog)
            HStack(spacing: 4) {
                if listing.level > 0 {
                    Text("+\(listing.level)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                if essence > 0 {
                    HStack(spacing: 3) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "essence", ext: "png")
                            .frame(width: 11, height: 11)
                        Text("\(essence)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(Theme.Color.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Color.bgPrimary.opacity(0.85)))
                }
            }
            .padding(6)
        }
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
                .frame(width: 72, height: 72)
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
        .frame(width: Self.cardWidth, height: Self.cardHeight)
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
        if items.catalog == nil { await items.refreshCatalog() }
        if let snap = await MarketService.shared.fetchListing(id: listingID) {
            listing = snap
        } else {
            loadFailed = true
        }
    }

    // Mirrors `MarketView.assetSubdir/Stem/Ext` — split out as static
    // helpers here so this bubble doesn't depend on private members
    // of MarketView.
    private static func assetSubdir(_ kind: ItemKind) -> String {
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let subdir = (trimmed as NSString).deletingLastPathComponent
        return subdir.isEmpty ? "Items" : "Items/\(subdir)"
    }
    private static func assetStem(_ kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private static func assetExt(_ kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}

/// Compact market-listing card for the reply-composer strip.
struct MarketReplyMiniCard: View {
    let listingID: String

    @StateObject private var items = ItemsService.shared
    @State private var listing: MarketplaceListing?

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
    private func content(_ listing: MarketplaceListing) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(listing.rarity.color)
                .frame(width: 6, height: 6)
            Text(ItemDisplay.name(for: listing.kindID))
                .font(.caption2.weight(.semibold))
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
        if items.catalog == nil { await items.refreshCatalog() }
        if let snap = await MarketService.shared.fetchListing(id: listingID) {
            listing = snap
        }
    }
}

/// Parse a chat-message body to see whether it's a single market URL.
/// Returns `(listingID, originalURL)` if it is, else nil. Used by
/// `TextBubble` to decide whether to render plain text or the rich
/// `MarketLinkBubble`.
enum MarketLinkParser {
    static func parse(_ body: String) -> (listingID: String, url: URL)? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        if url.scheme == "rcq" && url.host == "market" {
            let id = url.pathComponents.last ?? ""
            if !id.isEmpty { return (id, url) }
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "m" {
            return (url.pathComponents[2], url)
        }
        return nil
    }
}
