import AVKit
import SwiftUI

/// Broadcast news from the team — patch notes, announcements,
/// thoughts. Accessed from the 3-dot menu on the contacts screen.
/// Sets `markAllSeen()` on appear so the red unread indicator
/// clears once the user has at least surfaced the sheet.
///
/// Attachments are public (no per-recipient encryption) and load
/// straight from `/news/media/{id}`. The list is intentionally
/// chronological newest-first — short feed, no pagination needed
/// at the scale we expect through launch.
struct NewsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = NewsService.shared
    /// Drives the full-screen gallery viewer. Holds the current
    /// post + index of the tapped image so swiping inside the
    /// viewer can page through the post's other attachments.
    @State private var galleryTarget: GalleryTarget?

    var body: some View {
        NavigationStack {
            Group {
                if svc.items.isEmpty {
                    empty
                } else {
                    feed
                }
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("news.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task {
                await svc.refresh()
                svc.markAllSeen()
            }
            .fullScreenCover(item: $galleryTarget) { target in
                NewsGalleryView(
                    attachments: target.attachments,
                    initialIndex: target.startIndex,
                )
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.textSecondary)
            Text("news.empty".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var feed: some View {
        // Explicit per-card width — async media inside the card
        // would otherwise advertise its intrinsic size and grow
        // the row on a second layout pass.
        GeometryReader { geo in
            let cardWidth = max(0, geo.size.width - 32)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(svc.items) { post in
                        NewsPostCard(
                            post: post,
                            cardWidth: cardWidth,
                            onTapImage: { idx in
                                // Restrict the gallery to image-kind attachments —
                                // video taps stay on the inline player so the
                                // user doesn't get yanked into a fullscreen
                                // viewer that can't play them.
                                let imageAttachments = post.attachments.filter { $0.kind != "video" }
                                let tapped = post.attachments[idx]
                                let filteredIdx = imageAttachments.firstIndex(where: { $0.mediaID == tapped.mediaID }) ?? 0
                                galleryTarget = GalleryTarget(
                                    postID: post.id,
                                    attachments: imageAttachments,
                                    startIndex: filteredIdx,
                                )
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }
}

/// Sheet-presentation target for the news image gallery. Identifiable
/// keyed off the post + start index so re-tapping a different image
/// in the same post re-presents the viewer at the new page.
private struct GalleryTarget: Identifiable, Hashable {
    let postID: Int
    let attachments: [NewsPost.Attachment]
    let startIndex: Int
    var id: String { "\(postID)-\(startIndex)-\(attachments.count)" }
}

/// Single post card. Body + attachment strip. Attachment URLs resolve
/// via `APIClient.baseURL`.
private struct NewsPostCard: View {
    let post: NewsPost
    /// Explicit width from the parent feed.
    let cardWidth: CGFloat
    /// Tapped attachment index in `post.attachments`.
    let onTapImage: (Int) -> Void

    private var slotWidth: CGFloat { max(0, cardWidth - 28) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.authorLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(Self.dateFormatter.string(from: post.publishedAt))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
            }
            Text(post.body)
                .font(.body)
                .foregroundColor(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !post.attachments.isEmpty {
                attachmentCarousel
            }
        }
        .padding(14)
        .frame(width: cardWidth, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Horizontal media carousel. Pure SwiftUI HStack paging with
    /// explicit per-slot sizing (no GeometryReader inside).
    @ViewBuilder
    private var attachmentCarousel: some View {
        let attachments = post.attachments
        let height: CGFloat = 240
        if attachments.count == 1 {
            attachmentView(attachments[0], index: 0)
                .frame(width: slotWidth, height: height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            CustomPagingCarousel(
                pageCount: attachments.count,
                pageWidth: slotWidth,
                pageHeight: height,
            ) { idx in
                attachmentView(attachments[idx], index: idx)
                    .frame(width: slotWidth, height: height)
                    .clipped()
            }
            .frame(width: slotWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func attachmentView(_ att: NewsPost.Attachment, index: Int) -> some View {
        let url = APIClient.shared.baseURL.appendingPathComponent("news/media/\(att.mediaID)")
        switch att.kind {
        case "video":
            // Color.clear overlay — clear has no intrinsic size, so the
            // overlay child is bound to the parent slot and can't
            // advertise its native dimensions upward.
            Color.clear
                .overlay {
                    VideoPlayer(player: AVPlayer(url: url))
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        default:
            Color.clear
                .overlay {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Theme.Color.divider)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { onTapImage(index) }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Full-screen image viewer for news attachments. Horizontal swipe
/// pages through the post's images; tap-to-dismiss anywhere outside
/// the active image. Background is solid black so the focus stays
/// on the photo regardless of source aspect ratio.
private struct NewsGalleryView: View {
    let attachments: [NewsPost.Attachment]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex: Int
    @State private var dragOffset: CGFloat = 0
    /// Locked on first significant motion so horizontal paging
    /// doesn't drift the image down.
    @State private var gestureAxis: GestureAxis = .undecided

    private enum GestureAxis { case undecided, vertical, horizontal }

    init(attachments: [NewsPost.Attachment], initialIndex: Int) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        self._pageIndex = State(initialValue: initialIndex)
    }

    /// Backdrop fades as the user drags toward the bottom edge.
    private var backdropOpacity: Double {
        let normalized = min(1.0, max(0.0, dragOffset / 240.0))
        return 1.0 - normalized * 0.6
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()
            TabView(selection: $pageIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, att in
                    page(for: att)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .offset(y: dragOffset)
            // Direction-locked swipe-down dismiss; goes inert once the
            // gesture reads as horizontal so TabView paging isn't
            // fought.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        let dx = v.translation.width
                        let dy = v.translation.height
                        if gestureAxis == .undecided {
                            if abs(dx) + abs(dy) < 12 { return }
                            gestureAxis = abs(dy) > abs(dx) * 1.2 ? .vertical : .horizontal
                        }
                        guard gestureAxis == .vertical, dy > 0 else { return }
                        dragOffset = dy
                    }
                    .onEnded { v in
                        defer { gestureAxis = .undecided }
                        guard gestureAxis == .vertical else {
                            if dragOffset != 0 {
                                withAnimation(.easeOut(duration: 0.18)) { dragOffset = 0 }
                            }
                            return
                        }
                        if v.translation.height > 120 || v.predictedEndTranslation.height > 240 {
                            dismiss()
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
    }

    @ViewBuilder
    private func page(for att: NewsPost.Attachment) -> some View {
        let url = APIClient.shared.baseURL.appendingPathComponent("news/media/\(att.mediaID)")
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.white.opacity(0.7))
                    Text("news.gallery.failed".localized)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            default:
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// SwiftUI paging carousel with explicit `pageWidth/pageHeight` from
/// the caller — no GeometryReader, TabView, or UIPageViewController.
private struct CustomPagingCarousel<PageContent: View>: View {
    let pageCount: Int
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    @ViewBuilder let pageContent: (Int) -> PageContent

    @State private var currentPage: Int = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { idx in
                    pageContent(idx)
                        .frame(width: pageWidth, height: pageHeight)
                }
            }
            .frame(width: pageWidth, height: pageHeight, alignment: .leading)
            .offset(x: -CGFloat(currentPage) * pageWidth + dragOffset)
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86), value: currentPage)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in dragOffset = v.translation.width }
                    .onEnded { v in
                        let dx = v.translation.width
                        let predicted = v.predictedEndTranslation.width
                        let threshold = pageWidth * 0.25
                        let flickThreshold = pageWidth * 0.5
                        var next = currentPage
                        if (dx < -threshold || predicted < -flickThreshold) && currentPage < pageCount - 1 {
                            next = currentPage + 1
                        } else if (dx > threshold || predicted > flickThreshold) && currentPage > 0 {
                            next = currentPage - 1
                        }
                        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                            currentPage = next
                            dragOffset = 0
                        }
                    }
            )
            if pageCount > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { idx in
                        Circle()
                            .fill(idx == currentPage
                                  ? Color.white
                                  : Color.white.opacity(0.45))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.black.opacity(0.35)))
                .padding(.bottom, 8)
            }
        }
        .frame(width: pageWidth, height: pageHeight)
    }
}
