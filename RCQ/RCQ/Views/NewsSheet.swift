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
        ScrollView {
            VStack(spacing: 12) {
                ForEach(svc.items) { post in
                    NewsPostCard(post: post, onTapImage: { idx in
                        // Restrict the gallery to image-kind attachments —
                        // video taps stay on the inline player so the
                        // user doesn't get yanked into a fullscreen
                        // viewer that can't play them.
                        let imageAttachments = post.attachments.filter { $0.kind != "video" }
                        // Translate the tapped attachment's index in the
                        // mixed list to its index in the filtered list.
                        let tapped = post.attachments[idx]
                        let filteredIdx = imageAttachments.firstIndex(where: { $0.mediaID == tapped.mediaID }) ?? 0
                        galleryTarget = GalleryTarget(
                            postID: post.id,
                            attachments: imageAttachments,
                            startIndex: filteredIdx,
                        )
                    })
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
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

/// Single post card. Renders body + attachment strip. Attachment URLs
/// resolve via `APIClient.baseURL` so dev / prod toggles automatically.
private struct NewsPostCard: View {
    let post: NewsPost
    /// Index of the tapped attachment within `post.attachments` —
    /// the parent maps it to the gallery's image-only filtered list.
    let onTapImage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "megaphone.fill")
                    .font(.caption)
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.Color.accent.opacity(0.12))
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
                VStack(spacing: 6) {
                    ForEach(Array(post.attachments.enumerated()), id: \.offset) { idx, att in
                        attachmentView(att, index: idx)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func attachmentView(_ att: NewsPost.Attachment, index: Int) -> some View {
        let url = APIClient.shared.baseURL.appendingPathComponent("news/media/\(att.mediaID)")
        switch att.kind {
        case "video":
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        default:
            // Images + GIFs share the same renderer; tap routes
            // into the fullscreen gallery for both.
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Rectangle()
                    .fill(Theme.Color.divider)
                    .frame(height: 180)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

    init(attachments: [NewsPost.Attachment], initialIndex: Int) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        self._pageIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $pageIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, att in
                    page(for: att)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
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
