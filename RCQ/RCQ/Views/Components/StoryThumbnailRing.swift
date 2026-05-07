import SwiftUI

/// Circular thumbnail with a segmented progress-style ring around it
/// for stories. One segment per story in the group; segments are
/// accent-coloured if unviewed, dimmed grey if already watched.
///
/// Renders three visual layers stacked centrally:
/// 1. The segmented ring (Canvas drawing N arc strokes with gaps).
/// 2. The thumbnail image (resolved from the first story's media,
///    falling back to a generic icon while loading).
/// 3. (When all viewed) a thinner grey ring instead of the segmented
///    one — communicates "you've seen everything but they still have
///    active stories."
///
/// Tappable as a whole — caller wires a tap action to open the
/// `StoryViewerView` for this group.
struct StoryThumbnailRing: View {
    let group: StoryGroup
    var size: CGFloat = 36
    var ringWidth: CGFloat = 2.4
    var segmentGap: CGFloat = 4  // gap between segments in degrees

    var body: some View {
        ZStack {
            ringLayer
                .frame(width: size, height: size)
            thumbnailLayer
                .frame(width: size - ringWidth * 2 - 2, height: size - ringWidth * 2 - 2)
                .clipShape(Circle())
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var ringLayer: some View {
        if group.hasUnviewed {
            // Segmented ring: each story = one arc segment.
            // Unviewed segments accent-coloured, viewed ones dimmed.
            Canvas { ctx, sz in
                let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let radius = (sz.width - ringWidth) / 2
                let count = group.stories.count
                guard count > 0 else { return }
                let totalDeg: Double = 360
                let perGap = count > 1 ? Double(segmentGap) : 0
                let perSegment = (totalDeg - perGap * Double(count)) / Double(count)
                // Start at top (12 o'clock) and walk clockwise.
                var cursor = -90.0 + perGap / 2
                for story in group.stories {
                    let start = Angle(degrees: cursor)
                    let end = Angle(degrees: cursor + perSegment)
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: start,
                        endAngle: end,
                        clockwise: false
                    )
                    let color: Color = story.viewed
                        ? Theme.Color.divider
                        : Theme.Color.accent
                    ctx.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                    )
                    cursor += perSegment + perGap
                }
            }
        } else {
            // All watched: thin grey full-circle ring.
            Circle()
                .stroke(Theme.Color.divider, lineWidth: ringWidth)
        }
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let firstStory = group.stories.first {
            StoryThumbnailImage(
                mediaID: firstStory.mediaID,
                keyB64: firstStory.mediaKeyB64
            )
        } else {
            Circle().fill(Theme.Color.bgSecondary)
        }
    }
}

/// Loads + caches the first frame of a story's media. For photos,
/// it's the photo itself (downsized via UIImage). For video stories
/// we'd ideally pull a thumbnail; for v1 we use a generic film glyph
/// over the bgSecondary fill — still recognizable, no extra work.
private struct StoryThumbnailImage: View {
    let mediaID: String
    let keyB64: String

    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Theme.Color.bgSecondary
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                Image(systemName: "photo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            } else {
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(Theme.Color.accent)
            }
        }
        .task(id: mediaID) {
            await load()
        }
    }

    private func load() async {
        let img = await MediaService.shared.loadImage(mediaID: mediaID, keyBase64: keyB64)
        await MainActor.run {
            if let img {
                self.image = img
            } else {
                self.loadFailed = true
            }
        }
    }
}
