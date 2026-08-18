import SwiftUI

/// Square thumbnail on the reply-preview pill when the replied-to message is media.
/// Photos async-load via MediaService; video/premium decode inline `thumbnailB64`; voice shows a waveform glyph.
struct ReplyMediaThumbnail: View {
    let message: Message
    var size: CGFloat = 36

    @State private var loadedImage: UIImage?
    @State private var thumb: UIImage?

    var body: some View {
        ZStack {
            content
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if isLockedPremium {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
        .task(id: message.mediaID ?? "") { await loadIfPhoto() }
        .task(id: message.thumbnailB64 ?? "") { decodeThumb() }
    }

    @ViewBuilder
    private var content: some View {
        if let img = loadedImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .blur(radius: isLockedPremium ? 10 : 0)
        } else if let thumb {
            Image(uiImage: thumb)
                .resizable()
                .scaledToFill()
                .blur(radius: isLockedPremium ? 10 : 0)
        } else if message.kind == .voice {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Color.accent.opacity(0.18))
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Color.bgSecondary)
                Image(systemName: placeholderIcon)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    private var isVideo: Bool {
        message.kind == .video
    }

    private var isLockedPremium: Bool {
        false
    }

    private var placeholderIcon: String {
        switch message.kind {
        case .photo: return "photo"
        case .video: return "video"
        case .voice: return "waveform"
        default:     return "doc"
        }
    }

    private func decodeThumb() {
        guard let b64 = message.thumbnailB64,
              let data = Data(base64Encoded: b64),
              let image = UIImage(data: data) else {
            thumb = nil
            return
        }
        thumb = image
    }

    private func loadIfPhoto() async {
        guard message.kind == .photo else { return }
        guard let raw = message.mediaID else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let img = await MediaService.shared.loadImage(mediaID: parts[0], keyBase64: parts[1])
        await MainActor.run { self.loadedImage = img }
    }
}
