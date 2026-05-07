import SwiftUI
import UIKit

/// Multi-line input that renders KOLOBOK emoticon shortcodes
/// inline as static images, instead of leaving them as raw `:)`
/// text the way SwiftUI's `TextField` does. Wraps a UIKit
/// `UITextView` and uses `NSTextAttachment` to splice the
/// emoticon's first frame into the typed text.
///
/// Trade-off: attachments are static (UITextView can't animate
/// embedded `UIImage` frames cheaply, and an inline animated
/// emoticon in the composer wouldn't match anything else iOS
/// shows anyway). The bubbles render the *animated* GIF on
/// receive — input shows what's about to be sent.
struct EmoticonTextField: UIViewRepresentable {
    @Binding var text: String
    /// Caller-owned binding that the field writes its measured
    /// height into. The wrapping `HStack` reads this through
    /// `.frame(height:)` to size the composer — single-line at
    /// rest, growing in step with wrapping content, capped at
    /// `maxHeight`. Driving height via a binding side-steps the
    /// `intrinsicContentSize` approach which on iOS 26 was
    /// re-layout-looping the HStack to its full `maxHeight`.
    @Binding var dynamicHeight: CGFloat
    var placeholder: String = ""
    var minHeight: CGFloat = 32
    var maxHeight: CGFloat = 120
    var fontSize: CGFloat = 16
    var emoticonSize: CGFloat = 22
    /// Called when the text changes — used by the chat view to
    /// drive its typing-indicator broadcast.
    var onTextChange: ((String) -> Void)?

    func makeUIView(context: Context) -> EmoticonUITextView {
        let tv = EmoticonUITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = UIFont.systemFont(ofSize: fontSize)
        tv.textColor = UIColor(Theme.Color.textPrimary)
        tv.tintColor = UIColor(Theme.Color.accent)
        // Top/bottom inset chosen so a single line of `fontSize`-pt
        // text sits visually centered in the `minHeight`-tall pill.
        // For the 16pt font + 36pt minHeight pair: 16pt font has a
        // line height of ~19pt; (36-19)/2 ≈ 8 → 8pt top/bottom +
        // 19pt text + 1pt rounding fudge = 36pt content. UILabel
        // placeholder constraint reuses `textContainerInset.top` so
        // the placeholder ends up at the same y. Without this the
        // text sat ~3pt above center while the placeholder looked
        // fine, the alignment glitch the user reported.
        let topInset: CGFloat = max(4, (minHeight - fontSize * 1.2) / 2)
        tv.textContainerInset = UIEdgeInsets(top: topInset, left: 6, bottom: topInset, right: 6)
        tv.textContainer.lineFragmentPadding = 0
        // Wrap, not horizontal-grow.
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Start non-scrolling so the view auto-grows with content
        // (matching SwiftUI's `TextField(axis: .vertical)`
        // affordance). The coordinator flips this on once the
        // content height crosses `maxHeight`.
        tv.isScrollEnabled = false
        tv.placeholder = placeholder
        tv.placeholderColor = UIColor(Theme.Color.textSecondary)
        tv.allowedSendCallback = nil
        context.coordinator.textView = tv
        // Initial render so the binding's existing text shows up.
        let initial = context.coordinator.attributed(from: text)
        tv.attributedText = initial
        tv.refreshPlaceholderVisibility()
        return tv
    }

