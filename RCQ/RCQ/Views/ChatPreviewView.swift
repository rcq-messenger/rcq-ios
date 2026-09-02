import SwiftUI

/// Read-only chat preview for the contextMenu `preview:` slot. Does NOT fire read receipts.
struct ChatPreviewView: View {
    let target: ChatTarget
    var compact: Bool = true
    /// Ceiling for the compact card on a short screen. Applied HERE, to the
    /// card's own frame, so the card stays a fixed-size view: capping it from
    /// the outside with `.frame(maxHeight:)` made it flexible, and the stack
    /// above then stretched it to the full cap — which put the caller's
    /// rounded clip on a rectangle far taller than the card, so the corners
    /// curved somewhere out in empty space and the card itself read as a plain
    /// square. It also left a large gap between the card and the action list.
    var maxHeight: CGFloat = .greatestFiniteMagnitude

    @StateObject private var store = MessageStore.shared
    @StateObject private var contacts = ContactService.shared
    @StateObject private var groupSvc = GroupService.shared
    @State private var bottomVisible: Bool = true

    var body: some View {
        // ⚠ `safeAreaInset`, not a ZStack overlay. Overlaid, the pill floated on
        // top of a list that still began at its own padding, so the newest
        // message was drawn UNDERNEATH it and the taller the text size the more
        // of it disappeared (founder, 01.09). An inset both places the pill and
        // reserves its height in the scroll content, so the first bubble starts
        // below it and later ones still scroll under it. No constant to keep in
        // step with the pill's own padding, which is what an overlay would have
        // needed.
        Group {
            if compact {
                messages.safeAreaInset(edge: .top, spacing: 0) {
                    floatingIdentity
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                }
            } else {
                messages
            }
        }
        .modifier(PreviewFrame(compact: compact, maxHeight: maxHeight))
        // Compact = the floating card over a dimmed backdrop, which needs a
        // surface that is actually distinguishable from it; full size = a plain
        // screen, which uses the normal chat background.
        .background(compact ? Theme.Color.bgElevated : Theme.Color.bgPrimary)
        // Flatten the subtree (ScrollView, material pill, bubbles) into one
        // layer, then round it HERE, where the bounds are the card's own.
        .compositingGroup()
        .clipShape(Self.cardShape(compact))
        // The window this card draws is read from CoreData on demand, and a
        // long press on a chat the user has not opened is a demand. On
        // `onAppear` rather than inside `messages`: the preview is built while
        // the menu is presented, and mutating a published store from a body is
        // how "Publishing changes from within view updates" happens.
        .onAppear { MessageStore.shared.ensureLoaded(target.thread) }
    }

    @ViewBuilder
    private var floatingIdentity: some View {
        HStack(spacing: 8) {
            switch target {
            case .peer(let snapshot):
                let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
                PersonAvatarView(
                    mediaID: live.avatarMediaID, keyBase64: live.avatarMediaKey,
                    status: live.status, host: live.host, size: 28,
                    crossIsland: live.host != nil
                )
                VStack(spacing: 0) {
                    Text(live.nickname)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: "\(live.uin)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                }
            case .group(let snapshot):
                let live = groupSvc.find(snapshot.id) ?? snapshot
                GroupAvatarView(
                    mediaID: live.avatarMediaID,
                    keyBase64: live.avatarMediaKey,
                    size: 22,
                )
                VStack(spacing: 0) {
                    Text(live.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(MemberCountLabel.text(live.memberCount))
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            case .randomPeer:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.Color.divider.opacity(0.3), lineWidth: 0.5))
    }

    @ViewBuilder
    private var messages: some View {
        let thread = target.thread
        let all = store.threads[thread] ?? []
        let recent = all.suffix(50)
        if recent.isEmpty {
            VStack {
                Spacer()
                // Empty only counts once the window has actually been read.
                // `body` runs before the `onAppear` below, so on the first
                // frame of a preview for a chat nobody has opened this session
                // the dictionary is empty for the ordinary reason — which drew
                // "no messages" over every such chat and then popped the
                // history in mid-transition, and made a genuinely empty chat
                // indistinguishable from an unread one.
                if store.isLoaded(thread) {
                    Text("chat.preview.no_messages".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
            }
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        // allowsHitTesting on the inner stack only — keeps the ScrollView pan working.
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(recent), id: \.id) { msg in
                                ChatPreviewBubble(
                                    message: msg,
                                    senderNickname: senderNickname(msg.senderUIN)
                                )
                                .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: ChatPreviewBottomVisiblePref.self,
                                    value: g.frame(in: .named("preview-scroll")).minY < 1200
                                )
                            })
                    }
                    .coordinateSpace(name: "preview-scroll")
                    .onPreferenceChange(ChatPreviewBottomVisiblePref.self) { value in
                        bottomVisible = value
                    }
                    .onAppear {
                        if let last = recent.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    if !bottomVisible {
                        Button {
                            withAnimation(.easeOut(duration: 0.28)) {
                                if let last = recent.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                } else {
                                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                                .frame(width: 30, height: 30)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(Theme.Color.divider.opacity(0.4), lineWidth: 0.5))
                        }
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: bottomVisible)
            }
        }
    }

    private static let bottomAnchorID = "__rcq_chat_preview_bottom"

    /// The card's shape. Continuous (squircle) is what iOS gives its own
    /// context-menu previews; 22pt is enough to read as a card at 360pt wide.
    /// A full-size preview is a plain screen and stays square.
    static func cardShape(_ compact: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? 22 : 0, style: .continuous)
    }

