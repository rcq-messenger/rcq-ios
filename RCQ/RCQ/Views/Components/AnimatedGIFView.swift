import ImageIO
import SwiftUI
import UIKit

/// Animated GIF rendered from arbitrary `Data` (e.g. a decrypted blob
/// fetched via `MediaService`). Sister to `GIFImage`, which only
/// handles bundle assets — split out to keep the bundle path's
/// name→URL lookup logic separate from the data-driven path.
///
/// Same `TimelineView(.animation)` frame picker as `GIFImage` so the
/// animation survives:
///   - List cell recycling and lazy stacks
///   - Sheet / fullScreenCover dismiss
///   - App background → foreground (TimelineView resumes ticks on its
///     own when the view re-enters the screen)
struct AnimatedGIFView: View {
    let data: Data
    var contentMode: ContentMode = .fit

    var body: some View {
        if let bundle = Self.cachedFrames(for: data), !bundle.frames.isEmpty {
            TimelineView(.animation) { ctx in
                let elapsed = ctx.date.timeIntervalSince1970
                let phase = elapsed.truncatingRemainder(dividingBy: bundle.duration)
                let progress = phase / bundle.duration
                let raw = Int(progress * Double(bundle.frames.count))
                let idx = max(0, min(bundle.frames.count - 1, raw))
                Image(uiImage: bundle.frames[idx])
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        } else if let still = UIImage(data: data) {
            // Single-frame fallback — non-animated payload or decoder
            // refusal. Render whatever the data decodes to so we never
            // ship an empty bubble.
            Image(uiImage: still)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Color.clear
        }
    }

    /// SHA-style identity key isn't worth the cost on every render;
    /// the data's `hashValue` is good enough since GIF blobs in this
    /// app come straight from `MediaService.loadImageWithData` which
    /// already caches by `mediaID:key`. Two different blobs colliding
    /// to the same hash just causes one decode miss.
    final class FrameBundle {
        let frames: [UIImage]
        let duration: TimeInterval
        init(frames: [UIImage], duration: TimeInterval) {
            self.frames = frames
            self.duration = duration > 0 ? duration : Double(frames.count) * 0.1
        }
    }

    private static let cache = NSCache<NSNumber, FrameBundle>()

    static func cachedFrames(for data: Data) -> FrameBundle? {
        let key = NSNumber(value: data.hashValue)
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var frames: [UIImage] = []
        var total: TimeInterval = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            total += Self.frameDuration(source: source, index: i)
        }
        let bundle = FrameBundle(frames: frames, duration: total)
        cache.setObject(bundle, forKey: key)
        return bundle
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
            let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        else { return 0.1 }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval,
           unclamped > 0 {
            return unclamped
        }
        return (gif[kCGImagePropertyGIFDelayTime as String] as? TimeInterval) ?? 0.1
    }

    /// Quick magic-byte check. Both GIF87a and GIF89a start with the
    /// ASCII bytes "GIF8". Anything else (JPEG, PNG, WebP, MP4) won't
    /// match, so receivers can use this to decide whether to route a
    /// blob through `AnimatedGIFView` or the static `Image(uiImage:)`.
    static func isGIF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38
    }
}