    func updateUIView(_ uiView: EmoticonUITextView, context: Context) {
        // Avoid feedback loop: only re-render when the binding
        // diverges from what's already in the view.
        let current = context.coordinator.plainText(from: uiView.attributedText)
        if current != text {
            let attr = context.coordinator.attributed(from: text)
            uiView.attributedText = attr
            // After programmatic set, anchor cursor at the end —
            // most external mutations (e.g. clearing on send)
            // drop us to empty / append at end anyway.
            uiView.selectedRange = NSRange(location: attr.length, length: 0)
        }
        uiView.refreshPlaceholderVisibility()
        // Re-measure on every update — covers the empty-text path
        // (clear-on-send) where `textViewDidChange` won't fire.
        DispatchQueue.main.async {
            context.coordinator.measureHeight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EmoticonTextField
        weak var textView: EmoticonUITextView?

        init(parent: EmoticonTextField) {
            self.parent = parent
        }

        // MARK: - text<->attributed conversion

        /// Convert plain text (with shortcode literals like `:)`)
        /// into an attributed string with `EmoticonAttachment`s
        /// for each emoticon token. Surviving plain text uses the
        /// composer's font + foreground colour.
        func attributed(from text: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: UIColor(Theme.Color.textPrimary),
            ]
            for token in Emoticons.tokenize(text) {
                switch token {
                case .text(let s):
                    result.append(NSAttributedString(string: s, attributes: baseAttrs))
                case .emoticon(let asset, let code):
                    if GIFImage.cachedFrames(for: asset) != nil
                        || GIFImage.cachedImage(for: asset) != nil {
                        let att = EmoticonAttachment(asset: asset, code: code)
                        // Static `image` stays as a graceful
                        // fallback for any TextKit path that
                        // doesn't honour the view provider —
                        // shows the first frame so layout sizing
                        // is correct from the very first paint.
                        let img = GIFImage.cachedImage(for: asset)
                        att.image = img
                        // Smiley sizing — the line-grows-by-pixels bug.
                        // NSTextAttachment.bounds.origin.y is the
                        // attachment's offset from the baseline (positive
                        // = up). The surrounding text's "no-growth"
                        // window is [descender, ascender] from baseline
                        // (≈ [-4, +15] for 16pt SF). Anything outside
                        // this range makes TextKit grow the line.
                        // Earlier we used height = lineHeight (19) with
                        // y = 0 — that put the attachment at [0, 19],
                        // overshooting ascender by 4pt and growing the
                        // line. Pinning at [descender, ascender]
                        // exactly fits the line's natural bounds with
                        // ZERO growth.
                        let font = UIFont.systemFont(ofSize: parent.fontSize)
                        let descent = floor(font.descender)   // negative
                        let ascent  = floor(font.ascender)    // positive
                        let glyphHeight = ascent - descent     // = lineHeight (descent neg)
                        let aspect: CGFloat = {
                            guard let img, img.size.width > 0, img.size.height > 0 else { return 1 }
                            return img.size.width / img.size.height
                        }()
                        att.bounds = CGRect(
                            x: 0, y: descent,
                            width: glyphHeight * aspect,
                            height: glyphHeight,
                        )
                        result.append(NSAttributedString(attachment: att))
                    } else {
                        result.append(NSAttributedString(string: code, attributes: baseAttrs))
                    }
                }
            }
            return result
        }

        /// Walk the attributed string and rebuild the plain text:
        /// each attachment writes its `code` back, every other run
        /// writes its substring. Inverse of `attributed(from:)`.
        func plainText(from attr: NSAttributedString) -> String {
            var out = ""
            attr.enumerateAttributes(
                in: NSRange(location: 0, length: attr.length),
                options: []
            ) { attrs, range, _ in
                if let attachment = attrs[.attachment] as? EmoticonAttachment {
                    out.append(attachment.code)
                } else {
                    out.append((attr.string as NSString).substring(with: range))
                }
            }
            return out
        }

        /// Map an attributed-string offset to a plain-text offset.
        /// Used to preserve cursor position across re-render.
        func plainOffset(in attr: NSAttributedString, at attributedOffset: Int) -> Int {
            var plain = 0
            var i = 0
            while i < attributedOffset && i < attr.length {
                let c = attr.attribute(.attachment, at: i, effectiveRange: nil) as? EmoticonAttachment
                if let c {
                    plain += c.code.count
                } else {
                    plain += 1
                }
                i += 1
            }
            return plain
        }

        /// Inverse of `plainOffset(in:at:)`. Map plain-text offset
        /// back into an attributed-string offset, used after a
        /// re-render to restore the cursor.
        func attributedOffset(in attr: NSAttributedString, forPlainOffset plain: Int) -> Int {
            var consumed = 0
            var i = 0
            while i < attr.length {
                if consumed >= plain { return i }
                let c = attr.attribute(.attachment, at: i, effectiveRange: nil) as? EmoticonAttachment
                if let c {
                    consumed += c.code.count
                } else {
                    consumed += 1
                }
                i += 1
            }
            return attr.length
        }

        // MARK: - UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            guard let tv = textView as? EmoticonUITextView else { return }
            let plain = plainText(from: tv.attributedText)
            // Push back to binding first so external observers
            // see the new value before we possibly re-render.
            if parent.text != plain {
                parent.text = plain
                parent.onTextChange?(plain)
            }

            // Re-tokenize: if the plain text now contains a
            // shortcode that wasn't yet rendered as an attachment,
            // rebuild and restore cursor.
            let rebuilt = attributed(from: plain)
            if !attributedEqual(tv.attributedText, rebuilt) {
                let cursor = tv.selectedRange.location
                let plainCursor = plainOffset(in: tv.attributedText, at: cursor)
                tv.attributedText = rebuilt
                let restoredCursor = attributedOffset(in: rebuilt, forPlainOffset: plainCursor)
                tv.selectedRange = NSRange(location: restoredCursor, length: 0)
            }
            tv.refreshPlaceholderVisibility()
            // Toggle scroll once content exceeds the cap so we
            // grow up to it and then start scrolling — matches
            // the look of SwiftUI's `TextField(axis: .vertical)`
            // with a `lineLimit`.
            let needsScroll = tv.contentSize.height > parent.maxHeight
            if tv.isScrollEnabled != needsScroll {
                tv.isScrollEnabled = needsScroll
            }
            // Push the new height up to the SwiftUI parent so the
            // composer frame keeps step with wrapping text.
            measureHeight()
        }

