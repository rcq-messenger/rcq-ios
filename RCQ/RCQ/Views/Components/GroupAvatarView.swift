import SwiftUI

/// Round group-avatar. Loads the encrypted blob via MediaService if a
/// custom avatar is set, otherwise falls back to the generic `person.3`
/// glyph. Reused by ContactListView's GroupRow + GroupInfoView header.
struct GroupAvatarView: View {
    let mediaID: String?
    let keyBase64: String?
    let size: CGFloat
    var glyphSize: CGFloat? = nil

    @State private var image: UIImage?
    /// Raw bytes only held when the asset is a GIF (for AnimatedGIFView).
    @State private var gifData: Data?

    private var resolvedGlyph: CGFloat { glyphSize ?? size * 0.42 }

    init(mediaID: String?, keyBase64: String?, size: CGFloat, glyphSize: CGFloat? = nil) {
        self.mediaID = mediaID
        self.keyBase64 = keyBase64
        self.size = size
        self.glyphSize = glyphSize
        // Seed @State from the decrypted cache so the first render frame
        // already has the avatar when it's hot — otherwise the entrance
        // animation flashes the fallback glyph while the async .task
        // path catches up. Most callers (group rows, header) have already
        // loaded this exact avatar before MessageBannerHost renders.
        let seedImage: UIImage?
        let seedGIF: Data?
        if let id = mediaID, !id.isEmpty,
           let key = keyBase64, !key.isEmpty {
            seedImage = MediaService.shared.cachedImage(mediaID: id, keyBase64: key)
            let cachedData = MediaService.shared.cachedData(mediaID: id, keyBase64: key)
            seedGIF = (cachedData.map { AnimatedGIFView.isGIF($0) } ?? false) ? cachedData : nil
        } else {
            seedImage = nil
            seedGIF = nil
        }
        self._image = State(initialValue: seedImage)
        self._gifData = State(initialValue: seedGIF)
    }

    var body: some View {
        ZStack {
            Circle().fill(Theme.Color.accent)
            if let gifData {
                AnimatedGIFView(data: gifData, contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.3.fill")
                    .font(.system(size: resolvedGlyph))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .task(id: cacheKey) { await load() }
    }

    private var cacheKey: String {
        "\(mediaID ?? "")|\(keyBase64 ?? "")"
    }

    private func load() async {
        guard
            let id = mediaID, !id.isEmpty,
            let key = keyBase64, !key.isEmpty
        else {
            image = nil
            gifData = nil
            return
        }
        if let pair = await MediaService.shared.loadImageWithData(mediaID: id, keyBase64: key) {
            image = pair.0
            gifData = AnimatedGIFView.isGIF(pair.1) ? pair.1 : nil
        }
    }
}
