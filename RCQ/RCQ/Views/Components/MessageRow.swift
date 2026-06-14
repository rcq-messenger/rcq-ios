import AVKit
import SwiftUI

extension Message {
    /// Stored as the `text` of a received "peer took a screenshot" notice so
    /// the screenshotter's name resolves at DISPLAY time, not at ingest.
    static let screenshotSentinel = "\u{1}rcq.secscreen\u{1}"

    /// Localized display text for a system notice. A screenshot notice
    /// resolves the screenshotter's CURRENT nickname (the 1:1 peer is always a
    /// contact; resolving live avoids the stale "#911" that got baked when
    /// contacts weren't loaded yet during a reconnect-queue drain). All other
    /// system notices return their stored text unchanged.
    @MainActor var systemNoticeText: String {
        guard text == Message.screenshotSentinel else { return text }
        let nick = ContactService.shared.contacts.first { $0.uin == senderUIN }?.nickname
        let name = (nick?.isEmpty == false) ? nick! : "secscreen.peer_fallback".localized
        return String(format: "secscreen.peer_screenshotted".localized, name)
    }
}

/// Single chat message bubble — extracted from `ChatView` to keep
/// the parent file under SwiftUI's type-checker complexity ceiling.
/// Self-contained: every dependency travels as an init parameter
/// (target, callbacks, group-member list for @mention rendering),
/// so the row knows nothing about the surrounding chat lifecycle.
struct MessageRow: View {
    let message: Message
    let showSender: Bool
    let senderNickname: String
    /// When set, overrides the reply-quote author label (used to show "You"
    /// when the quoted message is the viewer's own — the wire still carries
    /// the real nick so other people see the nick).
    var replyAuthorOverride: String? = nil
    let displayBody: String
    let isTranslated: Bool
    let isHighlighted: Bool
    var isSelected: Bool = false
    var showSelectionAffordance: Bool = false
    let onTapReaction: (String) -> Void
    var onShowReactors: (() -> Void)? = nil
    let onLongPress: () -> Void
    let onDoubleTapLike: () -> Void
    var onTapWhenSelecting: (() -> Void)? = nil
    let onTapReplyQuote: (UUID) -> Void
    let onSwipeReply: () -> Void
    var currentGroupMembers: [RCQGroupMember] = []
    /// Optional aggregate view count for closed-group messages. Nil
    /// means "no badge" (1:1, open group, or count not yet fetched).
    /// Renders next to the timestamp as `👁 N`.
    var viewCount: Int? = nil

    /// Resolve a `#<uin>` in the body to a nick (group member / contact) so it
    /// renders as the clickable nick that opens the profile — Android parity.
    private var uinNick: (Int) -> String? {
        { uin in
            currentGroupMembers.first(where: { $0.uin == uin })?.nickname
                ?? ContactService.shared.contacts.first(where: { $0.uin == uin })?.nickname
        }
    }

    @State private var swipeOffset: CGFloat = 0
    @State private var swipeArmed: Bool = false
    @State private var bubblePressed: Bool = false
    /// Telegram-style collapse of a very long text body (#2): tap "Show more".
    @State private var bodyExpanded: Bool = false

    /// Conservative estimate of how many wrapped lines [body] takes in a chat
    /// bubble (~38 chars/line): sum over hard lines of ceil(len/38). Decides
    /// whether to collapse + offer "Show more"; `collapsedPrefix` below does
    /// the actual cut with the SAME math, so the button appears exactly when
    /// text was removed. Biased to not over-trigger on short messages.
    /// Realistic chars-per-rendered-line for the bubble body at the default body
    /// font in a 78%-width bubble. Cyrillic at this size wraps far shorter than
    /// the ~38 (Latin max) the old estimate assumed, which made the collapse fire
    /// on modest messages and bake a mid-message "…" into the text. 22 is
    /// calibrated for Cyrillic; `collapseLineBudget` is deliberately generous so
    /// only a screen-filling wall of text collapses.
    static let charsPerLine = 22
    static let collapseLineBudget = 40

