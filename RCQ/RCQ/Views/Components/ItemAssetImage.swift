import SwiftUI
import UIKit
import ImageIO

/// Renders an item asset (PNG static, GIF animated) from the bundle. Falls back to a cube glyph.
struct ItemAssetImage: View {
    // bundleSubdir unused: xcodegen flattens Resources/Items into the .app root.
    let bundleSubdir: String
    let filename: String
    let ext: String

    var body: some View {
        if let url = Bundle.main.url(forResource: filename, withExtension: ext) {
            if ext.lowercased() == "gif" {
                AnimatedGIFImage(url: url, speed: Self.speed(forFilename: filename))
            } else if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    /// Per-asset playback speed. Default 1× preserves the artist-set
    /// frame timing. Pets read sluggish at their authored timing —
    /// 1.3× lands them in "alive idle" without crossing into jittery.
    /// Filename pattern is `pet1.gif ... pet10.gif`.
    private static func speed(forFilename name: String) -> Double {
        if name.hasPrefix("pet"),
           name.dropFirst(3).allSatisfy({ $0.isNumber }),
           !name.dropFirst(3).isEmpty {
            return 1.3
        }
        return 1.0
    }

    private var placeholder: some View {
        Image(systemName: "cube")
            .font(.system(size: 18, weight: .light))
            .foregroundColor(Theme.Color.divider)
    }
}

/// SwiftUI animated-GIF renderer. Drives frame index off wall-clock via `TimelineView(.animation)`
/// — TimelineView pauses off-screen and resumes on re-show, no UIView lifecycle to manage.
struct AnimatedGIFImage: View {
    let url: URL
    /// 1× = native GIF timing. Higher values shorten the loop period;
    /// used to give pets a livelier idle (see `ItemAssetImage.speed`).
    var speed: Double = 1.0

    var body: some View {
        if let frames = AnimatedGIFCache.shared.frames(for: url),
           !frames.images.isEmpty {
            let duration = max(0.05, frames.duration / max(0.1, speed))
            TimelineView(.animation) { ctx in
                let elapsed = ctx.date.timeIntervalSince1970
                let phase = elapsed.truncatingRemainder(dividingBy: duration)
                let progress = phase / duration
                let raw = Int(progress * Double(frames.images.count))
                let idx = max(0, min(frames.images.count - 1, raw))
                Image(uiImage: frames.images[idx])
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }
        } else {
            Image(systemName: "cube")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(Theme.Color.divider)
        }
    }
}

private final class AnimatedGIFCache {
    static let shared = AnimatedGIFCache()

    struct Frames {
        let images: [UIImage]
        let duration: TimeInterval
    }

    private var cache: [URL: Frames] = [:]
    private let lock = NSLock()

    func frames(for url: URL) -> Frames? {
        lock.lock()
        if let hit = cache[url] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var images: [UIImage] = []
        var total: TimeInterval = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            images.append(UIImage(cgImage: cg))
            total += gifFrameDelay(src: src, index: i)
        }
        if total < 0.05 { total = TimeInterval(count) * 0.1 }
        let frames = Frames(images: images, duration: total)
        lock.lock()
        cache[url] = frames
        lock.unlock()
        return frames
    }

    private func gifFrameDelay(src: CGImageSource, index: Int) -> TimeInterval {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        if let unclamped = gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let clamped = gifProps?[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
            return clamped
        }
        return 0.1
    }
}
