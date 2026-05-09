import SwiftUI
import UIKit

struct HoodBannerCarousel: View {
    let bucket: String
    @StateObject private var svc = HoodBannerService.shared
    @State private var selected: HoodBanner?
    @State private var showComposer = false
    @State private var showBoard = false
    @State private var autoScrollIndex: Int = 0
    @State private var paused = false
    @State private var resumeTask: Task<Void, Never>?

    private let autoScrollInterval: TimeInterval = 5

    private var banners: [HoodBanner] { svc.banners(for: bucket) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if banners.isEmpty {
                emptyState
            } else {
                carousel
            }
        }
        .padding(.bottom, 8)
        .task(id: bucket) { await svc.refresh(bucket: bucket) }
        .onReceive(Timer.publish(every: autoScrollInterval, on: .main, in: .common).autoconnect()) { _ in
            guard !paused, banners.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                autoScrollIndex = (autoScrollIndex + 1) % banners.count
            }
        }
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
        .sheet(isPresented: $showBoard) {
            HoodBannerBoardSheet(bucket: bucket, onSelect: { b in
                showBoard = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    selected = b
                }
            })
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
            if banners.count > 3 {
                Button {
                    showBoard = true
                } label: {
                    Text("hood_banner.show_all".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                }
                .buttonStyle(.plain)
            }
            Button {
                showComposer = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Color.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        Button {
            showComposer = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed.badge.plus")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.Color.textSecondary)
                Text("hood_banner.empty.cta".localized)
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var carousel: some View {
        if #available(iOS 17.0, *) {
            modernCarousel
        } else {
            legacyCarousel
        }
    }

    @available(iOS 17.0, *)
    private var modernCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(banners) { banner in
                    HoodBannerCard(banner: banner)
                        .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: 10)
                        .scrollTransition(.animated.threshold(.visible(0.7))) { c, phase in
                            c.opacity(phase.isIdentity ? 1.0 : 0.55)
                        }
                        .onTapGesture {
                            pauseAutoScroll()
                            selected = banner
                        }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .frame(height: 96)
        .simultaneousGesture(
            DragGesture().onChanged { _ in pauseAutoScroll() }
        )
    }

    private var legacyCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(banners.enumerated()), id: \.element.id) { idx, banner in
                        HoodBannerCard(banner: banner)
                            .id(idx)
                            .onTapGesture {
                                pauseAutoScroll()
                                selected = banner
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 96)
            .onChange(of: autoScrollIndex) { idx in
                guard !paused else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(idx, anchor: .leading)
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in pauseAutoScroll() }
            )
        }
    }

    private func pauseAutoScroll() {
        paused = true
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            if !Task.isCancelled {
                paused = false
            }
        }
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
