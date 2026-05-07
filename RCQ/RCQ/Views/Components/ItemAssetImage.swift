import SwiftUI
import UIKit
import ImageIO

/// Renders a kind asset out of the bundled `Items/` folder reference.
/// Supports PNG (static) and GIF (animated) — the cosmetic packs use
/// gifs, the relics are PNGs. For unknown / missing assets falls back
/// to a placeholder cube glyph so a misnamed asset_ref doesn't crash
/// the inventory grid.
struct ItemAssetImage: View {
    /// Kept for forward-compat with a future folder-reference layout
    /// but unused at runtime — xcodegen flattens `RCQ/Resources/Items`
    /// into the .app root regardless of `type: folder`, so the bundle
    /// has no `Items/` subdirectory and `subdirectory:` lookups would
    /// always miss. We rely on every relic / cosmetic / wallet asset
    /// having a globally-unique basename, which they do.
    let bundleSubdir: String
    let filename: String       // basename without extension, e.g. "Item1"
    let ext: String            // "png" / "gif"

    var body: some View {
        if let url = Bundle.main.url(forResource: filename, withExtension: ext) {
            if ext.lowercased() == "gif" {
                AnimatedGIFImage(url: url)
            } else if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.none)  // pixel-perfect for the 32×32 PNG relics
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

/// Pure-SwiftUI animated-GIF renderer.
///
/// Earlier iterations wrapped a `UIImageView` and drove its
/// `animationImages` property — fast initial render, but Apple's
/// animation lifecycle is fragile: iOS pauses the animation when
/// the view is covered by a sheet, drops `animationImages` on
/// memory pressure, and doesn't auto-resume on re-show. We tried
/// patching with `updateUIView` self-heal, `layoutSubviews`,
/// `didMoveToWindow`, and scene-active observers — each fix broke
/// a different scenario (Form scroll flashing, sheet-dismiss
/// freeze, etc.).
///
/// Now: drive frames manually via `TimelineView(.animation)`. The
/// frame index is computed off the wall-clock modulo the gif's
/// total duration. SwiftUI's TimelineView automatically pauses when
/// off-screen and resumes when re-shown — no UIView lifecycle to
/// manage. Decoded frames live in `AnimatedGIFCache` so re-render
/// after a sheet dismiss is just a dictionary lookup.
struct AnimatedGIFImage: View {
    let url: URL

    var body: some View {
        if let frames = AnimatedGIFCache.shared.frames(for: url),
           !frames.images.isEmpty {
            // `.animation` schedule ticks ~60fps; we sample frame
            // index from elapsed time so render is deterministic.
            // Capping interval to ~30fps would be marginally more
            // efficient but most cosmetic gifs are <12 frames long
            // and the difference is invisible.
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
            // Decode failed (corrupt gif, unreadable file). Static
            // placeholder so the cell still has SOMETHING to draw.
            Image(systemName: "cube")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(Theme.Color.divider)
        }
    }
}

/// In-memory cache of decoded GIF frames keyed by URL. The decode
/// happens on the first `frames(for:)` call and is shared across
/// every `AnimatedGIFImage` referencing the same URL — so the coin
/// asset rendering in five different places only decodes once.
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
