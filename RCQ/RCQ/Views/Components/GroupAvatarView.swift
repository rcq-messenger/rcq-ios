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

    private var resolvedGlyph: CGFloat { glyphSize ?? size * 0.42 }

    var body: some View {
        ZStack {
            Circle().fill(Theme.Color.accent)
            if let image {
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
            return
        }
        image = await MediaService.shared.loadImage(mediaID: id, keyBase64: key)
    }
}