    static func estimatedLineCount(_ body: String) -> Int {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + charsPerLine - 1) / charsPerLine) }
    }

    /// The collapsed body: [body] cut after ~[maxLines] estimated wrapped
    /// lines, at a whitespace boundary, with a trailing ellipsis. STRING-level
    /// truncation, not lineLimit: EmoticonText renders each hard line as its
    /// own Text, and an environment lineLimit caps every one of them
    /// SEPARATELY — a 20-paragraph message never got cut at all (founder
    /// screenshot: "collapsed" message filling two screens), while dropping
    /// the vertical fixedSize to let lineLimit work resurrected the
    /// LazyVStack mis-measure that squeezed each paragraph to a couple of
    /// lines with "…" (the other founder screenshot).
    static func collapsedPrefix(_ body: String, maxLines: Int = MessageRow.collapseLineBudget) -> String {
        var remaining = maxLines
        var kept: [Substring] = []
        for para in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let est = max(1, (para.count + charsPerLine - 1) / charsPerLine)
            if est < remaining {
                kept.append(para)
                remaining -= est
            } else {
                // Budget ends inside this paragraph — cut at the last
                // whitespace before it so words (and emoticon codes)
                // survive whole.
                var cut = para.prefix(remaining * charsPerLine)
                if cut.count < para.count,
                   let sp = cut.lastIndex(where: { $0.isWhitespace }) {
                    cut = cut[..<sp]
                }
                kept.append(cut)
                break
            }
        }
        return kept.joined(separator: "\n") + "…"
    }

    private static let swipeTriggerDistance: CGFloat = 60
    private static let swipeMaxDistance: CGFloat = 80
    /// Hard cap on bubble width (~78% of the screen) so the body wraps at a
    /// determinate width and the LazyVStack measures its height right.
    private static var maxBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.78 }

    @ViewBuilder
    var body: some View {
        if showSelectionAffordance {
            selectableRow
        } else {
            primaryBody
        }
    }

    private var selectableRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(isSelected ? Theme.Color.accent : Theme.Color.textSecondary)
                .padding(.leading, 6)
            primaryBody
                .allowsHitTesting(false)
        }
        .background(
            Rectangle()
                .fill(isSelected ? Theme.Color.accent.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTapWhenSelecting?()
        }
    }

    @ViewBuilder
    private var primaryBody: some View {
        if message.kind == .systemNotice {
            HStack {
                Spacer()
                Text(message.systemNoticeText)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                ZStack(alignment: .trailing) {
                    if swipeOffset < -2 {
                        let progress = min(1.0, abs(swipeOffset) / Self.swipeTriggerDistance)
                        let armed = abs(swipeOffset) >= Self.swipeTriggerDistance
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(armed ? Theme.Color.accent : Theme.Color.textSecondary)
                            .opacity(progress)
                            .scaleEffect(0.7 + 0.3 * progress)
                            .padding(.trailing, 12)
                    }
                    HStack(alignment: .bottom) {
                        if message.isFromMe { Spacer(minLength: 40) }
                        // Tap/long-press scoped to bubble; the wider row only handles swipe-reply.
                        bubble
                            .scaleEffect(bubblePressed ? 0.96 : 1.0, anchor: message.isFromMe ? .trailing : .leading)
                            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: bubblePressed)
                            .onTapGesture(count: 2) {
                                guard !message.deletedForEveryone, message.kind != .systemNotice else { return }
                                onDoubleTapLike()
                            }
                            .onLongPressGesture(
                                // 0.18s was catching scroll-decel finger lingers
                                // as long-press, stopping the scroll. Telegram-
                                // grade feel is ~0.4s — leaves headroom for
                                // natural scroll pauses without losing the
                                // "press to act" cue.
                                minimumDuration: 0.4,
                                pressing: { isPressing in
                                    bubblePressed = isPressing
                                },
                                perform: {
                                    bubblePressed = false
                                    onLongPress()
                                }
                            )
                        if !message.isFromMe { Spacer(minLength: 40) }
                    }
                    .offset(x: swipeOffset)
                }
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        if message.isFromMe { Spacer(minLength: 40) }
                        ReactionsBar(message: message, onTap: onTapReaction, onShowWho: onShowReactors)
                        if !message.isFromMe { Spacer(minLength: 40) }
                    }
                }
            }
            // Full-width row so swipe-reply has a hit target even when the bubble is short.
            .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.Color.accent.opacity(isHighlighted ? 0.18 : 0))
            )
            .contentShape(Rectangle())
            // simultaneousGesture (not .gesture) so iOS's screen-edge back-swipe keeps working.
            .simultaneousGesture(
                // minimumDistance: 25 (was 18). Lets the ScrollView's pan
                // win small vertical drifts without our gesture even
                // activating — fewer accidental "scroll caught on a
                // message" cancellations during long scrolls.
                DragGesture(minimumDistance: 25)
                    .onChanged { value in
                        guard !message.deletedForEveryone, message.kind != .systemNotice else { return }
                        // Leading-edge drags belong to iOS's interactive-pop
                        // gesture. 60pt buffer (was 32) so the back-swipe
                        // doesn't fight our reply-swipe when the user
                        // starts a hair right of the edge.
                        if value.startLocation.x < 60 {
                            if swipeOffset != 0 { swipeOffset = 0 }
                            swipeArmed = false
                            return
                        }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        // Vertical-dominant or right-swipe → let the ScrollView pan win.
                        if abs(dy) > abs(dx) {
                            if swipeOffset != 0 { swipeOffset = 0 }
                            swipeArmed = false
                            return
                        }
                        if dx >= 0 {
                            if swipeOffset != 0 { swipeOffset = 0 }
                            swipeArmed = false
                            return
                        }
                        // Linear up to trigger, then rubber-band to the hard cap.
                        let raw = -dx
                        let bubble: CGFloat
                        if raw <= Self.swipeTriggerDistance {
                            bubble = -raw
                        } else {
                            let extra = (raw - Self.swipeTriggerDistance) * 0.4
                            bubble = -min(Self.swipeMaxDistance, Self.swipeTriggerDistance + extra)
                        }
                        swipeOffset = bubble
                        if !swipeArmed && raw >= Self.swipeTriggerDistance {
                            swipeArmed = true
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } else if swipeArmed && raw < Self.swipeTriggerDistance {
                            swipeArmed = false
                        }
                    }
                    .onEnded { _ in
                        let didReply = swipeArmed
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                            swipeOffset = 0
                        }
                        swipeArmed = false
                        if didReply {
                            onSwipeReply()
                        }
                    }
            )
        }
    }

    /// A plain text bubble carries the sender name + reply quote + body + time
    /// INSIDE the coloured bubble (Telegram-style, founder parity with Android).
    /// Media/voice/file/poll/location/relay/group-link keep the legacy layout
    /// (name above, time below) — they have no clean inline slot.
    private var isPlainTextBubble: Bool {
        if message.deletedForEveryone { return false }
        switch message.kind {
        case .photo, .video, .voice, .file, .location, .poll, .relay: return false
        default: break
        }
        return GroupLinkParser.parse(message.text) == nil
    }

    @ViewBuilder
    private var bubble: some View {
        if isPlainTextBubble {
            plainTextBubble
        } else {
            nonTextBubble
        }
    }

    /// Non-text bubble: sender name + reply quote ABOVE the coloured content,
    /// time/ticks BELOW it (the original layout, unchanged).
    private var nonTextBubble: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
            if showSender { senderLabel }
            forwardedLabel
            replyQuote
            HStack(alignment: .bottom, spacing: 6) {
                bubbleContent
                    // Determinate width cap so the body wraps at a fixed width
                    // and the LazyVStack measures its height right on first layout.
                    .frame(maxWidth: Self.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)
            }
            metaRow
        }
    }

    /// Plain text bubble: everything inside ONE coloured container (Telegram).
    private var plainTextBubble: some View {
        let collapsed = !bodyExpanded && Self.estimatedLineCount(displayBody) > Self.collapseLineBudget
        return VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                if showSender { senderLabel }
                forwardedLabel
                replyQuote
                EmoticonText(
                    text: collapsed ? Self.collapsedPrefix(displayBody) : displayBody,
                    members: currentGroupMembers,
                    uinNick: uinNick
                )
                .fixedSize(horizontal: false, vertical: true)
                if collapsed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { bodyExpanded = true }
                    } label: {
                        Text("chat.show_more".localized)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                }
                metaRow
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
            .cornerRadius(Theme.Metrics.bubbleRadius)
            // maxWidth cap LAST (outermost) so the bubble HUGS its content and
            // only caps the wrap width — like the original bubbleContent. With
            // the frame innermost the VStack filled the full width (founder:
            // short bubbles were full-width).
            .frame(maxWidth: Self.maxBubbleWidth, alignment: message.isFromMe ? .trailing : .leading)
            if isTranslated { translatedFooter }
            // Read off the original body so a translation that mangles the URL still gets a preview.
            if let url = LinkDetector.firstURL(in: message.text) {
                LinkPreviewCard(url: url)
            }
        }
    }

    /// Group sender name (tappable → profile). Shown inside a text bubble,
    /// above a non-text one.
    @ViewBuilder
    private var senderLabel: some View {
        Button {
            AppState.shared.pendingOpenUserProfile = message.senderUIN
        } label: {
            Text(senderNickname)
                .font(.caption2.weight(.semibold))
                .foregroundColor(Theme.Color.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var forwardedLabel: some View {
        if let fwdName = message.forwardedFromName, !fwdName.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 9))
                Text(String(format: "chat.forwarded_from".localized, fwdName))
                    .font(.caption2.italic())
            }
            .foregroundColor(Theme.Color.textSecondary)
        }
    }

    @ViewBuilder
    private var replyQuote: some View {
        if let snippet = message.replyToSnippet, !snippet.isEmpty {
            Button {
                if let target = message.replyToID {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onTapReplyQuote(target)
                }
            } label: {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Theme.Color.accent)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        if let author = replyAuthorOverride ?? message.replyToAuthorName, !author.isEmpty {
                            Text(author)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(Theme.Color.accent)
                                .lineLimit(1)
                        }
                        EmoticonText(
                            // Newlines flattened: EmoticonText renders each hard line
                            // as its OWN Text, so one flat line + lineLimit(2) is the
                            // whole preview contract.
                            text: snippet.replacingOccurrences(of: "\n", with: " "),
                            font: .caption2,
                            color: Theme.Color.textSecondary,
                            emoticonSize: 15,
                            members: currentGroupMembers,
                            uinNick: uinNick
                        )
                        .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
                // Always leading: the accent bar sits at the content's LEFT
                // edge for both incoming and outgoing. Trailing-aligning an
                // outgoing quote floated the bar inward off the body's left
                // edge — the "crooked" reply on my own messages.
                .frame(
                    maxWidth: 240,
                    alignment: .leading
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Time + edited + ttl + view-count + delivery ticks.
    private var metaRow: some View {
        HStack(spacing: 4) {
            Text(DateFormatters.timeOfDay.string(from: message.sentAt))
                .font(Theme.Font.timestamp)
                .foregroundColor(Theme.Color.textSecondary)
            if message.editedAt != nil {
                Text("chat.edited_suffix".localized)
                    .font(Theme.Font.timestamp.italic())
                    .foregroundColor(Theme.Color.textSecondary)
            }
            if message.ttlSeconds != nil {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            if let n = viewCount, n > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 9))
                    Text("\(n)")
                        .font(Theme.Font.timestamp)
                }
                .foregroundColor(Theme.Color.textSecondary)
            }
            if message.isFromMe {
                deliveryIcon
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.deletedForEveryone {
            Text("chat.deleted".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius)
                        .stroke(Theme.Color.divider, lineWidth: 1)
                )
        } else if message.kind == .photo {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                PhotoBubble(message: message)
                if !displayBody.isEmpty {
                    EmoticonText(text: displayBody, members: currentGroupMembers, uinNick: uinNick)
                        // Same full-height pin as the plain-text bubble below, so a
                        // long caption never truncates to a couple of lines.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                        .cornerRadius(Theme.Metrics.bubbleRadius)
                    if isTranslated { translatedFooter }
                }
            }
        } else if message.kind == .video {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                VideoBubble(message: message)
                if !displayBody.isEmpty {
                    EmoticonText(text: displayBody, members: currentGroupMembers, uinNick: uinNick)
                        // Same full-height pin as the plain-text bubble below, so a
                        // long caption never truncates to a couple of lines.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                        .cornerRadius(Theme.Metrics.bubbleRadius)
                    if isTranslated { translatedFooter }
                }
            }
        } else if message.kind == .voice {
            VoiceBubble(message: message)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                .cornerRadius(Theme.Metrics.bubbleRadius)
        } else if message.kind == .file {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                FileBubble(message: message)
                    .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                    .cornerRadius(Theme.Metrics.bubbleRadius)
                if !displayBody.isEmpty {
                    EmoticonText(text: displayBody, members: currentGroupMembers, uinNick: uinNick)
                        // Same full-height pin as the plain-text bubble below, so a
                        // long caption never truncates to a couple of lines.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                        .cornerRadius(Theme.Metrics.bubbleRadius)
                    if isTranslated { translatedFooter }
                }
            }
        } else if message.kind == .location {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                LocationBubble(message: message)
                if !displayBody.isEmpty {
                    EmoticonText(text: displayBody, members: currentGroupMembers, uinNick: uinNick)
                        // Same full-height pin as the plain-text bubble below, so a
                        // long caption never truncates to a couple of lines.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                        .cornerRadius(Theme.Metrics.bubbleRadius)
                    if isTranslated { translatedFooter }
                }
            }
        } else if message.kind == .poll {
            // Group polls — `creatorIsMe` toggles the "Close" footer
            // button so only the original creator sees the affordance.
            // PollBubble owns its own background + max-width clip.
            PollBubble(message: message, creatorIsMe: message.isFromMe)
        } else if message.kind == .relay {
            // In-chat bridge sharing: a relay a contact handed you (Add) or you
            // sent. RelayShareBubble owns its own background.
            RelayShareBubble(message: message)
        } else if let share = GroupLinkParser.parse(message.text) {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                GroupLinkBubble(groupID: share.groupID, host: share.host, rawURL: share.url)
                if isTranslated { translatedFooter }
            }
        } else {
            // Collapse a very long message to ~14 lines with a "Show more"
            // toggle (#2, Telegram-style). The gate is a conservative ESTIMATE
            // of the wrapped line count; when it clears 14, the BODY STRING is
            // cut by the same math (collapsedPrefix). lineLimit can't do this
            // cut — EmoticonText is one Text PER hard line, so an environment
            // lineLimit caps each paragraph separately and a multi-paragraph
            // message never shrinks. The vertical fixedSize stays on in BOTH
            // states: without it the LazyVStack mis-measure squeezes the
            // paragraphs to arbitrary couple-line stubs with "…".
            let collapsed = !bodyExpanded && Self.estimatedLineCount(displayBody) > Self.collapseLineBudget
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                EmoticonText(
                    text: collapsed ? Self.collapsedPrefix(displayBody) : displayBody,
                    members: currentGroupMembers,
                    uinNick: uinNick
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                    .cornerRadius(Theme.Metrics.bubbleRadius)
                if collapsed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { bodyExpanded = true }
                    } label: {
                        Text("chat.show_more".localized)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                }
                if isTranslated { translatedFooter }
                // Read off the original body so a translation that mangles the URL still gets a preview.
                if let url = LinkDetector.firstURL(in: message.text) {
                    LinkPreviewCard(url: url)
                }
            }
        }
    }


    private var translatedFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 9))
            Text("chat.translate.translated_badge".localized)
                .font(.system(size: 10))
        }
        .foregroundColor(Theme.Color.textSecondary)
    }

    @ViewBuilder
    private var deliveryIcon: some View {
        switch message.deliveryState {
        case .sending:   Image(systemName: "clock").font(.system(size: 9)).foregroundColor(Theme.Color.textSecondary)
        case .sent:      Image(systemName: "checkmark").font(.system(size: 9)).foregroundColor(Theme.Color.textSecondary)
        case .delivered: Image(systemName: "checkmark.circle").font(.system(size: 9)).foregroundColor(Theme.Color.textSecondary)
        case .read:      Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundColor(Theme.Color.accent)
        case .failed:    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(Theme.Color.statusBusy)
        }
    }

}

