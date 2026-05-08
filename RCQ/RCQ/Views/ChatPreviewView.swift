import SwiftUI

/// Read-only chat preview for the contextMenu `preview:` slot. Does NOT fire read receipts.
struct ChatPreviewView: View {
    let target: ChatTarget
    var compact: Bool = true

    @StateObject private var store = MessageStore.shared
    @StateObject private var contacts = ContactService.shared
    @StateObject private var groupSvc = GroupService.shared
    @State private var bottomVisible: Bool = true

    var body: some View {
        ZStack(alignment: .top) {
            messages
            if compact {
                floatingIdentity
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity)
            }
        }
        .modifier(PreviewFrame(compact: compact))
        .background(Theme.Color.bgPrimary)
    }

    @ViewBuilder
    private var floatingIdentity: some View {
        HStack(spacing: 8) {
            switch target {
            case .peer(let snapshot):
                let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
                StatusIcon(status: live.status, size: 22)
                    .floatingShadow()
                VStack(spacing: 0) {
                    Text(live.nickname)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                        .floatingShadow()
                    Text(String(live.uin))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                        .floatingShadow()
                }
                Color.clear.frame(width: 22, height: 1)
            case .group(let snapshot):
                let live = groupSvc.find(snapshot.id) ?? snapshot
                Image(systemName: "person.3.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 22, height: 22)
                    .floatingShadow()
                VStack(spacing: 0) {
                    Text(live.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                        .floatingShadow()
                    Text("\(live.members.count) member\(live.members.count == 1 ? "" : "s")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                        .floatingShadow()
                }
                Color.clear.frame(width: 22, height: 1)
            case .randomPeer:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        let thread = target.thread
        let all = store.threads[thread] ?? []
        let recent = all.suffix(50)
        if recent.isEmpty {
            VStack {
                Spacer()
                Text("chat.preview.no_messages".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
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
    func body(content: Content) -> some View {
        if compact {
            content.frame(width: 360, height: 340)
        } else {
            content
        }
    }
}

private extension View {
    func floatingShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.30), radius: 6, x: 0, y: 1)
            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
    }
}

private struct ChatPreviewBubble: View {
    let message: Message
    let senderNickname: String

    var body: some View {
        if message.kind == .systemNotice {
            HStack {
                Spacer()
                Text(message.text).font(.caption2).foregroundColor(Theme.Color.textSecondary)
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
                    bubbleBody
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius)
                                .fill(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                        )
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
            default:
                Text(message.text.isEmpty ? "Message" : message.text)
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
