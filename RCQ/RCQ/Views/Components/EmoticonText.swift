import SwiftUI

/// Renders text with inline animated GIF emoticons. Falls back to the
/// literal shortcode when the asset isn't bundled.
struct EmoticonText: View {
    let text: String
    var font: Font = Theme.Font.bubble
    var color: Color = Theme.Color.textPrimary
    var emoticonSize: CGFloat = 22
    var lineSpacing: CGFloat = 2

    var body: some View {
        // VStack of per-line FlowLayouts so user newlines drive real breaks.
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, lineRuns in
                if lineRuns.isEmpty {
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
            Text(Self.linkify(s)).font(font).foregroundColor(color)
        case .emoticon(let asset, let code):
            if let img = GIFImage.cachedImage(for: asset) {
                // Preserve native aspect ratio; square frames squash wide glyphs.
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

/// Flow layout: lays children left-to-right, wraps when a child won't fit. iOS 16+.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        // Propose available width to each child so long Text returns wrapped multi-line size.
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
        // Two-pass: row heights, then vertical-centred placement.
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
