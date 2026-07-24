import SwiftUI

/// Telegram-style album cluster — N media items shipped in a single
/// pendingMedia batch, rendered as one grouped bubble. Uses a 2-column
/// grid up to 4 tiles; for 3-tile albums the first row is one wide
/// tile and the second row is two halves so the layout never leaves a
/// stranded singleton. Caption is the trailing message's text — same
/// "anchor" rule the sender uses when composing the album.
struct MediaAlbumBubble: View {
    let items: [Message]
    var maxWidth: CGFloat = 248
    let onTapTile: (Int) -> Void
    /// Fires from the same view target as the tap, so SwiftUI can
    /// disambiguate by duration without nested-gesture flakiness on
    /// iOS 26. Earlier this lived on a wrapper above the bubble and
    /// stole release events from the per-tile tap.
    var onLongPress: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topTrailing) {
            grid
            countPill
                .padding(8)
        }
        .frame(width: maxWidth)
    }

    private var countPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("\(items.count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    @ViewBuilder
    private var grid: some View {
        let spacing: CGFloat = 3
        let count = min(items.count, 4)
        // 2-up rows for 2 / 4. 3 = wide top tile + 2 half-width below.
        let isThree = count == 3
        let cellHeight: CGFloat = isThree ? maxWidth * 0.55 : maxWidth * 0.5

        if count == 2 {
            HStack(spacing: spacing) {
                tile(at: 0, w: (maxWidth - spacing) / 2, h: cellHeight)
                tile(at: 1, w: (maxWidth - spacing) / 2, h: cellHeight)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if count == 3 {
            VStack(spacing: spacing) {
                tile(at: 0, w: maxWidth, h: cellHeight)
                HStack(spacing: spacing) {
                    tile(at: 1, w: (maxWidth - spacing) / 2, h: cellHeight * 0.7)
                    tile(at: 2, w: (maxWidth - spacing) / 2, h: cellHeight * 0.7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            // 4 (or 5+ truncated to 4 with overflow badge on the last)
            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    tile(at: 0, w: (maxWidth - spacing) / 2, h: cellHeight)
                    tile(at: 1, w: (maxWidth - spacing) / 2, h: cellHeight)
                }
                HStack(spacing: spacing) {
                    tile(at: 2, w: (maxWidth - spacing) / 2, h: cellHeight)
                    ZStack {
                        tile(at: 3, w: (maxWidth - spacing) / 2, h: cellHeight)
                        if items.count > 4 {
                            ZStack {
                                Color.black.opacity(0.5)
                                Text("+\(items.count - 4)")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: (maxWidth - spacing) / 2, height: cellHeight)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func tile(at idx: Int, w: CGFloat, h: CGFloat) -> some View {
        AlbumTile(
            message: items[idx],
            width: w,
            height: h,
            onTap: { onTapTile(idx) },
            onLongPress: onLongPress
        )
    }

    /// Static thumbnail-only video tile. Tapping the album already
    /// opens the viewer where the video will play, so the in-grid
    /// preview just needs the still frame + a play badge.
    @ViewBuilder
    private func videoTile(message: Message, w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            if let b64 = message.thumbnailB64,
               let data = Data(base64Encoded: b64),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                Theme.Color.bgSecondary
                    .frame(width: w, height: h)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .frame(width: w, height: h)
    }
}

/// One album tile. Tap goes through a plain SwiftUI Button (the
/// most reliably-firing tap primitive in SwiftUI), long-press rides
/// alongside via `simultaneousGesture` so it can't steal the tap.
private struct AlbumTile: View {
    let message: Message
    let width: CGFloat
    let height: CGFloat
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// Spoiler tiles blur until the first tap; the Button action does
    /// the reveal (the cover is visual-only here) so the second tap
    /// opens the album viewer as usual.
    @State private var spoilerRevealed = false

    private var spoilerCovered: Bool {
        message.isSpoiler && !spoilerRevealed
    }

    var body: some View {
        Button(action: {
            if spoilerCovered {
                withAnimation(.easeOut(duration: 0.25)) { spoilerRevealed = true }
            } else {
                onTap()
            }
        }) {
            ZStack {
                switch message.kind {
                case .photo:
                    PhotoBubble(
                        message: message,
                        forcedSize: CGSize(width: width, height: height),
                        disableTap: true
                    )
                case .video:
                    videoTile
                default:
                    Theme.Color.bgSecondary.frame(width: width, height: height)
                }
            }
            .frame(width: width, height: height)
            .modifier(SpoilerCover(active: spoilerCovered, tapToReveal: false) {})
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onLongPress()
                }
        )
    }

    @ViewBuilder
    private var videoTile: some View {
        ZStack {
            if let b64 = message.thumbnailB64,
               let data = Data(base64Encoded: b64),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Theme.Color.bgSecondary.frame(width: width, height: height)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .frame(width: width, height: height)
    }
}
