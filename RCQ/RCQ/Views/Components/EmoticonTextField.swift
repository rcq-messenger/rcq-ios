import SwiftUI
import UIKit

/// Multi-line composer that renders KOLOBOK shortcodes inline via NSTextAttachment.
struct EmoticonTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    var placeholder: String = ""
    var minHeight: CGFloat = 32
    var maxHeight: CGFloat = 120
    var fontSize: CGFloat = 16
    var emoticonSize: CGFloat = 22
    var onTextChange: ((String) -> Void)?
    /// Optional image-paste handler. Wired by chat / Bug Bounty so a
    /// screenshot on the clipboard pastes straight into the message
    /// composer or attachment list — saves users a galley-trip just
    /// to attach what they already have on copy.
    var onImagePaste: ((UIImage) -> Void)?
    /// Two-way binding for the caret position (in plain-string units,
    /// not attributed-string units — emoticon attachments count as
    /// their full shortcode length on the way out). Optional so the
    /// existing call sites don't have to opt in. The chat composer
    /// wires this so the emoji panel can splice a shortcode at the
    /// cursor instead of appending to the end of input.
    var caretPlainLocation: Binding<Int>?

    func makeUIView(context: Context) -> EmoticonUITextView {
        let tv = EmoticonUITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = UIFont.systemFont(ofSize: fontSize)
        tv.textColor = UIColor(Theme.Color.textPrimary)
        tv.tintColor = UIColor(Theme.Color.accent)
        // Center one line of fontSize-pt text inside the minHeight pill.
        let topInset: CGFloat = max(4, (minHeight - fontSize * 1.2) / 2)
        tv.textContainerInset = UIEdgeInsets(top: topInset, left: 6, bottom: topInset, right: 6)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Scrolling is always on — the SwiftUI binding still drives
        // the frame height via `sizeThatFits` measured in
        // `measureHeight`, so the textView "auto-grows" up to
        // `maxHeight` and starts scrolling content past it. Leaving
        // `isScrollEnabled = false` until overflow used to leave the
        // cursor drifting below the visible bounds whenever content
        // outgrew the animating frame faster than SwiftUI could
        // catch up — symptom was "after Enter, typed text becomes
        // invisible and scrolling doesn't work".
        tv.isScrollEnabled = true
        tv.placeholder = placeholder
        tv.placeholderColor = UIColor(Theme.Color.textSecondary)
        tv.allowedSendCallback = nil
        tv.onImagePaste = onImagePaste
        context.coordinator.textView = tv
        let initial = context.coordinator.attributed(from: text)
        tv.attributedText = initial
        tv.refreshPlaceholderVisibility()
        return tv
    }

    func updateUIView(_ uiView: EmoticonUITextView, context: Context) {
        uiView.onImagePaste = onImagePaste
        // Only re-render when the binding diverges to avoid a feedback loop.
        let current = context.coordinator.plainText(from: uiView.attributedText)
        if current != text {
            let attr = context.coordinator.attributed(from: text)
            uiView.attributedText = attr
            // If the parent supplied a caret position (e.g. the emoji
            // panel just spliced a shortcode mid-string), honour it —
            // map plain offset to attributed offset. Otherwise default
            // to end-of-text, matching the pre-binding behaviour.
            let attrCursor: Int
            if let wantedPlain = caretPlainLocation?.wrappedValue {
                let clampedPlain = min(max(0, wantedPlain), text.count)
                attrCursor = context.coordinator.attributedOffset(in: attr, forPlainOffset: clampedPlain)
            } else {
                attrCursor = attr.length
            }
            uiView.selectedRange = NSRange(location: attrCursor, length: 0)
            // Defer the scroll — see commentary in textViewDidChange.
            DispatchQueue.main.async { [weak uiView] in
                guard let uiView else { return }
                guard let position = uiView.selectedTextRange?.start else { return }
                let caret = uiView.caretRect(for: position)
                guard !caret.isNull && !caret.isInfinite && caret.height > 0 else { return }
                var visible = caret
                visible.size.height += 12
                uiView.scrollRectToVisible(visible, animated: false)
            }
        }
        uiView.refreshPlaceholderVisibility()
        // Re-measure here covers the empty-on-send path where textViewDidChange won't fire.
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
                        // Static fallback so TextKit paths that ignore the view provider still size correctly.
                        let img = GIFImage.cachedImage(for: asset)
                        att.image = img
                        // Pin attachment bounds to [descender, ascender] so TextKit doesn't grow the line.
                        let font = UIFont.systemFont(ofSize: parent.fontSize)
                        let descent = floor(font.descender)
                        let ascent  = floor(font.ascender)
                        let glyphHeight = ascent - descent
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

        /// Mirror the caret position (in plain-string units) back to the
        /// parent's optional binding so external splicers (emoji panel
        /// tapped a smiley) can insert at the user's cursor instead of
        /// the end of input.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let tv = textView as? EmoticonUITextView else { return }
            guard let binding = parent.caretPlainLocation else { return }
            let attrCursor = tv.selectedRange.location
            let plain = plainOffset(in: tv.attributedText, at: attrCursor)
            if binding.wrappedValue != plain {
                binding.wrappedValue = plain
            }
        }

        /// Workaround for a TextKit 2 oddity: after the user collapses
        /// keyboard + emoji panel and re-taps the field, the
        /// NSTextAttachmentViewProvider views (the emoticon glyphs) can
        /// blank out — the text bytes are intact but their attachment
        /// views fail to re-attach to the layout manager. Re-setting
        /// attributedText with a freshly-built copy forces TextKit to
        /// recreate the attachments (and thus fresh view providers),
        /// which paints them again. We preserve the selected range so
        /// the caret doesn't jump.
        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let tv = textView as? EmoticonUITextView else { return }
            let plain = plainText(from: tv.attributedText)
            guard plain.contains(":") else { return }  // no emoticon tokens, nothing to rehydrate
            let rebuilt = attributed(from: plain)
            let savedRange = tv.selectedRange
            tv.attributedText = rebuilt
            let safeLocation = min(savedRange.location, rebuilt.length)
            tv.selectedRange = NSRange(location: safeLocation, length: 0)
            tv.refreshPlaceholderVisibility()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let tv = textView as? EmoticonUITextView else { return }
            let plain = plainText(from: tv.attributedText)
            if parent.text != plain {
                parent.text = plain
                parent.onTextChange?(plain)
            }

            let rebuilt = attributed(from: plain)
            if !attributedEqual(tv.attributedText, rebuilt) {
                let cursor = tv.selectedRange.location
                let plainCursor = plainOffset(in: tv.attributedText, at: cursor)
                tv.attributedText = rebuilt
                let restoredCursor = attributedOffset(in: rebuilt, forPlainOffset: plainCursor)
                tv.selectedRange = NSRange(location: restoredCursor, length: 0)
            }
            tv.refreshPlaceholderVisibility()
            // Always keep the caret in view — frame animations on the
            // SwiftUI side can lag the cursor by a frame or two, and
            // when content exceeds maxHeight we need to actively scroll
            // to the caret since UITextView's auto-scroll only kicks
            // in on character entry, not on Enter-driven newlines.
            //
            // `scrollRangeToVisible(selectedRange)` used to do this
            // synchronously, but it runs against the OLD layout when
            // the attributedText was just rebuilt (emoticon swap path)
            // — the textview's caret could end up below the visible
            // bottom and never come back. Defer to the next runloop
            // so the layout pass finalises, then scroll to the
            // explicit caret rect with some breathing room below.
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                guard let position = tv.selectedTextRange?.start else { return }
                let caret = tv.caretRect(for: position)
                guard !caret.isNull && !caret.isInfinite && caret.height > 0 else { return }
                var visible = caret
                visible.size.height += 12  // pad so the cursor doesn't hug the bottom edge
                tv.scrollRectToVisible(visible, animated: false)
            }
            measureHeight()
        }

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

        /// Equality that ignores `NSObject` reference identity for our
        /// `EmoticonAttachment` instances. The old `a.isEqual(to: b)`
        /// path always returned false after `attributed(from:)`
        /// rebuilt the string — every attachment was a fresh allocation
        /// even when the rendered text was identical — so every
        /// textViewDidChange tick replaced `attributedText`, which
        /// re-created TextKit view providers and flashed the GIF
        /// frames mid-typing (the "smileys flicker on line wrap" bug).
        /// Comparing by attachment `code` short-circuits the
        /// no-op rebuild path entirely.
        private func attributedEqual(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
            if a.length != b.length { return false }
            if (a.string as NSString) != (b.string as NSString) { return false }
            var i = 0
            while i < a.length {
                let aAtt = a.attribute(.attachment, at: i, effectiveRange: nil) as? EmoticonAttachment
                let bAtt = b.attribute(.attachment, at: i, effectiveRange: nil) as? EmoticonAttachment
                if (aAtt == nil) != (bAtt == nil) { return false }
                if let aAtt, let bAtt, aAtt.code != bAtt.code { return false }
                i += 1
            }
            return true
        }
    }
}

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