/// In-chat bridge sharing: a relay a contact handed you (Add it to your
/// transport pool) or one you sent. The rcq-relay:// token lives in
/// `message.text`. See RCQ/docs/bridge-sharing-design.md.
private struct RelayShareBubble: View {
    let message: Message
    @State private var added = false

    private var relay: RelayConfigStore.RelayEntry? { ContactRelayStore.relayFromToken(message.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled").foregroundColor(Theme.Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("relay.share.title".localized)
                        .font(.subheadline).bold().foregroundColor(Theme.Color.textPrimary)
                    if let r = relay {
                        Text("\(r.proto.rawValue.uppercased()) · \(r.server):\(r.port)")
                            .font(.caption2).foregroundColor(Theme.Color.textSecondary).lineLimit(1)
                    }
                }
            }
            if relay == nil {
                Text("relay.share.invalid".localized).font(.caption).foregroundColor(Theme.Color.textSecondary)
            } else if message.isFromMe {
                Text("relay.share.sent_note".localized).font(.caption2).foregroundColor(Theme.Color.textSecondary)
            } else if added {
                Text("relay.share.added".localized).font(.caption).bold().foregroundColor(Theme.Color.accent)
            } else {
                Button {
                    if let r = relay { ContactRelayStore.shared.add(r, fromUin: message.senderUIN, fromName: nil) }
                    added = true
                } label: {
                    Text("relay.share.add".localized)
                        .font(.caption).bold().foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.Color.accent).cornerRadius(8)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
        .cornerRadius(Theme.Metrics.bubbleRadius)
        .onAppear { if let r = relay { added = ContactRelayStore.shared.has(r) } }
    }
}

