import SwiftUI

/// A person's picture, with their status kept ON it.
///
/// The rule the whole feature rests on: a picture does NOT replace presence.
/// This app is built around the status flower, so when someone has a picture
/// the flower moves to a badge on the lower-left corner and stays there, the
/// way the site draws it in the Hall of Fame. With no picture nothing changes
/// at all — the plain `StatusIcon` is drawn exactly as before, so every screen
/// keeps its look for the people who never set one.
///
/// The encrypted blob is loaded through `MediaService` like a group avatar, and
/// a miss / failed decrypt / slow load all fall back to the flower rather than
/// to a broken image. Cross-island peers keep the flower too: presence does not
/// cross islands and neither does the blob.
struct PersonAvatarView: View {
    // Observed, not read statically: without this the toggle would only
    // take effect on the next fresh appearance of the screen.
    @ObservedObject private var theme = ThemeManager.shared
    let mediaID: String?
    let keyBase64: String?
    let status: UserStatus
    var host: String? = nil
    var size: CGFloat = 28
    var crossIsland: Bool = false
    /// No confirmed link to the server. Only ever set for your OWN picture,
    /// where the badge is the one place the header has left to say it: a
    /// picture covers the corner the connection dot used to sit in, and two
    /// marks stacked there read as neither. While this is true the badge shows
    /// the connection instead of the chosen status — a status nobody can see
    /// is not the thing worth reporting.
    var linkDown: Bool = false
    /// Set where the badge itself is actionable (the header, where tapping the
    /// flower opens the status picker). Without it the badge is decoration.
    var onStatusTap: (() -> Void)? = nil

    @State private var image: UIImage?
    @State private var gifData: Data?

    init(
        mediaID: String?,
        keyBase64: String?,
        status: UserStatus,
        host: String? = nil,
        size: CGFloat = 28,
        crossIsland: Bool = false,
        linkDown: Bool = false,
        onStatusTap: (() -> Void)? = nil
    ) {
        self.mediaID = mediaID
        self.keyBase64 = keyBase64
        self.status = status
        self.host = host
        self.size = size
        self.crossIsland = crossIsland
        self.linkDown = linkDown
        self.onStatusTap = onStatusTap
        // Seed from the decrypted cache so a hot avatar is already there on the
        // first frame instead of flashing the flower — same trick as
        // GroupAvatarView, and it matters more here because contact rows
        // recycle constantly while scrolling.
        var seedImage: UIImage?
        var seedGIF: Data?
        if !crossIsland, let id = mediaID, !id.isEmpty, let key = keyBase64, !key.isEmpty {
            seedImage = MediaService.shared.cachedImage(mediaID: id, keyBase64: key)
            if let data = MediaService.shared.cachedData(mediaID: id, keyBase64: key),
               AnimatedGIFView.isGIF(data) {
                seedGIF = data
            }
        }
        self._image = State(initialValue: seedImage)
        self._gifData = State(initialValue: seedGIF)
    }

    /// Big enough to read on a 24pt row avatar, small enough not to swallow a
    /// large profile one.
    private var badge: CGFloat { min(26, max(12, size * 0.36)) }

    var body: some View {
        Group {
            if image == nil && gifData == nil {
                if let onStatusTap {
                    Button(action: onStatusTap) {
                        StatusIcon(status: status, size: size, crossIsland: crossIsland)
                    }
                    .buttonStyle(.plain)
                } else {
                    StatusIcon(status: status, size: size, crossIsland: crossIsland)
                }
            } else {
                ZStack(alignment: .bottomLeading) {
                    picture
                    // Sits ON the picture's edge and sticks out past it: keeping
                    // it fully inside the square puts it in the corner the round
                    // image never reaches, where it reads as clipped.
                    badgeView.offset(x: -badge / 4, y: badge / 4)
                }
                .frame(width: size, height: size)
            }
        }
        .task(id: cacheKey) { await load() }
    }

    @ViewBuilder private var picture: some View {
        if let gifData {
            AnimatedGIFView(data: gifData, contentMode: .fill, animates: theme.animateAvatars)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }

    @ViewBuilder private var badgeView: some View {
        let content = ZStack {
            Circle().fill(Theme.Color.bgPrimary)
            if linkDown {
                // The same orange the header's connection dot uses, so the two
                // ways of saying "no link" cannot disagree with each other.
                Circle()
                    .fill(Color.orange)
                    .frame(width: badge * 0.62, height: badge * 0.62)
            } else {
                StatusIcon(status: status, size: badge * 0.82, crossIsland: crossIsland)
            }
        }
        .frame(width: badge, height: badge)
        if let onStatusTap {
            Button(action: onStatusTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var cacheKey: String {
        guard !crossIsland, let mediaID, let keyBase64 else { return "none" }
        return "\(mediaID)|\(keyBase64)|\(host ?? "")"
    }

    private func load() async {
        guard !crossIsland, let mediaID, !mediaID.isEmpty,
              let keyBase64, !keyBase64.isEmpty else {
            image = nil
            gifData = nil
            return
        }
        if let pair = await MediaService.shared.loadImageWithData(
            mediaID: mediaID, keyBase64: keyBase64, host: host
        ) {
            image = pair.0
            gifData = AnimatedGIFView.isGIF(pair.1) ? pair.1 : nil
        }
    }
}
