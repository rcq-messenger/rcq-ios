import SwiftUI

/// Bottom sheet listing every photo / video in a thread as a grid.
/// Tapping a tile opens `AlbumViewer`.
struct AllMediaSheet: View {
    let messages: [Message]
    @Environment(\.dismiss) private var dismiss

    private var mediaItems: [Message] {
        messages
            .filter {
                !$0.deletedForEveryone
                    && [.photo, .video].contains($0.kind)
            }
            .reversed()
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if mediaItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.Color.textSecondary)
                        Text("chat.all_media.empty".localized)
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(Array(mediaItems.enumerated()), id: \.element.id) { idx, m in
                                MediaThumbCell(message: m)
                                    .onTapGesture {
                                        AlbumViewerPresenter.present(
                                            items: mediaItems, initialIndex: idx
                                        )
                                    }
                            }
                        }
                        .padding(2)
                    }
                }
            }
            .navigationTitle("chat.all_media.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct MediaThumbCell: View {
    let message: Message
    @State private var image: UIImage?

    private var isVideo: Bool {
        message.kind == .video
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().tint(Theme.Color.textSecondary)
            }
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .task(id: message.id) { await load() }
    }

    private func load() async {
        if isVideo {
            if let b64 = message.thumbnailB64,
               let data = Data(base64Encoded: b64),
               let img = UIImage(data: data) {
                await MainActor.run { self.image = img }
            }
            return
        }
        guard let combined = message.mediaID else { return }
        let parts = combined.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return }
        if let img = await MediaService.shared.loadImage(
            mediaID: String(parts[0]), keyBase64: String(parts[1])
        ) {
            await MainActor.run { self.image = img }
        }
    }
}
