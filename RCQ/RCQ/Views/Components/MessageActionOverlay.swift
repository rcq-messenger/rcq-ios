import SwiftUI
import UIKit

/// Long-press popover for a message: reactions row + actions panel over a material backdrop.
struct MessageActionOverlay: View {
    let message: Message
    let senderNickname: String
    /// Where the held bubble actually is, in this overlay's own space. Nil
    /// when the row is not on screen.
    var bubbleRect: CGRect? = nil
    let canDeleteForEveryone: Bool
    let canReply: Bool
    let canEdit: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onForward: () -> Void
    let onTranslate: () -> Void
    var isTranslated: Bool = false
    let onDeleteForMe: () -> Void
    let onDeleteForEveryone: () -> Void
    let onDismiss: () -> Void
    var onReport: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    var onResend: (() -> Void)? = nil
    /// Group owner / info-moderator only: pin this message into the group's
    /// single pin slot (replaces whatever was pinned, chat- or settings-set).
    var onPin: (() -> Void)? = nil

    @State private var showDeleteSubmenu = false
    @State private var pillSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero

    /// The user's chosen quick reactions, defaulting to the historical set until
    /// customised in the emoji picker.
    @ObservedObject private var emojiPrefs = EmoticonPrefsStore.shared

    /// The quick bar's order FOR THIS OPENING (21): most-used first, ties left
    /// exactly as the picker configured them.
    ///
    /// ⚠⚠ Two rules matter more than the counting itself.
    ///
    /// 1. The order settles when the bar OPENS and never moves while it is open.
    ///    That is what this `@State` is for. Sorting inline in `body` off the
    ///    live counts would re-order the row the moment a tap bumped a weight -
    ///    the buttons would move under the finger that is pressing them, which
    ///    turns a picker into a game of chance. This view is built fresh every
    ///    time `actionTarget` goes non-nil, so one appearance is one order.
    ///
    /// 2. Ties break by the CONFIGURED order, not alphabetically and not by
    ///    whatever the dictionary felt like. `Array.sort` in Swift is not a
    ///    stable sort, so the tie-break is written out by hand below rather than
    ///    left to luck; on a fresh account every weight is zero and the bar must
    ///    read exactly as the emoji picker left it.
    @State private var orderedReactions: [String] = []

