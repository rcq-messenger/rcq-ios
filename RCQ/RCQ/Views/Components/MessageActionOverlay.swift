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
    /// Told when the layout switches to drawing a COPY of the message (see
    /// `placement`), so the chat can dim the real row under the blur instead of
    /// leaving a bright, slightly scaled twin of the copy where the message was.
    var onUsesCopy: ((Bool) -> Void)? = nil

    @State private var showDeleteSubmenu = false
    @State private var pillSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero
    /// The copy's natural height at the bubble's width, once it has been drawn.
    @State private var copySize: CGSize = .zero
    /// The bubble's rectangle at the moment the copy layout was chosen. The
    /// live anchor keeps moving for a quarter second after a long press (the
    /// keyboard resigns, the composer shrinks, the list re-lays out) and a copy
    /// that chased it slid across the screen. The hole layout follows the live
    /// rect on purpose; the copy layout freezes it.
    @State private var frozenRect: CGRect? = nil

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
            let p = placement(rect: frozenRect ?? bubbleRect, geo: geo)
            layout(p, geo: geo)
                .onChange(of: p.usesCopy) { uses in
                    if uses, frozenRect == nil { frozenRect = bubbleRect }
                    onUsesCopy?(uses)
                }
        }
        // "The bar opens" - see `orderedReactions`. onAppear, not `.task`: the
        // work is synchronous and must be done before the first paint, so the
        // row never visibly re-shuffles in front of the user.
        .onAppear { settleReactionOrder() }
    }

    // MARK: - where everything goes

    /// One answer for every case: where the pill is, where the panel is, and
    /// whether the message is the real bubble showing through a hole or a copy
    /// that has been moved.
    private struct Placement {
        /// The real bubble stays under a hole in the dim (false), or a copy of
        /// it is drawn and may be moved (true).
        var usesCopy: Bool
        /// False until every panel has been measured. The first pass draws at
        /// opacity 0 so the panels can report their sizes without flashing in
        /// the top-left corner.
        var ready: Bool
        /// Where the message is drawn: the live bubble, or the copy.
        var rect: CGRect
        /// Set when the copy is taller than the room left for it, and has to
        /// scroll inside a frame of this height.
        var messageMaxHeight: CGFloat?
        var pillY: CGFloat
        var panelY: CGFloat
    }

    /// The rule, in the order it is tried (founder, 12.09):
    ///
    /// 1. The message stays where it is, and the WHOLE menu goes on whichever
    ///    side has room for the whole menu — below first, above second. The
    ///    menu is never clamped to a band: a short message near the middle of
    ///    the screen used to get a menu cut to the band under it, two rows and
    ///    a scroll bar, with half the screen empty.
    /// 2. Neither side can hold the whole menu, or the message is not fully on
    ///    screen: a COPY of the message is drawn and MOVED. The menu is pinned
    ///    fully visible at the bottom, the message sits directly above it, the
    ///    reactions above that. A long message goes UP and the menu is under
    ///    it, which is what every other messenger does; it used to be lifted
    ///    into a scroll view with the menu after its last line, off the bottom
    ///    of the screen, and you scrolled the message to find the menu.
    /// 3. A message taller than what is left scrolls inside its frame, opened
    ///    at its tail so the last lines sit right above the menu; the reactions
    ///    pin at the top, the menu at the bottom, nothing ever off screen.
    ///
    /// Everything is decided from `rect.height`, which is known on the first
    /// frame, never from the copy's measured height, so the invisible first
    /// pass does not flip between layouts.
    private func placement(rect anchor: CGRect?, geo: GeometryProxy) -> Placement {
        let top = geo.safeAreaInsets.top + Self.edgeMargin
        let bottom = geo.size.height - geo.safeAreaInsets.bottom - Self.edgeMargin
        let gap = Self.gap
        let pillH = pillSize.height
        let panelH = panelSize.height
        let measured = pillH > 0 && panelH > 0

        // Nothing measured yet: draw the in-place layout invisibly so the
        // panels can report their sizes. One wrong invisible frame is cheaper
        // than flashing the copy layout at every long press.
        if let rect = anchor, !measured {
            return Placement(usesCopy: false, ready: false, rect: rect, messageMaxHeight: nil,
                             pillY: rect.minY - gap - pillH, panelY: rect.maxY + gap)
        }

        if let rect = anchor, rect.minY >= top, rect.maxY <= bottom {
            let above = max(0, rect.minY - gap - top)
            let below = max(0, bottom - rect.maxY - gap)
            // Reactions over the message, where every messenger puts them;
            // under it only when the message is too close to the top.
            let pillAbove = pillH <= above
            let pillY = pillAbove ? rect.minY - gap - pillH : rect.maxY + gap
            let freeBelow = pillAbove ? below : max(0, below - pillH - gap)
            let freeAbove = pillAbove ? max(0, above - pillH - gap) : above
            if freeBelow >= panelH {
                let panelY = pillAbove ? rect.maxY + gap : pillY + pillH + gap
                return Placement(usesCopy: false, ready: true, rect: rect, messageMaxHeight: nil, pillY: pillY, panelY: panelY)
            }
            if freeAbove >= panelH {
                let panelY = pillAbove ? pillY - gap - panelH : rect.minY - gap - panelH
                return Placement(usesCopy: false, ready: true, rect: rect, messageMaxHeight: nil, pillY: pillY, panelY: panelY)
            }
        }

        // The copy. Its width is the bubble's own, so it wraps exactly as the
        // bubble did; with no anchor at all (jumped to from search) it takes
        // the chat's width less the margins.
        let width = anchor?.width ?? (geo.size.width - 40)
        let x = anchor?.minX ?? (message.isFromMe ? geo.size.width - 20 - width : 20)
        let panelY = bottom - panelH
        let maxMessageH = max(0, panelY - gap - (top + pillH + gap))
        let naturalH = copySize.height > 0 ? copySize.height : (anchor?.height ?? 0)
        let messageH = min(naturalH, maxMessageH)
        let messageY = panelY - gap - messageH
        let pillY = messageY - gap - pillH
        return Placement(
            usesCopy: true,
            ready: measured && copySize.height > 0,
            rect: CGRect(x: x, y: messageY, width: width, height: messageH),
            messageMaxHeight: naturalH > maxMessageH ? maxMessageH : nil,
            pillY: pillY,
            panelY: panelY
        )
    }

    /// ⚠⚠ THE HELD MESSAGE IS NOT DRAWN HERE unless it has to move. In the
    /// ordinary case it is the real bubble, still in the chat, showing through
    /// a hole cut in this view's dim: every other messenger leaves the message
    /// under your finger where your eye already is, and lifting a copy of it
    /// into the middle of the screen made you find it twice (founder, 08.09).
    ///
    /// A copy is drawn only when the message cannot stay: nothing beside it
    /// would hold the menu, or it runs off the screen. The real one is then
    /// under the blur, dimmed by the chat like every other row (`onUsesCopy`).
    ///
    /// Dismissal is the dim. The panels and the copy are framed to their own
    /// sizes, so a tap anywhere else lands on the dim; the copy itself
    /// dismisses on tap too, as the hole does.
    @ViewBuilder
    private func layout(_ p: Placement, geo: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            DimWithHole(
                hole: p.usesCopy ? .zero : p.rect.insetBy(dx: -Self.holePad, dy: -Self.holePad),
                radius: Theme.Metrics.bubbleRadius + Self.holePad
            )
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
            if p.usesCopy {
                messageCopy(p)
                    .offset(x: p.rect.minX, y: p.rect.minY)
            }
            reactionsPanel
                .measured($pillSize)
                .offset(x: clampedX(width: pillSize.width, rect: p.rect, geo: geo), y: p.pillY)
            actionsPanel
                .frame(width: Self.panelWidth)
                .measured($panelSize)
                .offset(x: clampedX(width: Self.panelWidth, rect: p.rect, geo: geo), y: p.panelY)
        }
        // Placed off measurements that are zero on the first pass. Showing that
        // pass would flash the panels in the top-left corner.
        .opacity(p.ready ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: p.rect.minY)
    }

    /// The copy of the message, framed to the bubble's width. Taller than the
    /// room left for it, it scrolls inside that room and opens at its tail.
    @ViewBuilder
    private func messageCopy(_ p: Placement) -> some View {
        let side: HorizontalAlignment = message.isFromMe ? .trailing : .leading
        let card = VStack(alignment: side, spacing: 4) {
            if !senderNickname.isEmpty {
                Text(senderNickname)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // No line cap: this layout exists so the whole message can be read.
            MessagePreviewCard(message: message, lineLimit: nil)
        }
        .frame(width: p.rect.width, alignment: side == .trailing ? .trailing : .leading)
        .measured($copySize)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }

        if let maxHeight = p.messageMaxHeight {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    card
                    Color.clear.frame(height: 1).id("tail")
                }
                .frame(width: p.rect.width, height: maxHeight)
                // Opened at the end, so the last lines sit right above the menu
                // and the reader scrolls UP for the beginning, the way a chat
                // reads. `defaultScrollAnchor` is iOS 17; this app ships to 16.
                .onAppear { proxy.scrollTo("tail", anchor: .bottom) }
            }
        } else {
            card
        }
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
                // #971: a caption is text too. This was gated on the KIND being
                // text, so a photo with a paragraph under it had no Copy; `text`
                // carries the caption for media, so the gate is whether there is
                // anything in it.
                if canForward, !message.text.isEmpty,
                   [.text, .photo, .video, .voice, .file].contains(message.kind) {
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
