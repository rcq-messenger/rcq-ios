import SwiftUI
import UIKit

/// Horizontal strip of active district banners (max 5 per bucket — the
/// backend caps the roster). Tap a card to open the detail sheet. The
/// "Post banner" CTA is a single capsule below the strip, and flips
/// to a disabled "Bucket full" state when `canPost == false`.
struct HoodBannerCarousel: View {
    let bucket: String
    @StateObject private var svc = HoodBannerService.shared
    @State private var selected: HoodBanner?
    @State private var showComposer = false

    private var banners: [HoodBanner] { svc.banners(for: bucket) }
    private var canPost: Bool { svc.canPost(in: bucket) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if banners.isEmpty {
                emptyState
            } else {
                carousel
            }
            postCTA
        }
        .padding(.bottom, 8)
        .task(id: bucket) { await svc.refresh(bucket: bucket) }
        .sheet(item: $selected) { banner in
            HoodBannerDetailSheet(banner: banner, bucket: bucket)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showComposer) {
            HoodBannerComposer(bucket: bucket)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            Text("hood_banner.section.title".localized)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        // Lone soft prompt — the actual CTA is the capsule below.
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 18))
                .foregroundColor(Theme.Color.textSecondary)
            Text("hood_banner.empty.subtitle".localized)
                .font(.system(.caption, weight: .medium))
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(banners) { banner in
                    HoodBannerCard(banner: banner)
                        .frame(width: 240)
                        .onTapGesture {
                            selected = banner
                        }
                }
            }
            // Trailing padding so the last chip is fully visible
            // instead of clipped against the right edge.
            .padding(.horizontal, 16)
        }
        .frame(height: 96)
    }

    @ViewBuilder
    private var postCTA: some View {
        Button {
            if canPost { showComposer = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: canPost ? "plus.circle.fill" : "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(canPost
                     ? "hood_banner.post_cta".localized
                     : "hood_banner.full".localized)
                    .font(.system(.callout, weight: .semibold))
            }
            .foregroundColor(canPost ? .white : Theme.Color.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                Capsule().fill(canPost ? Theme.Color.accent : Theme.Color.bgSecondary)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canPost)
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }
}

struct HoodBannerCard: View {
    let banner: HoodBanner

    var body: some View {
        HStack(spacing: 10) {
            if banner.imageURL != nil {
                BannerThumbnail(imageRef: banner.imageThumbURL ?? banner.imageURL)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.text)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(banner.imageURL != nil ? 2 : 3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(authorLine)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 88, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
    }

    private var authorLine: String {
        if banner.isAnonymous { return "hood_banner.anonymous".localized }
        if let nick = banner.ownerNickname { return nick }
        return ""
    }
}

/// Renders a banner image. Banner image_url uses the format
/// `mediaID|keyBase64` — the same encrypted-blob pattern as photo
/// messages, decrypted client-side via MediaService.loadImage.
struct BannerThumbnail: View {
    let imageRef: String?
    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .tint(Theme.Color.textSecondary)
            }
        }
        .task(id: imageRef) {
            await load()
        }
    }

    private func load() async {
        guard let imageRef, image == nil, !isLoading else { return }
        let parts = imageRef.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        isLoading = true
        let img = await MediaService.shared.loadImage(mediaID: parts[0], keyBase64: parts[1])
        image = img
        isLoading = false
    }
}