        /// Compute the text view's natural height for its current
        /// width and write the clamped result back to the parent's
        /// `dynamicHeight` binding. Idempotent — only mutates the
        /// binding when the value actually changes, so SwiftUI
        /// doesn't end up in a re-layout cycle.
        func measureHeight() {
            guard let tv = textView else { return }
            let width = tv.bounds.width > 0 ? tv.bounds.width : UIScreen.main.bounds.width
            let target = CGSize(width: width, height: .greatestFiniteMagnitude)
            let fitted = tv.sizeThatFits(target).height
            let clamped = max(parent.minHeight, min(fitted, parent.maxHeight))
            if abs(parent.dynamicHeight - clamped) > 0.5 {
                parent.dynamicHeight = clamped
            }
        }

        private func attributedEqual(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
            if a.length != b.length { return false }
            return a.isEqual(to: b)
        }
    }
}

/// `NSTextAttachment` subclass that:
///  - remembers the plain-text shortcode it stands in for so the
///    coordinator can rebuild the binding string on every edit,
///  - hands back a custom `NSTextAttachmentViewProvider` that
///    swaps a *live* animated `UIImageView` into the layout —
///    that's how we get GIFs to actually animate inside the
///    composer instead of rendering as a frozen first frame.
final class EmoticonAttachment: NSTextAttachment {
    let code: String
    let asset: String
    init(asset: String, code: String) {
        self.asset = asset
        self.code = code
        super.init(data: nil, ofType: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewProvider(
        for parentView: UIView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = AnimatedEmoticonViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

/// Provider that loads an `AnimatedEmoticonImageView` at the
/// attachment's bounds. Animation kicks via the same
/// `didMoveToWindow` / `layoutSubviews` self-restart trick the
/// regular `GIFImage` view uses.
private final class AnimatedEmoticonViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let imgView = AnimatedEmoticonImageView()
        imgView.contentMode = .scaleAspectFit
        if let attachment = textAttachment as? EmoticonAttachment {
            if let bundle = GIFImage.cachedFrames(for: attachment.asset) {
                imgView.animationImages = bundle.frames
                imgView.animationDuration = bundle.duration
                imgView.animationRepeatCount = 0
                imgView.image = bundle.frames.first
                imgView.startAnimating()
            } else {
                imgView.image = UIImage(named: attachment.asset)
                    ?? UIImage(named: "rxn_\(attachment.asset)")
            }
        }
        view = imgView
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        // Trust the bounds the host computed against its
        // surrounding font's ascent/descent (see
        // `Coordinator.attributed(from:)`). Fallback rect uses
        // the same descender/ascender geometry as 16pt SF so it
        // doesn't grow the line either.
        textAttachment?.bounds ?? CGRect(x: 0, y: -4, width: 19, height: 19)
    }
}

private final class AnimatedEmoticonImageView: UIImageView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if animationImages != nil, !isAnimating { startAnimating() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if animationImages != nil, !isAnimating { startAnimating() }
    }
}

/// `UITextView` subclass with a `UILabel` placeholder overlay
/// plus a small affordance to send the message via the return
/// key when configured to. Height is driven from SwiftUI via the
/// `dynamicHeight` binding the wrapping `EmoticonTextField` owns
/// — see `Coordinator.measureHeight()`.
final class EmoticonUITextView: UITextView {
    var placeholder: String = "" {
        didSet { placeholderLabel.text = placeholder; refreshPlaceholderVisibility() }
    }
    var placeholderColor: UIColor = .secondaryLabel {
        didSet { placeholderLabel.textColor = placeholderColor }
    }
    var allowedSendCallback: (() -> Void)?

    private let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupPlaceholder()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlaceholder()
    }

    private func setupPlaceholder() {
        placeholderLabel.numberOfLines = 1
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = font
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: textContainerInset.left + textContainer.lineFragmentPadding
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: topAnchor,
                constant: textContainerInset.top
            ),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    func refreshPlaceholderVisibility() {
        placeholderLabel.font = font
        placeholderLabel.isHidden = !attributedText.string.isEmpty
    }
}