    private func senderNickname(_ uin: Int) -> String {
        if uin == AuthService.shared.ownUIN { return AuthService.shared.nickname }
        if case .group(let g) = target, let m = g.members.first(where: { $0.uin == uin }) {
            return m.nickname
        }
        if let c = contacts.contacts.first(where: { $0.uin == uin }) { return c.nickname }
        return String(uin)
    }
}

private struct ChatPreviewBottomVisiblePref: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

private struct PreviewFrame: ViewModifier {
    let compact: Bool
    let maxHeight: CGFloat
    func body(content: Content) -> some View {
        if compact {
            content.frame(width: 360, height: min(340, maxHeight))
        } else {
            content
        }
    }
}

private struct ChatPreviewBubble: View {
    let message: Message
    let senderNickname: String

    private var isPureMedia: Bool {
        switch message.kind {
        case .photo, .video: return message.text.isEmpty
        default: return false
        }
    }

    var body: some View {
        if message.kind == .systemNotice {
            HStack {
                Spacer()
                Text(message.systemNoticeText).font(.caption2).foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
        } else {
            HStack {
                if message.isFromMe { Spacer(minLength: 30) }
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                    if !message.isFromMe {
                        Text(senderNickname)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    if let fwd = message.forwardedFromName, !fwd.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                                .font(.system(size: 8))
                            Text(String(format: "chat.forwarded_from".localized, fwd))
                                .font(.caption2.italic())
                        }
                        .foregroundColor(Theme.Color.textSecondary)
                    }
                    if isPureMedia {
                        // Media clips itself — extra bubble fill would leave a colored strip around the image.
                        bubbleBody
                    } else {
                        bubbleBody
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius)
                                    .fill(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                            )
                    }
                    if !message.reactions.isEmpty {
                        previewReactions
                    }
                }
                if !message.isFromMe { Spacer(minLength: 30) }
            }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        if message.deletedForEveryone {
            Text("chat.deleted".localized)
                .font(.callout.italic())
                .foregroundColor(Theme.Color.textSecondary)
        } else {
            switch message.kind {
            case .text:
                EmoticonText(text: message.text, font: .callout, emoticonSize: 18)
                    .lineLimit(8)
            case .photo:
                VStack(alignment: .leading, spacing: 4) {
                    PhotoBubble(message: message, maxWidth: 200)
                    if !message.text.isEmpty {
                        EmoticonText(text: message.text, font: .callout, emoticonSize: 16)
                            .lineLimit(4)
                    }
                }
            case .video:
                VStack(alignment: .leading, spacing: 4) {
                    VideoBubble(message: message, maxWidth: 200)
                    if !message.text.isEmpty {
                        EmoticonText(text: message.text, font: .callout, emoticonSize: 16)
                            .lineLimit(4)
                    }
                }
            case .voice:
                Text("🎤 Voice")
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
            case .poll:
                // Polls are gone (14a). The branch stays so an old poll row in
                // the long-press preview reads the same as it does in the chat,
                // and never falls through to printing its leftover payload JSON.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("chat.poll.removed".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(4)
                }
            default:
                Text(message.previewSnippet)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(8)
            }
        }
    }

    private var previewReactions: some View {
        let me = AuthService.shared.ownUIN ?? 0
        var counts: [String: Int] = [:]
        var mineSet: Set<String> = []
        for (uin, asset) in message.reactions {
            counts[asset, default: 0] += 1
            if uin == me { mineSet.insert(asset) }
        }
        let entries = counts.keys.sorted().map { (asset: $0, count: counts[$0] ?? 0, mine: mineSet.contains($0)) }
        return HStack(spacing: 4) {
            ForEach(entries, id: \.asset) { entry in
                HStack(spacing: 3) {
                    GIFImage(name: entry.asset).frame(width: 14, height: 14)
                    if entry.count > 1 {
                        Text("\(entry.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    Capsule().fill(entry.mine ? Theme.Color.accent.opacity(0.25) : Theme.Color.bgSecondary)
                )
                .overlay(
                    Capsule().stroke(entry.mine ? Theme.Color.accent : Color.clear, lineWidth: 1)
                )
            }
        }
    }
}
