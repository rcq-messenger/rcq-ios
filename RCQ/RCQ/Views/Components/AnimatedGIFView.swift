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
    /// Off draws the first frame and stops the per-refresh redraw entirely.
    /// Callers that are avatars pass the person's setting; a picture inside a
    /// chat, which is looked at deliberately, keeps moving.
    var animates: Bool = true

    /// Frames, once they exist. Nil means "not decoded yet", which is not the
    /// same as "not a GIF": the still fallback below covers both, so a bubble
    /// is never empty while the decode runs.
    @State private var decoded: FrameBundle?

    var body: some View {
        content
            // ⚠⚠ The decode used to happen inside `body`, which means on the
            // main thread, for every GIF the moment it appeared. Walking every
            // frame of an animation through CGImageSourceCreateImageAtIndex is
            // what Xcode's thread performance checker reports as "Performing
            // I/O on the main thread can cause hangs", and a chat list of
            // animated avatars pays it once per avatar, in one frame.
            //
            // Only a MISS goes off the main thread. The cache lookup below
            // stays synchronous and stays in `body`, because that is what keeps
            // a cell scrolled back into view from flickering through the still.
            .task(id: data.hashValue) {
                if decoded != nil || Self.cached(for: data) != nil { return }
                let blob = data
                let bundle = await Task.detached(priority: .userInitiated) {
                    Self.decodeFrames(for: blob)
                }.value
                decoded = bundle
            }
    }

    @ViewBuilder
    private var content: some View {
        // `decoded` first, then the cache: the same view can be reused for
        // another blob (list cell recycling), and `task(id:)` reruns for it
        // while the old bundle is still in `decoded`.
        let bundle = Self.cached(for: data) ?? decoded
        if let bundle, !bundle.frames.isEmpty, !animates {
            Image(uiImage: bundle.frames[0])
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else if let bundle, !bundle.frames.isEmpty {
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
            // Single-frame fallback — non-animated payload, decoder refusal,
            // or the frames not being decoded yet. Render whatever the data
            // decodes to so we never ship an empty bubble.
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
    /// `@unchecked Sendable`: the frames are decoded once, off the main thread,
    /// and the bundle is immutable from the moment it exists. UIImage itself is
    /// safe to read from any thread; what is not safe is mutating one, and
    /// nothing here does.
    final class FrameBundle: @unchecked Sendable {
        let frames: [UIImage]
        let duration: TimeInterval
        init(frames: [UIImage], duration: TimeInterval) {
            self.frames = frames
            self.duration = duration > 0 ? duration : Double(frames.count) * 0.1
        }
    }

    /// ⚠ `nonisolated` for the same reason as the helpers below: `View`
    /// conformance would put this on the main actor, and the decode that
    /// reads it deliberately runs off it. `NSCache` is thread-safe by
    /// contract, which is what makes the opt-out honest rather than a
    /// silenced warning. `(unsafe)` because `NSCache` carries no `Sendable`
    /// conformance to prove it with; the guarantee is Foundation's, in prose.
    nonisolated(unsafe) private static let cache = NSCache<NSNumber, FrameBundle>()

    /// Cache lookup only, no decode. Cheap enough to call from `body`.
    ///
    /// ⚠ `nonisolated`, like the three helpers below it. Conforming to `View`
    /// puts the whole type on the main actor, statics included, so the decode
    /// this file exists to move OFF the main thread was being called back onto
    /// it from `Task.detached` - a warning under Swift 5 and an error the day
    /// the project moves to Swift 6. Nothing here touches the view: the input
    /// is bytes, the store is an `NSCache`, which is thread-safe by contract.
    nonisolated static func cached(for data: Data) -> FrameBundle? {
        cache.object(forKey: NSNumber(value: data.hashValue))
    }

    /// Decode every frame and cache the result. Never call this on the main
    /// thread: see the note on `body`.
    @discardableResult
    nonisolated static func decodeFrames(for data: Data) -> FrameBundle? {
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

    nonisolated private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
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
    nonisolated static func isGIF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38
    }
}
