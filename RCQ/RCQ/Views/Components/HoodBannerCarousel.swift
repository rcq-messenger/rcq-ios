import SwiftUI

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
        .padding(.horizontal, 16)
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
        .padding(.horizontal, 4)
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
    }

    private var carousel: some View {
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
                .padding(.horizontal, 4)
            }
            .frame(height: 88)
            .onChange(of: autoScrollIndex) { idx in
                guard !paused else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(idx, anchor: .leading)
                }
            }
            .simultaneousGesture(
                DragGesture()
                    .onChanged { _ in pauseAutoScroll() }
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

private struct HoodBannerCard: View {
    let banner: HoodBanner

    var body: some View {
        HStack(spacing: 10) {
            if let thumb = banner.imageThumbURL ?? banner.imageURL {
                AsyncImage(url: URL(string: thumb)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.black.opacity(0.2)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.text)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(banner.imageThumbURL != nil ? 2 : 3)
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
        .frame(width: 280, height: 80, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
    }

    private var authorLine: String {
        if banner.isAnonymous { return "hood_banner.anonymous".localized }
        if let nick = banner.ownerNickname { return nick }
        return ""
    }
}
