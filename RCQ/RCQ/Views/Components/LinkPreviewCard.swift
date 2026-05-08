import LinkPresentation
import SwiftUI
import UIKit

/// Link preview underneath a text bubble. Uses `LinkPresentation` for OG metadata; renders nothing on failure.
struct LinkPreviewCard: View {
    let url: URL
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

/// Per-URL metadata cache, process-wide. `failed` tombstones cap retries.
actor LinkPreviewCache {
    static let shared = LinkPreviewCache()

    private var hits: [URL: LPLinkMetadata] = [:]
    private var failed: Set<URL> = []

    func get(_ url: URL) -> LPLinkMetadata? {
        if failed.contains(url) { return nil }
        return hits[url]
    }

    func wasFailed(_ url: URL) -> Bool { failed.contains(url) }
    func set(_ m: LPLinkMetadata, for url: URL) { hits[url] = m }
    func markFailed(_ url: URL) { failed.insert(url) }
}

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
