import SwiftUI

/// Renders text with inline ICQ emoticons. When the GIF asset is present, the
/// emoticon is rendered via the animated GIFImage so the bubble actually feels alive.
/// When it's missing (dev builds without the pack), we render the literal shortcode.
///
/// Layout: a flow layout that wraps text + animated images on the same line. SwiftUI's
/// Text-concat trick (`Text + Text(Image(…))`) only handles static images, so for the
/// animated path we need to break out of Text-only rendering and use a wrapping layout.
struct EmoticonText: View {
    let text: String
    var font: Font = Theme.Font.bubble
    var color: Color = Theme.Color.textPrimary
    /// Inline emoticon side. Tied to `~22pt` so a smiley sharing a
    /// row with body-size text stays the same visual height — bigger
    /// values (28pt was the previous default) inflated row heights
    /// and made bubbles look gappy on lines that contained one.
    var emoticonSize: CGFloat = 22
    /// Vertical gap between logical lines of the message. SwiftUI
    /// Text already adds its own ascent/descent leading; this is an
    /// extra nudge between paragraphs only.
    var lineSpacing: CGFloat = 2

    var body: some View {
        // VStack of per-logical-line FlowLayouts. Splitting on `\n`
        // up-front means the user's explicit newlines drive real
        // line breaks here, and each line's per-word + emoticon
        // wrapping happens inside its own FlowLayout. The previous
        // single-FlowLayout version emitted `Text("\n")` slots for
        // each newline, which contributed a full font-height empty
        // row to the layout and made multi-line bubbles read with
        // huge gaps between lines.
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, lineRuns in
                if lineRuns.isEmpty {
                    // Preserve a blank line the user typed — render
                    // as a single zero-width Text so VStack adds the
                    // expected vertical step between paragraphs.
                    Text(" ").font(font).foregroundColor(color)
                } else {
                    FlowLayout(spacing: 0, lineSpacing: 2) {
                        ForEach(Array(lineRuns.enumerated()), id: \.offset) { _, run in
                            renderRun(run)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func renderRun(_ run: Run) -> some View {
        switch run {
        case .text(let s):
            // SwiftUI auto-handles `.link` AttributedString attribute
            // on Text — tap opens the URL via the environment's
            // OpenURL action. Detection is best-effort via
            // NSDataDetector; non-URL text falls through unchanged.
            Text(Self.linkify(s)).font(font).foregroundColor(color)
        case .emoticon(let asset, let code):
            if let img = GIFImage.cachedImage(for: asset) {
                // Preserve native aspect ratio; pin height to the
                // requested size and let width scale proportionally.
                // Square frames squashed wide kolobok/forum-classic
                // glyphs into deformed boxes.
                let aspect: CGFloat = {
                    guard img.size.width > 0, img.size.height > 0 else { return 1 }
                    return img.size.width / img.size.height
                }()
                GIFImage(name: asset)
                    .frame(width: emoticonSize * aspect, height: emoticonSize)
                    .accessibilityLabel(code)
            } else {
                Text(code).font(font).foregroundColor(color)
            }
        }
    }

    /// Run NSDataDetector across `s` and decorate every URL match
    /// with a `.link` + accent color + underline. Cached detector
    /// avoids the per-render allocator hit.
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func linkify(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        guard let detector = linkDetector, !s.isEmpty else { return attr }
        let nsRange = NSRange(s.startIndex..<s.endIndex, in: s)
        detector.enumerateMatches(in: s, options: [], range: nsRange) { match, _, _ in
            guard let match, let url = match.url,
                  let r = Range(match.range, in: s) else { return }
            // Convert the String range to AttributedString offsets.
            let lower = s.distance(from: s.startIndex, to: r.lowerBound)
            let upper = s.distance(from: s.startIndex, to: r.upperBound)
            let lo = attr.index(attr.startIndex, offsetByCharacters: lower)
            let hi = attr.index(attr.startIndex, offsetByCharacters: upper)
            attr[lo..<hi].link = url
            attr[lo..<hi].foregroundColor = .blue
            attr[lo..<hi].underlineStyle = .single
        }
        return attr
    }

    /// Tokenize the message into [logical line] → [run]. Logical
    /// lines come from `\n` splits in the source text; runs inside a
    /// line are word-text fragments + inline emoticons. Per-word
    /// splitting (rather than one Text per line) lets a wide line
    /// wrap inside its FlowLayout while still leaving the next
    /// emoticon glued to the right of the prior word.
    private var lines: [[Run]] {
        var out: [[Run]] = []
        for line in text.components(separatedBy: "\n") {
            var lineRuns: [Run] = []
            for token in Emoticons.tokenize(line) {
                switch token {
                case .text(let s):
                    var current = ""
                    for ch in s {
                        if ch.isWhitespace {
                            if !current.isEmpty { lineRuns.append(.text(current)); current = "" }
                            lineRuns.append(.text(String(ch)))
                        } else {
                            current.append(ch)
                        }
                    }
                    if !current.isEmpty { lineRuns.append(.text(current)) }
                case .emoticon(let asset, let code):
                    lineRuns.append(.emoticon(asset: asset, code: code))
                }
            }
            out.append(lineRuns)
        }
        return out
    }

    private enum Run: Hashable {
        case text(String)
        case emoticon(asset: String, code: String)
    }
}

/// Single-pass flow layout: lays children left-to-right, wraps when the next child
/// won't fit. Uses each child's natural size. iOS 16+.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        // Crucial: propose the available width to each child
        // (instead of `.unspecified`), so a long `Text` returns
        // its *wrapped* multi-line size rather than a single
        // continuous line wider than the bubble. The previous
        // version asked text "what's your natural size?" which
        // blew through the right edge of the chat for any
        // long-paragraph send.
        let childProposal = ProposedViewSize(
            width: maxWidth.isFinite ? maxWidth : nil,
            height: nil
        )
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(childProposal)
            if x + s.width > maxWidth, x > 0 {
                widestRow = max(widestRow, x - spacing)
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        widestRow = max(widestRow, x - spacing)
        let total = CGSize(width: min(widestRow, maxWidth.isFinite ? maxWidth : widestRow), height: y + rowHeight)
        return total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Same `bounds.width` propagation as the sizing pass —
        // each child gets to wrap inside the bubble's actual
        // width. Two-pass layout: row heights first, then
        // vertical-centred placement so a 22pt smiley sharing a
        // row with shorter text doesn't get clipped along the
        // top.
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        struct Slot { let x: CGFloat; let row: Int; let size: CGSize }
        var slots: [Slot] = []
        var rowHeights: [CGFloat] = []
        var x: CGFloat = 0
        var rowIndex = 0
        var rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(childProposal)
            if x + s.width > bounds.width, x > 0 {
                rowHeights.append(rowHeight)
                rowIndex += 1
                x = 0
                rowHeight = 0
            }
            slots.append(Slot(x: x, row: rowIndex, size: s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        rowHeights.append(rowHeight)

        var rowYs: [CGFloat] = []
        var y: CGFloat = bounds.minY
        for h in rowHeights {
            rowYs.append(y)
            y += h + lineSpacing
        }

        for (i, slot) in slots.enumerated() {
            let h = rowHeights[slot.row]
            let yPos = rowYs[slot.row] + (h - slot.size.height) / 2
            subviews[i].place(
                at: CGPoint(x: bounds.minX + slot.x, y: yPos),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: slot.size.width, height: slot.size.height)
            )
        }
    }
}
