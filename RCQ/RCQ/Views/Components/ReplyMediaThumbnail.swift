import SwiftUI

/// Small square thumbnail rendered on the leading edge of the
/// compose-bar's reply preview pill when the replied-to message is
/// media (photo / video / voice / premium media). Without this, a
/// reply to a photo just showed "📷 Photo" — clean enough for a
/// voice reply but loses the visual context of "this exact photo
/// I'm replying to".
///
/// Lifecycle
/// ---------
/// • Photos: async-load via `MediaService.loadImage`. The chat row
///   that fired the reply almost always already loaded the photo,
///   so the cache hit is instant.
/// • Videos & premium media: decode the inline `thumbnailB64`
///   (always shipped in the envelope for these types) — no fetch.
/// • Premium media (locked): renders the thumbnail with a heavy
///   blur + lock glyph overlay so it reads as paywalled at a glance.
/// • Voice: no media to show — render a mic glyph on a tinted plate.
struct ReplyMediaThumbnail: View {
    let message: Message
    var size: CGFloat = 36

    @State private var loadedImage: UIImage?

    var body: some View {
        ZStack {
            content
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // Lock glyph for paywalled, not-yet-unlocked media so it
            // reads at a glance without re-rendering the unlock pill.
            if isLockedPremium {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            // Tiny play-button overlay on video thumbs.
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
        .task(id: message.mediaID ?? "") { await loadIfPhoto() }
    }

    @ViewBuilder
    private var content: some View {
        if let img = loadedImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .blur(radius: isLockedPremium ? 10 : 0)
        } else if let thumb = decodedThumbnail {
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
            // Generic media placeholder — bgSecondary tile + media
            // icon. Sits while the photo's async load is in flight,
            // OR permanently for any media kind without a fetchable
            // body (e.g. premium-locked sender on receiving device
            // before unlock — handled by the lock-glyph branch above).
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Color.bgSecondary)
                Image(systemName: placeholderIcon)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
    }

    /// Inline-shipped thumbnail (videos + premium media). Decoded
    /// once per render of this view; cheap on a 32×32 surface even
    /// for a multi-K JPEG.
    private var decodedThumbnail: UIImage? {
        guard let b64 = message.thumbnailB64,
              let data = Data(base64Encoded: b64),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    private var isVideo: Bool {
        message.kind == .video || message.kind == .premiumVideo
    }

    private var isLockedPremium: Bool {
        (message.kind == .premiumPhoto || message.kind == .premiumVideo)
            && !message.premiumUnlocked
    }

    private var placeholderIcon: String {
        switch message.kind {
        case .photo, .premiumPhoto: return "photo"
        case .video, .premiumVideo: return "video"
        case .voice:                return "waveform"
        default:                    return "doc"
        }
    }

    /// Async-load real photos via MediaService. Cache hit is the
    /// common case (the original chat row already populated it).
    /// Skip for kinds that don't need a fetch — videos and premium
    /// media have everything inline via `thumbnailB64`.
    private func loadIfPhoto() async {
        guard message.kind == .photo else { return }
        guard let raw = message.mediaID else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let img = await MediaService.shared.loadImage(mediaID: parts[0], keyBase64: parts[1])
        await MainActor.run { self.loadedImage = img }
    }
}
