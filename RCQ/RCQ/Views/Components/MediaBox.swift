import SwiftUI
import ImageIO

/// The box a photo or video bubble occupies, decided from the media's own
/// proportions instead of a fixed rectangle.
///
/// ⚠⚠ EVERY photo and EVERY video used to be a hard `maxWidth x maxWidth*0.75`
/// with `.scaledToFill()`: a landscape frame lost its sides, a portrait one was
/// cut in half. Android carried the same defect in a harsher form (a square)
/// and a tester filed it as "the video is simply not shown full width, the way
/// ordinary players do" (#932). The math here mirrors `mediaBubbleBox` in the
/// Android `ChatScreen.kt` so the two clients crop identically.
///
/// ⚠⚠ JITTER, and the reason for the ratio cache. Nothing on the wire carries a
/// picture's width and height: a photo learns its shape only once the encrypted
/// bytes have come down AND decoded, several frames after the row was laid out.
/// Sizing the box off that alone would resize a settled row every time it
/// scrolled back into view. So a ratio is written down the first time it is
/// learned and read back synchronously afterwards: the box is decided BEFORE
/// the picture on every appearance except the very first. A VIDEO never reflows
/// at all, its poster travels inside the message, and neither does a photo we
/// sent ourselves, whose size the send path hands over at compose time.
enum MediaBox {
    /// Width cap. The old bubble width, so nothing else on the row moves.
    static let maxWidth: CGFloat = 240
    /// A tall portrait shot stops here instead of pushing the rest of the
    /// thread off the screen.
    static let maxHeight: CGFloat = 300
    /// A panorama or a very long screenshot stops here and IS cropped again, on
    /// purpose: past this it is a sliver you cannot see anything in.
    static let minSide: CGFloat = 120
    /// Shape of a photo whose bytes have not arrived: square, the box this
    /// bubble reserved before it could measure anything.
    static let photoFallbackRatio: CGFloat = 1
    /// Shape of a clip with no poster frame. An empty box with a play disc in
    /// it reads as a player, and a player is 16:9.
    static let videoFallbackRatio: CGFloat = 16.0 / 9.0

    /// - Parameter ratio: width / height of the media.
    static func size(ratio: CGFloat?, maxWidth: CGFloat = MediaBox.maxWidth) -> CGSize {
        let r = ratio.flatMap { $0.isFinite && $0 > 0 ? min(max($0, 0.05), 20) : nil } ?? photoFallbackRatio
        var w = maxWidth
        var h = w / r
        if h > maxHeight {
            h = maxHeight
            w = min(maxWidth, h * r)
        }
        return CGSize(width: max(minSide, w), height: max(minSide, h))
    }

    /// Box for this message, from whatever we already know of its shape.
    static func size(for message: Message, maxWidth: CGFloat = MediaBox.maxWidth) -> CGSize {
        let fallback = message.kind == .video ? videoFallbackRatio : photoFallbackRatio
        return size(ratio: ratio(for: message) ?? fallback, maxWidth: maxWidth)
    }

    /// Ratio of this message's media, or nil while it is still unknown.
    static func ratio(for message: Message) -> CGFloat? {
        if let cached = cached(message.mediaID) ?? cached(message.id.uuidString) { return cached }
        // A video's poster is in the envelope: read its header (no pixel
        // decode) so the bubble is the right shape on its very first frame.
        guard let b64 = message.thumbnailB64,
              let data = Data(base64Encoded: b64),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0
        else { return nil }
        let r = CGFloat(w / h)
        remember(message.mediaID ?? message.id.uuidString, ratio: r)
        return r
    }

    /// Write down what a decoded picture turned out to be. Called by the
    /// bubbles once the bytes land, and by the send paths, which hold the
    /// picked image before the upload has an id.
    static func remember(_ key: String?, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        remember(key, ratio: size.width / size.height)
    }

    static func remember(_ id: UUID, size: CGSize) {
        remember(id.uuidString, size: size)
    }

    // MARK: - Ratios learned in this launch
    //
    // In memory only, and bounded. Not persisted: a map of media ids on disk in
    // the clear would put back metadata the store keeps encrypted, and it buys
    // nothing a re-decode does not.

    private static let maxEntries = 512
    private static var ratios: [String: CGFloat] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()

    private static func remember(_ key: String?, ratio: CGFloat) {
        guard let key, !key.isEmpty, ratio.isFinite, ratio > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if ratios[key] == nil { order.append(key) }
        ratios[key] = ratio
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            ratios.removeValue(forKey: oldest)
        }
    }

    private static func cached(_ key: String?) -> CGFloat? {
        guard let key, !key.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return ratios[key]
    }
}
