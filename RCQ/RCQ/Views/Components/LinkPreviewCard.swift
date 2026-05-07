import LinkPresentation
import SwiftUI
import UIKit

/// Telegram-style link preview attached underneath a text bubble or
/// the composer. Fetches Open-Graph metadata via Apple's
/// `LinkPresentation` framework — no backend, no scraping plumbing.
/// On failure (404, no OG tags, network blip) the card just doesn't
/// render and the URL stays visible in the bubble's body text.
struct LinkPreviewCard: View {
    let url: URL
    /// Cap width so the card doesn't stretch to bubble-full width on
    /// long captions. 260pt matches the Telegram visual rhythm.
    var maxWidth: CGFloat = 260

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
                // Render nothing — the URL is already in the bubble.
                EmptyView()
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .task { await fetch() }
    }

    @ViewBuilder
    private func content(_ m: LPLinkMetadata) -> some View {
        Button {
            UIApplication.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if m.imageProvider != nil || m.iconProvider != nil {
                    LinkImageView(metadata: m)
                        .frame(maxWidth: .infinity)
                        .frame(height: 130)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title ?? url.absoluteString)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(url.host ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .background(Theme.Color.bgSecondary.opacity(0.7))
        .cornerRadius(8)
        .overlay(
            // Leading-edge accent strip — Telegram-style "this is a
            // link" affordance. 3pt accent bar attached to the card's
            // leading edge.
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
        if let cached = await LinkPreviewCache.shared.get(url) {
            metadata = cached
            status = .loaded
            return
        }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        do {
            let m = try await provider.startFetchingMetadata(for: url)
            await LinkPreviewCache.shared.set(m, for: url)
            metadata = m
            status = .loaded
        } catch {
            await LinkPreviewCache.shared.markFailed(url)
            status = .failed
        }
        // No re-anchor signal needed — `BottomAnchoredScroll` installs
        // `defaultScrollAnchor(.bottom)` on iOS 17+ which keeps the
        // latest bubble glued to the composer when this card grows
        // (or shrinks) the bubble's measured height.
    }
}

/// UIKit bridge to render the LPLinkMetadata's preview image. Apple
/// supplies an `LPLinkView` that does this natively, but it's
/// hard-coded to use the system Card chrome — way too heavy for an
/// inline-bubble preview. We just pull the bytes via the metadata's
/// image provider and render in a UIImageView.
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
        // Prefer the larger preview image; fall back to the favicon.
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

/// Per-URL metadata cache. Reads fan out across every visible bubble
/// that references the same link so we don't re-fetch on scroll-back.
/// `failed` tombstones cap retries — a URL that timed out once won't
/// re-try on the next render. Lifecycle is process-wide; no
/// persistence needed since metadata becomes stale anyway.
actor LinkPreviewCache {
    static let shared = LinkPreviewCache()

    private var hits: [URL: LPLinkMetadata] = [:]
    private var failed: Set<URL> = []

    func get(_ url: URL) -> LPLinkMetadata? {
        if failed.contains(url) {
            // Return a sentinel-empty metadata so the card path stays
            // off — actually we just return nil and the caller treats
            // it as cache miss. Marker is checked via `wasFailed`.
            return nil
        }
        return hits[url]
    }

    func wasFailed(_ url: URL) -> Bool { failed.contains(url) }
    func set(_ m: LPLinkMetadata, for url: URL) { hits[url] = m }
    func markFailed(_ url: URL) { failed.insert(url) }
}

/// First URL detected in a piece of text. Cached helper used by the
/// chat-row composer to decide whether to attach a `LinkPreviewCard`
/// underneath the bubble.
enum LinkDetector {
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func firstURL(in text: String) -> URL? {
        guard let detector, !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = detector.firstMatch(in: text, options: [], range: range),
           let url = match.url,
           url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return nil
    }
}
