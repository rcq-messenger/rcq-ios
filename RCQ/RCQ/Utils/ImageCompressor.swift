import UIKit

enum ImageCompressor {
    /// Resize so the longest side is `maxSide`, then JPEG-encode at the given
    /// quality. Returns nil for empty or invalid images.
    static func compress(_ image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? (maxSide / longest) : 1.0
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target, format: {
            let f = UIGraphicsImageRendererFormat.default()
            f.scale = 1
            f.opaque = true
            return f
        }())
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