/// UITextView with a UILabel placeholder overlay; height is driven by EmoticonTextField's binding.
final class EmoticonUITextView: UITextView {
    var placeholder: String = "" {
        didSet { placeholderLabel.text = placeholder; refreshPlaceholderVisibility() }
    }
    var placeholderColor: UIColor = .secondaryLabel {
        didSet { placeholderLabel.textColor = placeholderColor }
    }
    var allowedSendCallback: (() -> Void)?
    /// Fires when the user pastes an image (screenshot, copied photo, etc.).
    /// Wired by the SwiftUI parent — chat composer routes into the pending-media
    /// queue, Bug Bounty into its attachment list. When set, the system Paste
    /// menu shows for image-bearing pasteboards even when the field is empty.
    var onImagePaste: ((UIImage) -> Void)?

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

    // MARK: - image paste

    /// Surface the system Paste action when the pasteboard carries an
    /// image AND we have a handler wired up. UIKit otherwise hides
    /// Paste on an empty text field unless there's text on the clipboard.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)),
           onImagePaste != nil, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Intercept the paste action when an image is on the clipboard.
    /// Routes the image to the parent's handler instead of letting
    /// UIKit attempt to insert it as a text attachment (which it
    /// can't render correctly in this composer's NSTextAttachment
    /// emoticon layout, so the user would see a blank box).
    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if let handler = onImagePaste, let image = pb.image, pb.hasImages {
            handler(image)
            return
        }
        super.paste(sender)
    }
}
