import LinkPresentation
import SwiftUI
import UIKit

/// Link preview underneath a text bubble. Uses `LinkPresentation` for
/// OG metadata; renders nothing on failure. Compact Telegram-style
/// layout — small square thumbnail on the leading edge, title + host
/// stacked on the trailing side — so the card hugs the bubble width
/// instead of swelling to a full-screen-wide banner.
struct LinkPreviewCard: View {
    let url: URL
    var maxWidth: CGFloat = 220

    @State private var metadata: LPLinkMetadata?
    @State private var status: Status = .loading

    private enum Status { case loading, loaded, failed }

    var body: some View {
        Group {
            switch status {
            case .loading:
                placeholder
            case .loaded:
                if let metadata { content(metadata) } else { EmptyView() }
            case .failed:
                EmptyView()
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .task { await fetch() }
    }

    @ViewBuilder
    private func content(_ m: LPLinkMetadata) -> some View {
        Button {
            InAppBrowser.open(url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if m.imageProvider != nil || m.iconProvider != nil {
                    LinkImageView(metadata: m)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title ?? url.absoluteString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(url.host ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Theme.Color.bgSecondary.opacity(0.7))
        .cornerRadius(8)
        .overlay(
            HStack(spacing: 0) {
                Rectangle().fill(Theme.Color.accent).frame(width: 3)
                Spacer()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.Color.accent)
            Text(url.host ?? url.absoluteString)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.Color.bgSecondary.opacity(0.5))
        .cornerRadius(8)
        .overlay(
            HStack(spacing: 0) {
                Rectangle().fill(Theme.Color.accent.opacity(0.4)).frame(width: 3)
                Spacer()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fetch() async {
        // All cache lookup, in-flight dedup, and concurrency throttling live in
        // LinkPreviewCache — see its note on why LPMetadataProvider must be
        // rate-limited (it spawns a WebKit process per fetch).
        if let m = await LinkPreviewCache.shared.metadata(for: url) {
            metadata = m
            status = .loaded
        } else {
            status = .failed
        }
    }
}

private struct LinkImageView: UIViewRepresentable {
    let metadata: LPLinkMetadata

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.backgroundColor = .secondarySystemBackground
        loadImage(into: v)
        return v
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image == nil { loadImage(into: uiView) }
    }

    private func loadImage(into view: UIImageView) {
        let provider = metadata.imageProvider ?? metadata.iconProvider
        provider?.loadObject(ofClass: UIImage.self) { obj, _ in
            DispatchQueue.main.async {
                if let img = obj as? UIImage {
                    view.image = img
                }
            }
        }
    }
}

/// Per-URL link-metadata cache + fetch coordinator, process-wide.
///
/// `LPMetadataProvider` spawns a WebKit `WebContent` + GPU process for EVERY
/// fetch. A chat screen full of distinct links would launch a swarm of them at
/// once — observed on-device as cumulative heat, `WebContent didBecomeUnresponsive`,
/// and main-thread contention that made even sending a message lag after a long
/// session. So this actor:
///  - serves a process-wide cache (`failed` tombstones cap retries),
///  - coalesces concurrent requests for the SAME url onto one fetch (`inFlight`),
///  - caps how many LP fetches — and thus WebContent processes — run at once,
///  - bounds the resident cache (LPLinkMetadata retains image data) so it can't
///    grow without limit over a long session.
actor LinkPreviewCache {
    static let shared = LinkPreviewCache()

    private var hits: [URL: LPLinkMetadata] = [:]
    private var order: [URL] = []                       // FIFO eviction order
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<LPLinkMetadata?, Never>] = [:]
    private static let maxCached = 60

    // Counting semaphore (actor-serialized): at most `maxConcurrent` LP fetches
    // alive at any moment, so the WebContent/GPU process count stays bounded.
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let maxConcurrent = 2

    func metadata(for url: URL) async -> LPLinkMetadata? {
        if failed.contains(url) { return nil }
        if let hit = hits[url] { return hit }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<LPLinkMetadata?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquire()
            let provider = LPMetadataProvider()
            provider.timeout = 8
            let result = try? await provider.startFetchingMetadata(for: url)
            await self.release()
            return result
        }
        inFlight[url] = task
        let m = await task.value
        inFlight[url] = nil
        if let m {
            store(m, for: url)
        } else {
            failed.insert(url)
        }
        return m
    }

    private func store(_ m: LPLinkMetadata, for url: URL) {
        if hits[url] == nil {
            order.append(url)
            if order.count > Self.maxCached {
                hits[order.removeFirst()] = nil
            }
        }
        hits[url] = m
    }

    // Hand-off counting semaphore. A releaser with a waiter passes its slot
    // straight on (active unchanged); only an idle release decrements.
    private func acquire() async {
        if active < Self.maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum LinkDetector {
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func firstURL(in text: String) -> URL? {
        guard let detector, !text.isEmpty else { return nil }
        // Cheap substring pre-gate: skip the full NSDataDetector scan for the
        // vast majority of bodies that contain no URL. Mirrors
        // EmoticonText.linkify's gate so inline link styling and preview cards
        // agree on what counts as a link. Called per text bubble per render.
        guard text.contains("://") || text.contains("www.") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = detector.firstMatch(in: text, options: [], range: range),
           let url = match.url,
           url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return nil
    }
}
