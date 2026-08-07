import SwiftUI
import UIKit

/// The sender's picture beside their nick on a group message — and NOTHING at
/// all when they have not set one, so that line stays the plain nick it has
/// always been.
///
/// Deliberately not `PersonAvatarView`: that one falls back to the status
/// flower and keeps presence as a badge, which is right in a list of people and
/// wrong here. Presence on a bubble would be the sender's status NOW, sitting
/// next to something they said hours ago, and a coloured dot on every message
/// is noise where the list needs it to be signal.
struct SenderAvatarView: View {
    let mediaID: String?
    let keyBase64: String?
    var size: CGFloat = 15

    @State private var image: UIImage?

    init(mediaID: String?, keyBase64: String?, size: CGFloat = 15) {
        self.mediaID = mediaID
        self.keyBase64 = keyBase64
        self.size = size
        // Seeded from the decrypted cache so a hot picture is already there on
        // the first frame instead of popping in a moment later — bubbles
        // recycle constantly while scrolling.
        var seed: UIImage?
        if let id = mediaID, !id.isEmpty, let key = keyBase64, !key.isEmpty {
            seed = MediaService.shared.cachedImage(mediaID: id, keyBase64: key)
        }
        self._image = State(initialValue: seed)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private var cacheKey: String {
        guard let mediaID, let keyBase64 else { return "none" }
        return "\(mediaID)|\(keyBase64)"
    }

    private func load() async {
        guard let mediaID, !mediaID.isEmpty, let keyBase64, !keyBase64.isEmpty else {
            image = nil
            return
        }
        if image != nil { return }
        // A still frame even for an animated picture: an animation per message
        // would be its own kind of noise, and this is 15pt of identification.
        image = await MediaService.shared.loadImage(mediaID: mediaID, keyBase64: keyBase64)
    }
}
