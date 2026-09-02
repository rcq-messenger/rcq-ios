import AVKit
import SwiftUI

/// Broadcast news from the island — patch notes, announcements,
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
    /// `/news` is asked of the active account's island, so the author line
    /// names THAT island, drawn the way the switcher pill and the Settings row
    /// draw it, and not a team a self-hoster's island has never heard of.
    @StateObject private var appState = AppState.shared
    @StateObject private var accountManager = AccountManager.shared
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
            // A post published WHILE the sheet is open (news_posted refresh):
            // the reader is looking straight at it, so it is seen; without
            // this the dot re-lights behind the open sheet and survives
            // until the next open.
            .onChange(of: svc.latestID) { _ in svc.markAllSeen() }
            .fullScreenCover(item: $galleryTarget) { target in
                NewsGalleryView(
                    attachments: target.attachments,
                    initialIndex: target.startIndex,
                )
            }
            // A link in a post body opens over the app in the in-app browser,
            // like every other link in RCQ, instead of throwing the reader out
            // to Safari. Stated here rather than inherited from the root so a
            // tap keeps working whoever presents this sheet.
            .environment(\.openURL, OpenURLAction { url in InAppBrowser.open(url) })
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
            // Resolved once per feed, not once per card: it reads the account
            // card off UserDefaults, and every post is from the same island.
            let island = activeIsland
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(svc.items) { post in
                        NewsPostCard(
                            post: post,
                            island: island,
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

    /// The live facts for the island we are ON, falling back to the account's
    /// card so a cold start draws the right name and picture before
    /// `/server/info` has answered, and to the bare host for an island that
    /// never has. Same three-step fallback as the switcher pill.
    private var activeIsland: NewsIsland {
        let card = accountManager.activeAccountID.flatMap { AccountCardCache.card(for: $0) }
        let live = appState.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewsIsland(
            name: live.isEmpty ? (card?.islandName ?? "") : live,
            host: accountManager.active?.displayHost ?? card?.host ?? "",
            logoVersion: appState.serverLogoVersion.isEmpty
                ? (card?.islandLogoVersion ?? "")
                : appState.serverLogoVersion
        )
    }
}

/// Who a post is from: the island the feed was read from (founder, 2026-09-02:
/// the island's own logo and name on every client, never "RCQ Team"; a
/// self-hoster's news come from their own island under their own name).
private struct NewsIsland: Equatable {
    /// What the island calls itself. "" on an island whose operator left it
    /// blank, and until the first `/server/info` of an island never recorded.
    let name: String
    let host: String
    let logoVersion: String

    /// The name, or the host, which is all we honestly know about an island
    /// that has never said its name.
    var title: String { name.isEmpty ? host : name }

    /// The label the post was published under, kept only when it says
    /// something the island's own name does not. The island's default label
    /// was "RCQ Team" until 2026-09-02 and is its name from then on, and
    /// either one repeated after the name is noise; anything else ("Support",
    /// a person's name) is the operator telling the reader who wrote it.
    func customAuthor(_ label: String) -> String? {
        let author = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { return nil }
        let taken = ["rcq team", "rcq", name.lowercased(), host.lowercased()]
        guard !taken.contains(author.lowercased()) else { return nil }
        return author
    }
}

/// Turns the plain text of a news post into an `AttributedString` with its
/// links tappable. Posts are written by hand and routinely carry a release
/// link or a Habr article, and as plain `Text` they were dead on the screen.
///
/// `NSDataDetector` does the finding, but its idea of where a link ends is not
/// a Russian sentence's: it already drops a trailing `.` or `,`, and it keeps a
/// Cyrillic path (percent-encoding it correctly), but it swallows a closing
/// `»` and everything glued after it, and it keeps a trailing `?` that was the
/// question mark of the sentence. Both are narrowed off here.
private enum NewsBodyText {

    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Characters that never appear inside a link somebody typed, but do
    /// appear right after one in Russian text. The match is cut at the first
    /// of them.
    private static let stoppers = CharacterSet(charactersIn: "«»„“”‹›\"'<>")
    /// Sentence punctuation the detector leaves attached to the tail.
    /// `)` is deliberately absent: the detector balances parentheses itself,
    /// so a trailing one belongs to the link.
    private static let tailPunctuation = CharacterSet(charactersIn: ".,;:!?…")

    static func linkified(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        // NSDataDetector is not cheap and the feed re-evaluates its rows.
        // Scan only when a link marker is present, the same gate the chat
        // bubbles use.
        guard text.contains("://") || text.contains("www.") else { return attr }
        for span in spans(in: text) {
            guard let lo = AttributedString.Index(span.range.lowerBound, within: attr),
                  let hi = AttributedString.Index(span.range.upperBound, within: attr) else { continue }
            attr[lo..<hi].link = span.url
            attr[lo..<hi].foregroundColor = Theme.Color.accent
            attr[lo..<hi].underlineStyle = .single
        }
        return attr
    }

    private struct Span { let range: Range<String.Index>; let url: URL }

    private static func spans(in text: String) -> [Span] {
        guard let detector else { return [] }
        let ns = text as NSString
        var out: [Span] = []
        detector.enumerateMatches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            let matched = ns.substring(with: match.range)
            let kept = narrowed(matched)
            guard !kept.isEmpty else { return }
            if kept.utf16.count == matched.utf16.count {
                guard let url = match.url else { return }
                out.append(Span(range: matchRange, url: url))
                return
            }
            // Re-detect inside the shortened text rather than re-parsing it by
            // hand: that is what percent-encodes a Cyrillic path for us.
            let keptRange = NSRange(location: match.range.location, length: kept.utf16.count)
            guard let range = Range(keptRange, in: text), let url = firstURL(in: kept) else { return }
            out.append(Span(range: range, url: url))
        }
        return out
    }

    /// The part of [matched] that was actually meant as a link.
    private static func narrowed(_ matched: String) -> String {
        var scalars = matched.unicodeScalars
        if let stop = scalars.firstIndex(where: { stoppers.contains($0) }) {
            scalars = String.UnicodeScalarView(scalars[..<stop])
        }
        while let last = scalars.last, tailPunctuation.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    private static func firstURL(in s: String) -> URL? {
        guard let detector, !s.isEmpty else { return nil }
        let ns = s as NSString
        return detector
            .firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length))?
            .url
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
    let island: NewsIsland
    /// Explicit width from the parent feed.
    let cardWidth: CGFloat
    /// Tapped attachment index in `post.attachments`.
    let onTapImage: (Int) -> Void

    private var slotWidth: CGFloat { max(0, cardWidth - 28) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // The island's own face, not the app's logo: on a self-hosted
                // island the post is the operator's, and the reader should
                // see whose. The lettered tile covers an island with no logo.
                IslandAvatarView(
                    name: island.name,
                    host: island.host,
                    logoVersion: island.logoVersion,
                    size: 28
                )
                VStack(alignment: .leading, spacing: 1) {
                    authorLine
                    Text(Self.dateFormatter.string(from: post.publishedAt))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
            }
            Text(NewsBodyText.linkified(post.body))
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

    /// The island leads, in the weight the author line always had; the label
    /// the post was published under follows dimmed, and only when it adds a
    /// name of its own. One `Text`, so a long pair wraps the way a sentence
    /// does instead of truncating the half that carried the information.
    private var authorLine: Text {
        let name = Text(island.title)
            .font(.callout.weight(.semibold))
            .foregroundColor(Theme.Color.textPrimary)
        guard let author = island.customAuthor(post.authorLabel) else { return name }
        return name
            + Text(verbatim: " · \(author)")
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
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
        // ⚠ Not `AsyncImage(url:)` / `AVPlayer(url:)` on the island URL. Both
        // load through `URLSession.shared` or AVFoundation's own stack, which
        // no delegate reaches, so on a fingerprint island every news image and
        // video failed closed with no banner. The bytes come down through the
        // island session into a scratch file, the way chat media does, and
        // the views take the file (design §6).
        switch att.kind {
        case "video":
            // Color.clear overlay — clear has no intrinsic size, so the
            // overlay child is bound to the parent slot and can't
            // advertise its native dimensions upward.
            Color.clear
                .overlay {
                    NewsMediaFile(mediaID: att.mediaID, kind: att.kind) { state in
                        if case .video(let file) = state {
                            VideoPlayer(player: AVPlayer(url: file))
                        } else {
                            Rectangle().fill(Theme.Color.divider)
                        }
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        default:
            Color.clear
                .overlay {
                    NewsMediaFile(mediaID: att.mediaID, kind: att.kind) { state in
                        // Fit, not fill: the slot is a fixed landscape window
                        // (deliberately, so async media cannot grow LazyVStack
                        // rows on a second layout pass) and fill center-cropped
                        // a portrait screenshot down to a horizontal strip
                        // (founder, the news crop complaint). Fit letterboxes
                        // instead, exactly like the video branch above, so the
                        // whole frame is visible and the two media kinds stop
                        // disagreeing; the gallery still shows it full-screen.
                        if case .image(let image) = state {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Rectangle().fill(Theme.Color.divider)
                        }
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
        // The same scratch file the feed already fetched (see
        // `attachmentView`): one download per attachment, through the island
        // session, never `AsyncImage`'s own.
        NewsMediaFile(mediaID: att.mediaID, kind: att.kind) { state in
            switch state {
            case .image(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            case .failed:
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

/// One news attachment fetched to a scratch file and handed to the view as a
/// decoded image or a playable file URL.
///
/// Through `APIClient.downloadBlob(_:to:)`, which is `IslandHTTP.download`
/// with the island's masquerade header: the same road chat media takes
/// (`MediaService.fetchBlob(to:)`), so the trust delegate sees the handshake
/// and a closed island gets its header. `AsyncImage(url:)` and
/// `AVPlayer(url:)` see neither.
private struct NewsMediaFile<Content: View>: View {
    let mediaID: String
    let kind: String
    @ViewBuilder let content: (NewsMedia.State) -> Content
    @State private var state: NewsMedia.State = .loading

    var body: some View {
        content(state)
            .task(id: mediaID) {
                state = await NewsMedia.load(mediaID: mediaID, kind: kind)
            }
    }
}

@MainActor
private enum NewsMedia {
    enum State {
        case loading
        case failed
        case image(UIImage)
        case video(URL)
    }

    /// What is already decoded, and what is on its way, so the feed's carousel
    /// and the full-screen gallery share one download per attachment instead
    /// of racing each other for the same scratch path.
    private static var loaded: [String: State] = [:]
    private static var inFlight: [String: Task<State, Never>] = [:]

    static func load(mediaID: String, kind: String) async -> State {
        if let done = loaded[mediaID] { return done }
        if let task = inFlight[mediaID] { return await task.value }
        let task = Task<State, Never> { await fetch(mediaID: mediaID, kind: kind) }
        inFlight[mediaID] = task
        let result = await task.value
        inFlight[mediaID] = nil
        if case .failed = result {} else { loaded[mediaID] = result }
        return result
    }

    private static func fetch(mediaID: String, kind: String) async -> State {
        // The id is the island's word, so it becomes a file name only after
        // everything that is not a name character is dropped.
        let safe = mediaID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return .failed }
        let isVideo = kind == "video"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rcq-news-\(safe).\(isVideo ? "mp4" : "img")")
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try await APIClient.shared.downloadBlob("/news/media/\(mediaID)", to: file)
            } catch {
                return .failed
            }
        }
        if isVideo { return .video(file) }
        let path = file.path
        let image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: path) }.value
        return image.map { .image($0) } ?? .failed
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
