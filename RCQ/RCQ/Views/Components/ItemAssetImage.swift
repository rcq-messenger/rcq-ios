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
                AnimatedGIFImage(url: url)
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

    var body: some View {
        if let frames = AnimatedGIFCache.shared.frames(for: url),
           !frames.images.isEmpty {
            TimelineView(.animation) { ctx in
                let elapsed = ctx.date.timeIntervalSince1970
                let phase = elapsed.truncatingRemainder(dividingBy: frames.duration)
                let progress = phase / frames.duration
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