    /// Settle the order. Reads the counts once, here, on appear.
    private func settleReactionOrder() {
        let configured = emojiPrefs.reactions
        let counts = EmoticonUsageStore.shared.counts
        orderedReactions = configured.enumerated()
            .sorted { a, b in
                let ca = counts[a.element] ?? 0
                let cb = counts[b.element] ?? 0
                if ca != cb { return ca > cb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    var body: some View {
        GeometryReader { geo in
            if let rect = bubbleRect, fitsBeside(rect, geo) {
                anchored(rect: rect, geo: geo)
            } else {
                // Either there is no anchor (the message is off screen, jumped
                // to from search) or it is too tall to leave where it is: see
                // `fitsBeside`.
                lifted(geo: geo)
            }
        }
        // "The bar opens" - see `orderedReactions`. onAppear, not `.task`: the
        // work is synchronous and must be done before the first paint, so the
        // row never visibly re-shuffles in front of the user.
        .onAppear { settleReactionOrder() }
    }

    // MARK: - the message stays where it is

    /// ⚠⚠ THE HELD MESSAGE IS NOT DRAWN HERE. It is the real bubble, still in
    /// the chat, showing through a hole cut in this view's dim. That is the
    /// whole of the founder's 08.09 note: every other messenger leaves the
    /// message under your finger where your eye already is, and lifting a copy
    /// of it into the middle of the screen made you find it twice.
    ///
    /// A copy was the obvious alternative and it is worse: `MessagePreviewCard`
    /// re-derives the bubble from the message, so a reply quote, a forwarded
    /// label, an edit mark or a reaction row would sit slightly differently
    /// from the original two points underneath it, and the mismatch reads as a
    /// ghost. Nothing can drift out of line with a hole.
    ///
    /// The panels are placed AROUND the rectangle, never over it, and the
    /// rectangle never moves: a message near the top gets its reactions below
    /// rather than being pushed down the screen to make room above.
    @ViewBuilder
    private func anchored(rect: CGRect, geo: GeometryProxy) -> some View {
        let top = geo.safeAreaInsets.top + Self.edgeMargin
        let bottom = geo.size.height - geo.safeAreaInsets.bottom - Self.edgeMargin
        // The message splits what is left into two bands. Everything below is
        // arithmetic on those two numbers, and nothing is ever placed over the
        // message itself.
        let above = max(0, rect.minY - Self.gap - top)
        let below = max(0, bottom - rect.maxY - Self.gap)

        // Reactions go over the message, which is where every messenger puts
        // them; under it when the message is close enough to the top that they
        // would not fit, because the message does not move.
        let pillAbove = pillSize.height <= above
        let pillY = pillAbove ? rect.minY - Self.gap - pillSize.height : rect.maxY + Self.gap

        // Whatever the pill did not take.
        let freeBelow = pillAbove ? below : max(0, below - pillSize.height - Self.gap)
        let freeAbove = pillAbove ? max(0, above - pillSize.height - Self.gap) : above
        // Below by preference; above only when below cannot hold a usable menu
        // AND above can hold more of one.
        let panelBelow = freeBelow >= min(panelSize.height, Self.minPanelHeight) || freeBelow >= freeAbove
        let room = panelBelow ? freeBelow : freeAbove
        let panelHeight = min(panelSize.height, room)
        let panelY = panelBelow
            ? (pillAbove ? rect.maxY + Self.gap : pillY + pillSize.height + Self.gap)
            : (pillAbove ? pillY - Self.gap - panelHeight : rect.minY - Self.gap - panelHeight)

        ZStack(alignment: .topLeading) {
            DimWithHole(
                hole: rect.insetBy(dx: -Self.holePad, dy: -Self.holePad),
                radius: Theme.Metrics.bubbleRadius + Self.holePad,
            )
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
            reactionsPanel
                .measured($pillSize)
                .offset(x: clampedX(width: pillSize.width, rect: rect, geo: geo), y: pillY)
            // ⚠ A ScrollView, always, because `panelHeight` is a clamp: a menu
            // taller than the band it was given must still reach its last row
            // rather than have it cut off. Scrolling is off when it all fits,
            // so a menu that fits does not bounce under the finger.
            ScrollView {
                actionsPanel
                    .frame(width: Self.panelWidth)
                    .measured($panelSize)
            }
            .scrollDisabled(panelHeight >= panelSize.height)
            .frame(width: Self.panelWidth, height: max(0, panelHeight))
            .offset(x: clampedX(width: Self.panelWidth, rect: rect, geo: geo), y: panelY)
        }
        // Both panels are placed off measurements that are zero on the first
        // pass. Showing that pass would flash them in the top-left corner.
        .opacity(pillSize.height > 0 && panelSize.height > 0 ? 1 : 0)
    }

    /// The panels line up with the side the bubble is on, the way the bubble
    /// itself does, and stay inside the screen.
    private func clampedX(width: CGFloat, rect: CGRect, geo: GeometryProxy) -> CGFloat {
        let ideal = message.isFromMe ? rect.maxX - width : rect.minX
        let lo = geo.safeAreaInsets.leading + Self.edgeMargin
        let hi = geo.size.width - geo.safeAreaInsets.trailing - Self.edgeMargin - width
        return min(max(ideal, lo), max(lo, hi))
    }

    private static let gap: CGFloat = 8
    private static let edgeMargin: CGFloat = 10
    /// The hole hugs the bubble exactly. Any padding here shows the chat
    /// background around a photo or a video, which have no bubble colour of
    /// their own: a 4pt pad drew a white frame around every held picture.
    private static let holePad: CGFloat = 0
    private static let panelWidth: CGFloat = 260
    /// Below this a menu is not worth placing on that side: it would be two
    /// rows and a scroll bar.
    private static let minPanelHeight: CGFloat = 180

    // MARK: - too tall to leave alone

    /// Can the menu sit beside the message without anything being cut off?
    ///
    /// Two questions, and a no to either means the message has to be lifted.
    /// Is the message ITSELF fully on screen: one that runs off the top cannot
    /// be read where it lies, and there is no way to scroll the chat while the
    /// menu is up. And is there room on one side of it for a menu worth
    /// showing.
    private func fitsBeside(_ rect: CGRect, _ geo: GeometryProxy) -> Bool {
        // Nothing has been measured yet on the first pass. Answer YES so the
        // anchored branch renders and measures; it draws at opacity 0 until it
        // has its numbers, and a wrong answer for one invisible frame is
        // cheaper than flashing the lifted layout at every long press.
        if pillSize.height == 0 || panelSize.height == 0 { return true }
        let top = geo.safeAreaInsets.top + Self.edgeMargin
        let bottom = geo.size.height - geo.safeAreaInsets.bottom - Self.edgeMargin
        guard rect.minY >= top, rect.maxY <= bottom else { return false }
        let above = max(0, rect.minY - Self.gap - top)
        let below = max(0, bottom - rect.maxY - Self.gap)
        let pillAbove = pillSize.height <= above
        let freeBelow = pillAbove ? below : max(0, below - pillSize.height - Self.gap)
        let freeAbove = pillAbove ? max(0, above - pillSize.height - Self.gap) : above
        return max(freeBelow, freeAbove) >= min(panelSize.height, Self.minPanelHeight)
    }

    /// A message too long to leave where it is: LIFTED, with the menu under it,
    /// and the two of them scrolling together.
    ///
    /// This is the founder's 08.09 note in full. A long message ran off the top
    /// of the screen with no way to scroll it, and the menu had nowhere to go,
    /// so the reactions ended up where the menu should have been and the menu
    /// was not drawn at all. Here the message is a copy — the real one is under
    /// the blur — and the copy is free to move, so the message goes up, the
    /// menu goes under it, and one scroll view carries both. Reactions pin to
    /// the top, clear of the pair, because they are the one thing that must
    /// never be scrolled away from.
    private func lifted(geo: GeometryProxy) -> some View {
        let side: HorizontalAlignment = message.isFromMe ? .trailing : .leading
        return ZStack(alignment: .top) {
            DimWithHole(hole: .zero, radius: 0)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 10) {
                reactionsPanel
                    .measured($pillSize)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: side, spacing: 8) {
                        if !senderNickname.isEmpty {
                            Text(senderNickname)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.Color.accent)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        // No line cap: the scroll view around this exists so
                        // the whole message can be read.
                        MessagePreviewCard(message: message, lineLimit: nil)
                        actionsPanel
                            .frame(width: Self.panelWidth)
                            .measured($panelSize)
                    }
                    .frame(maxWidth: .infinity, alignment: side == .trailing ? .trailing : .leading)
                    .padding(.horizontal, 20)
                    // The stack is bottom-heavy on purpose: a long message
                    // starts at the top of the scroll and the menu is one flick
                    // away, rather than the other way round.
                    .padding(.bottom, 12)
                }
            }
            .padding(.top, geo.safeAreaInsets.top + Self.edgeMargin)
            .padding(.bottom, geo.safeAreaInsets.bottom + Self.edgeMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - reactions

    private var reactionsPanel: some View {
        // ScrollView would happily expand to the parent's full width
        // (was: pill stretched edge-to-edge on every device). Wrap in
        // an HStack with `fixedSize` on horizontal so the ScrollView
        // sizes to its CONTENT and only kicks scrolling when the row
        // genuinely overflows (small width + Dynamic Type). The
        // outer cap of 320pt prevents the pill from ballooning past
        // a comfortable reading width even when content fits.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // The settled order, with the configured list as the fallback
                // for the single frame before onAppear runs.
                ForEach(orderedReactions.isEmpty ? emojiPrefs.reactions : orderedReactions, id: \.self) { asset in
                    Button {
                        // Count it only when it is being SET. `onReact` toggles,
                        // and taking a reaction back off is not a vote for it.
                        // The counts live in the app's existing
                        // `EmoticonUsageStore` rather than a second store of
                        // their own; picking a kolobok is picking a kolobok,
                        // whether it lands in a message or on one.
                        if message.reactions[AuthService.shared.ownUIN ?? 0] != asset {
                            EmoticonUsageStore.shared.bump(asset)
                        }
                        onReact(asset)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onDismiss()
                    } label: {
                        ZStack {
                            if message.reactions.values.contains(asset) {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Theme.Color.accent.opacity(0.3))
                            }
                            GIFImage(name: asset)
                                .frame(width: 30, height: 30)
                        }
                        .frame(width: 42, height: 42)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(maxWidth: 320)
        .fixedSize(horizontal: true, vertical: false)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    // MARK: - actions

    private var actionsPanel: some View {
        VStack(spacing: 0) {
            if showDeleteSubmenu {
                actionRow("chat.action.delete_for_me".localized, icon: "trash", destructive: true) {
                    onDeleteForMe(); onDismiss()
                }
                rowDivider
                actionRow("chat.action.delete_for_everyone".localized, icon: "trash.fill", destructive: true) {
                    onDeleteForEveryone(); onDismiss()
                }
            } else {
                if let onResend, message.deliveryState == .failed {
                    actionRow("chat.action.resend".localized, icon: "arrow.clockwise", destructive: false) {
                        onResend(); onDismiss()
                    }
                    rowDivider
                }
                if canReply && canForward {
                    actionRow("chat.action.reply".localized, icon: "arrowshape.turn.up.left", destructive: false) {
                        onReply(); onDismiss()
                    }
                    rowDivider
                }
                if canEdit {
                    actionRow("chat.action.edit".localized, icon: "pencil", destructive: false) {
                        onEdit(); onDismiss()
                    }
                    rowDivider
                }
                if canForward, message.kind == .text, !message.text.isEmpty {
                    actionRow("chat.action.copy".localized, icon: "doc.on.doc", destructive: false) {
                        UIPasteboard.general.string = message.text
                        UISelectionFeedbackGenerator().selectionChanged()
                        onDismiss()
                    }
                    rowDivider
                    actionRow(
                        (isTranslated ? "chat.action.show_original" : "chat.action.translate").localized,
                        icon: "globe",
                        destructive: false
                    ) {
                        onTranslate(); onDismiss()
                    }
                    rowDivider
                }
                if canForward {
                    actionRow("chat.action.forward".localized, icon: "arrowshape.turn.up.right", destructive: false) {
                        onForward(); onDismiss()
                    }
                    rowDivider
                }
                if let onPin {
                    actionRow("chat.action.pin".localized, icon: "pin", destructive: false) {
                        onPin(); onDismiss()
                    }
                    rowDivider
                }
                if let onSelect {
                    actionRow("chat.action.select".localized, icon: "checkmark.circle", destructive: false) {
                        onSelect(); onDismiss()
                    }
                    rowDivider
                }
                if let onReport, !canDeleteForEveryone {
                    actionRow(
                        "chat.action.report_content".localized,
                        icon: "exclamationmark.bubble",
                        destructive: true
                    ) {
                        onReport(); onDismiss()
                    }
                    rowDivider
                }
                if canDeleteForEveryone {
                    actionRow("chat.action.delete".localized, icon: "trash", destructive: true) {
                        withAnimation(.easeInOut(duration: 0.2)) { showDeleteSubmenu = true }
                    }
                } else {
                    actionRow("chat.action.delete_for_me".localized, icon: "trash", destructive: true) {
                        onDeleteForMe(); onDismiss()
                    }
                }
            }
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.33)
    }

    private var canForward: Bool {
        if message.deletedForEveryone { return false }
        switch message.kind {
        case .text, .photo, .video: return true
        default: return false
        }
    }

    private func actionRow(
        _ title: String,
        icon: String?,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tint: Color = destructive ? Color.red : Theme.Color.textPrimary
        return Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(tint)
                        .frame(width: 22, alignment: .center)
                }
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelBackground: some View {
        Rectangle().fill(.regularMaterial)
    }
}
