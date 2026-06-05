import SwiftUI

/// Anonymous bucket-local public chat. Plaintext only; permanent warning banner.
struct HoodChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = HoodChatService.shared
    @StateObject private var contacts = ContactService.shared
    @State private var input: String = ""
    @State private var profileTarget: ProfileTarget?
    @State private var showEmojiPanel: Bool = false
    @State private var composerHeight: CGFloat = 36
    @State private var actionTarget: HoodMessage?

    let bucket: String

    private struct ProfileTarget: Identifiable {
        let uin: Int
        let nickname: String
        let anonymous: Bool
        var id: Int { uin }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    warningBanner
                    messageList
                    if let reply = service.replyTarget {
                        replyComposeStrip(reply)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composer
                }
                if let target = actionTarget {
                    HoodActionOverlay(
                        message: target,
                        senderNickname: isMine(target)
                            ? "hood.you".localized
                            : target.nickname,
                        canDelete: isMine(target) && !target.deleted,
                        canReply: !target.deleted,
                        onReact: { emoji in
                            Task { await service.toggleReaction(messageID: target.id, emoji: emoji) }
                        },
                        onReply: {
                            service.replyTarget = target
                        },
                        onDelete: {
                            Task { await service.delete(messageID: target.id) }
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.18)) { actionTarget = nil }
                        }
                    )
                    .zIndex(50)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("hood.title".localized)
                            .font(.headline)
                            .foregroundColor(Theme.Color.textPrimary)
                        Text(bucket)
                            .font(.caption2.monospaced())
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Color.textSecondary)
                        Text("\(service.bucketCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
            .task { await service.join(bucket: bucket) }
            // leave() drops the subscription so other viewers' bucket_count badge ticks down.
            .onDisappear { service.leave() }
            .sheet(item: $profileTarget) { target in
                anonymousProfile(target)
                    .presentationDetents([.height(280)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func isMine(_ msg: HoodMessage) -> Bool {
        guard let mine = AuthService.shared.ownUIN, let owner = msg.ownerUIN else {
            return false
        }
        return owner == mine
    }

    // MARK: - banner

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("hood.warn.title".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("hood.warn.body".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.yellow.opacity(0.15)
            }
        }
    }

    // MARK: - message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if service.messages.isEmpty {
                        emptyState.padding(.top, 40)
                    } else {
                        ForEach(service.messages) { msg in
                            messageRow(msg).id(msg.id)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
            .onChange(of: service.messages.last?.id) { _ in
                if let last = service.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .refreshable { await service.refresh() }
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundColor(Theme.Color.textSecondary)
            Text("hood.empty.title".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
            Text("hood.empty.body".localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
        }
    }

    private func messageRow(_ msg: HoodMessage) -> some View {
        let mine = isMine(msg)
        return HStack(alignment: .top) {
            if mine { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 2) {
                if !mine {
                    Button {
                        // Only meaningful if we know the UIN — anonymous
                        // messages just show a plain nickname row, no profile.
                        if let uin = msg.ownerUIN {
                            profileTarget = ProfileTarget(
                                uin: uin,
                                nickname: msg.nickname,
                                anonymous: msg.anonymous
                            )
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(msg.nickname)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.Color.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(msg.ownerUIN == nil)
                }
                bubble(msg, isMine: mine)
                if !msg.reactions.isEmpty {
                    reactionsRow(msg)
                }
                Text(timeLabel(msg.createdAt))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            if !mine { Spacer(minLength: 50) }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: HoodMessage, isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snippet = msg.replyToBody, let nick = msg.replyToNickname {
                quoteBlock(authorName: nick, snippet: snippet)
            }
            if msg.deleted {
                Text("hood.deleted".localized)
                    .font(.body.italic())
                    .foregroundColor(Theme.Color.textSecondary)
            } else {
                EmoticonText(text: msg.body)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isMine ? Theme.Color.accent.opacity(0.18) : Theme.Color.bgSecondary)
        .cornerRadius(10)
        .onLongPressGesture(minimumDuration: 0.35) {
            if !msg.deleted {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    actionTarget = msg
                }
            }
        }
    }

    private func quoteBlock(authorName: String, snippet: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Theme.Color.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(authorName)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                Text(snippet)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .background(Theme.Color.bgPrimary.opacity(0.5))
        .cornerRadius(6)
    }

    private func reactionsRow(_ msg: HoodMessage) -> some View {
        // Backend wire format: emoji -> "uin1,uin2,..." comma string.
        let myKey = String(AuthService.shared.ownUIN ?? -1)
        let rows: [(emoji: String, count: Int, mine: Bool)] = msg.reactions
            .map { (emoji, csv) in
                let uins = csv.split(separator: ",").map(String.init).filter { !$0.isEmpty }
                return (emoji: emoji, count: uins.count, mine: uins.contains(myKey))
            }
            .sorted { $0.emoji < $1.emoji }
        return HStack(spacing: 4) {
            ForEach(rows, id: \.emoji) { row in
                Button {
                    Task { await service.toggleReaction(messageID: msg.id, emoji: row.emoji) }
                } label: {
                    HStack(spacing: 3) {
                        Text(row.emoji).font(.system(size: 14))
                        if row.count > 1 {
                            Text("\(row.count)").font(.caption2)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(row.mine ? Theme.Color.accent.opacity(0.25) : Theme.Color.bgSecondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - reply strip

    private func replyComposeStrip(_ reply: HoodMessage) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Theme.Color.accent)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "hood.replying_to".localized, reply.nickname))
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                Text(HoodChatService.snippet(for: reply))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                service.replyTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.Color.bgSecondary)
    }

    // MARK: - composer

    private var composer: some View {
        VStack(spacing: 4) {
            if let err = service.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.statusBusy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
            if showEmojiPanel {
                emojiPanel
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
            HStack(alignment: .top, spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        showEmojiPanel.toggle()
                    }
                } label: {
                    Image(systemName: "face.smiling").font(.system(size: 20))
                        .foregroundColor(Theme.Color.accent)
                }
                .frame(height: 30)
                EmoticonTextField(
                    text: $input,
                    dynamicHeight: $composerHeight,
                    placeholder: "hood.composer.placeholder".localized,
                    minHeight: 36, maxHeight: 120
                )
                .frame(maxWidth: .infinity, minHeight: composerHeight, maxHeight: composerHeight)
                .animation(.easeOut(duration: 0.18), value: composerHeight)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(10)
                Button {
                    send()
                } label: {
                    Image(systemName: service.sending ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 18))
                        .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? Theme.Color.textSecondary
                                         : Theme.Color.accent)
                }
                .disabled(service.sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(height: 30)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private var emojiPanel: some View {
        // Plain unicode emoji palette — Hood reactions are stored
        // server-side as short strings, and rendering as GIF emoticons
        // would need an asset-to-emoji round trip we don't have here.
        let palette: [String] = [
            "👍", "❤️", "😂", "😮", "😢", "🔥", "👏", "🎉",
            "😎", "🤔", "😅", "🙏", "💯", "✨", "👀", "🤯",
        ]
        let cols = [GridItem](repeating: GridItem(.flexible(), spacing: 8), count: 8)
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(palette, id: \.self) { emoji in
                    Button {
                        input += emoji
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(width: 32, height: 32)
                    }
                }
            }
            .padding(8)
        }
        .frame(height: 180)
    }

    private func send() {
        let text = input
        input = ""
        Task { await service.send(text: text) }
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - anonymous profile

    @ViewBuilder
    private func anonymousProfile(_ target: ProfileTarget) -> some View {
        let alreadyContact = contacts.contacts.contains(where: { $0.uin == target.uin })
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: target.anonymous
                      ? "person.crop.circle.badge.questionmark"
                      : "person.crop.circle")
                    .font(.system(size: 36))
                    .foregroundColor(Theme.Color.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.nickname)
                        .font(.title3.bold())
                        .foregroundColor(Theme.Color.textPrimary)
                    if target.anonymous {
                        Text("hood.profile.anon".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    } else {
                        Text("#\(target.uin)")
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 36)
            .padding(.horizontal, 20)
            Text(target.anonymous
                 ? "hood.profile.body.anon".localized
                 : "hood.profile.body.real".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 20)
            Spacer()
            if alreadyContact {
                Text("hood.profile.already".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            } else {
                Button {
                    Task {
                        try? await ContactService.shared.sendAddRequest(to: target.uin)
                        profileTarget = nil
                    }
                } label: {
                    Text("hood.profile.add_contact".localized)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.Color.accent)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - HoodActionOverlay

private struct HoodActionOverlay: View {
    let message: HoodMessage
    let senderNickname: String
    let canDelete: Bool
    let canReply: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private static let emojis: [String] = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    var body: some View {
        let mine: Bool = {
            guard let me = AuthService.shared.ownUIN, let owner = message.ownerUIN else {
                return false
            }
            return me == owner
        }()
        return ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 10) {
                reactionsPanel
                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                    Text(senderNickname)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                    bubblePreview(isMine: mine)
                }
                .frame(maxWidth: 280, alignment: mine ? .trailing : .leading)
                actionsPanel.frame(width: 240)
            }
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    private func bubblePreview(isMine: Bool) -> some View {
        HStack {
            if isMine { Spacer(minLength: 0) }
            Group {
                if message.deleted {
                    Text("hood.deleted".localized)
                        .font(.body.italic())
                        .foregroundColor(Theme.Color.textSecondary)
                } else {
                    EmoticonText(text: message.body)
                        .lineLimit(6)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isMine ? Theme.Color.accent.opacity(0.18) : Theme.Color.bgSecondary)
            .cornerRadius(10)
            if !isMine { Spacer(minLength: 0) }
        }
    }

    private var reactionsPanel: some View {
        HStack(spacing: 2) {
            ForEach(Self.emojis, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onDismiss()
                } label: {
                    ZStack {
                        if message.reactions.keys.contains(emoji) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Theme.Color.accent.opacity(0.3))
                        }
                        Text(emoji).font(.system(size: 24))
                    }
                    .frame(width: 42, height: 42)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Theme.Color.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private var actionsPanel: some View {
        VStack(spacing: 0) {
            if canReply {
                row("hood.action.reply".localized, icon: "arrowshape.turn.up.left", destructive: false) {
                    onReply(); onDismiss()
                }
                if canDelete {
                    Divider().background(Theme.Color.divider)
                }
            }
            if canDelete {
                row("hood.action.delete".localized, icon: "trash", destructive: true) {
                    onDelete(); onDismiss()
                }
            }
        }
        .background(Theme.Color.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private func row(_ title: String, icon: String, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body)
                    .foregroundColor(destructive ? Theme.Color.statusBusy : Theme.Color.textPrimary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(destructive ? Theme.Color.statusBusy : Theme.Color.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
