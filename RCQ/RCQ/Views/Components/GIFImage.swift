import ImageIO
import SwiftUI
import UIKit

/// Plays an animated GIF from the bundle.
///
/// Pure SwiftUI renderer driven by `TimelineView(.animation)` —
/// frame index is derived from wall-clock time modulo the gif's
/// total duration. No `UIImageView.animationImages` lifecycle to
/// track, so the renderer survives:
///   - Form / List cell recycling on scroll
///   - Sheet / fullScreenCover dismiss without manual self-heal
///   - App background → foreground (TimelineView resumes ticks
///     automatically when the view re-enters the screen)
///
/// Earlier `UIViewRepresentable` version chased every iOS
/// lifecycle hole (`didMoveToWindow`, `layoutSubviews`, scene
/// observers) and still left the pet glyph frozen on its first
/// frame after Settings → About → back. TimelineView side-steps
/// the entire problem.
struct GIFImage: View {
    let name: String
    var contentMode: ContentMode = .fit

    /// Decoded frame stash. NSCache so memory-pressure can evict it.
    final class FrameBundle {
        let frames: [UIImage]
        let duration: TimeInterval
        init(frames: [UIImage], duration: TimeInterval) {
            self.frames = frames
            self.duration = duration > 0 ? duration : Double(frames.count) * 0.1
        }
    }

    var body: some View {
        if let bundle = Self.cachedFrames(for: name), !bundle.frames.isEmpty {
            let duration = max(0.05, bundle.duration / Self.playbackSpeed(for: name))
            TimelineView(.animation) { ctx in
                let elapsed = ctx.date.timeIntervalSince1970
                let phase = elapsed.truncatingRemainder(dividingBy: duration)
                let progress = phase / duration
                let raw = Int(progress * Double(bundle.frames.count))
                let idx = max(0, min(bundle.frames.count - 1, raw))
                Image(uiImage: bundle.frames[idx])
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: contentMode)
            }
        } else if let fallback = UIImage(named: name) ?? UIImage(named: "rxn_\(name)") {
            // Loose-resource path — `EmoticonText` and friends ship
            // some assets as plain PNGs in the imageset namespace.
            // Render statically.
            Image(uiImage: fallback)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: contentMode)
        } else {
            Color.clear
        }
    }

    /// Pet sprites (`pet1.gif`…`pet10.gif`) read sluggish at their
    /// authored frame timing — 1.3× lands them in "alive idle" without
    /// crossing into jittery. Everything else plays at 1×.
    private static func playbackSpeed(for name: String) -> Double {
        if name.hasPrefix("pet"),
           !name.dropFirst(3).isEmpty,
           name.dropFirst(3).allSatisfy({ $0.isNumber }) {
            return 1.3
        }
        return 1.0
    }

    // MARK: - frame cache

    private static let cache = NSCache<NSString, FrameBundle>()

    static func cachedFrames(for name: String) -> FrameBundle? {
        let key = name as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = locateGIF(named: name) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [UIImage] = []
        var total: TimeInterval = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            total += frameDuration(source: source, index: i)
        }
        let bundle = FrameBundle(frames: frames, duration: total)
        cache.setObject(bundle, forKey: key)
        return bundle
    }

    /// Legacy hook — callers like `EmoticonText` use this as a "do we
    /// have an animatable asset" probe, returning either the first
    /// frame or a static fallback. Kept stable so the rest of the
    /// app doesn't need to change shape after the renderer rewrite.
    static func cachedImage(for name: String) -> UIImage? {
        if let bundle = cachedFrames(for: name) {
            return bundle.frames.first
        }
        return UIImage(named: name) ?? UIImage(named: "rxn_\(name)")
    }

    private static func locateGIF(named name: String) -> URL? {
        // xcodegen flattens by default, so the file is usually at
        // the bundle root. We also check a `.gif`-suffixed name and
        // a couple of likely subdirectories in case the project
        // ever goes back to folder-refs.
        if let url = Bundle.main.url(forResource: name, withExtension: "gif") { return url }
        if let url = Bundle.main.url(forResource: "\(name).gif", withExtension: nil) { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Emoticons") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Resources/Emoticons") { return url }
        return nil
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
}
