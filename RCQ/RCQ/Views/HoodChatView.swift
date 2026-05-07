import SwiftUI

/// Anonymous, bucket-local public chat. Lives behind a Nearby
/// check-in: open via the "Hood Chat" entry on `NearbyView`,
/// closes when you stop checking in.
///
/// Visual contract:
///  - Permanent warning strip at the top — Hood Chat is *not*
///    end-to-end encrypted, and the banner is non-dismissible
///    so somebody scrolled five minutes deep can't forget.
///  - Title shows the live participant count for the bucket.
///  - Bubbles support reply / delete-mine / reactions through
///    the same long-press affordance as the regular chat.
///    Forward is intentionally absent — Hood is about saying a
///    thing here, not exporting it elsewhere.
///  - Tap on a bubble's nickname offers "Add as contact" since
///    the UIN is exposed (anonymous-mini-profile sheet).
struct HoodChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = HoodChatService.shared
    @StateObject private var contacts = ContactService.shared
    @State private var input: String = ""
    @State private var profileTarget: ProfileTarget?
    @State private var showEmojiPanel: Bool = false
    @State private var composerHeight: CGFloat = 36
    /// Currently long-pressed message — drives the floating
    /// action overlay. `nil` while no menu is up.
    @State private var actionTarget: HoodMessage?

    let bucket: String

    private struct ProfileTarget: Identifiable {
        let uin: Int
        let nickname: String
        let status: UserStatus
        let anonymous: Bool
        let gender: String?
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
                        senderNickname: target.uin == (AuthService.shared.ownUIN ?? -1)
                            ? "hood.you".localized
                            : target.nickname,
                        canDelete: target.uin == (AuthService.shared.ownUIN ?? -1) && !target.deleted,
                        canReply: !target.deleted,
                        onReact: { asset in
                            Task { await service.toggleReaction(messageID: target.id, asset: asset) }
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
            // Closing the view drops our active subscription so
            // the bucket_count badge ticks down for the people
            // who stayed. Without this, every other viewer kept
            // seeing us in the count until the WS itself
            // disconnected — surprising on a phone where the WS
            // can stay alive for hours.
            .onDisappear { service.leave() }
            .sheet(item: $profileTarget) { target in
                anonymousProfile(target)
                    .presentationDetents([.height(280)])
                    .presentationDragIndicator(.visible)
            }
        }
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
        // Glass + yellow tint. The translucent material picks up
        // a hint of the chat content scrolling behind so the
        // banner doesn't read as a hard slab — but the warm
        // yellow overlay keeps the "this is a warning" colour
        // signal intact.
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
            // Tap anywhere on the message scroll dismisses the
            // keyboard. Using a high-priority tap so it doesn't
            // fight with the bubble long-press; the contentShape
            // rectangle keeps empty stretches between bubbles
            // tappable too.
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
        let isMine = msg.uin == (AuthService.shared.ownUIN ?? -1)
        return HStack(alignment: .top) {
            if isMine { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 2) {
                if !isMine {
                    // Bubble byline. UIN is intentionally NOT
                    // surfaced here even in non-anonymous mode —
                    // it'd clutter the chat and is one tap away
                    // in the bottom-sheet profile when the user
                    // actually wants to send a contact request.
                    Button {
                        profileTarget = ProfileTarget(
                            uin: msg.uin,
                            nickname: msg.nickname,
                            status: msg.status,
                            anonymous: msg.anonymous,
                            gender: msg.gender
                        )
                    } label: {
                        HStack(spacing: 4) {
                            StatusIcon(status: msg.status, size: 14)
                            Text(msg.nickname)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.Color.accent)
                            GenderIcon(gender: msg.gender, size: 11)
                        }
                    }
                    .buttonStyle(.plain)
                }
                bubble(msg, isMine: isMine)
                if !msg.reactions.isEmpty {
                    reactionsRow(msg)
                }
                Text(timeLabel(msg.createdAt))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            if !isMine { Spacer(minLength: 50) }
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
                // Same emoticon-aware renderer the regular chat
                // uses, so `:)` / `;)` etc. inside Hood bodies
                // animate as GIFs instead of staying as raw text.
                EmoticonText(text: msg.body)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isMine ? Theme.Color.accent.opacity(0.18) : Theme.Color.bgSecondary)
        .cornerRadius(10)
        // Long-press opens the action overlay. Skip when the
        // bubble is already a tombstone — nothing to act on.
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

    /// Aggregated reactions strip beneath a bubble. Same shape
    /// as the regular chat: each unique asset shows its count;
    /// tapping toggles the caller's pick on that asset.
    private func reactionsRow(_ msg: HoodMessage) -> some View {
        let counts: [(String, Int, Bool)] = {
            let myKey = String(AuthService.shared.ownUIN ?? -1)
            var grouped: [String: (Int, Bool)] = [:]
            for (uinKey, asset) in msg.reactions {
                var t = grouped[asset] ?? (0, false)
                t.0 += 1
                if uinKey == myKey { t.1 = true }
                grouped[asset] = t
            }
            return grouped.map { (asset, t) in (asset, t.0, t.1) }
                .sorted { $0.0 < $1.0 }
        }()
        return HStack(spacing: 4) {
            ForEach(counts, id: \.0) { row in
                Button {
                    Task { await service.toggleReaction(messageID: msg.id, asset: row.0) }
                } label: {
                    HStack(spacing: 3) {
                        GIFImage(name: row.0).frame(width: 16, height: 16)
                        if row.1 > 1 {
                            Text("\(row.1)").font(.caption2)
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(row.2 ? Theme.Color.accent.opacity(0.25) : Theme.Color.bgSecondary)
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

    /// Same KOLOBOK palette the regular chat uses, just rendered
    /// inline without the chat-side reply-strip neighbour. Tapping
    /// an emoticon appends its text code into the composer; from
    /// there the regular `/hood/send` flow ships it as plain text.
    private var emojiPanel: some View {
        let cols = [GridItem](repeating: GridItem(.flexible(), spacing: 8), count: 8)
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(Emoticons.paletteAssets, id: \.asset) { entry in
                    Button {
                        input += entry.primaryCode
                    } label: {
                        // Render `GIFImage` unconditionally — the
                        // wrapper handles its own load/animate
                        // lifecycle. The previous `cachedImage`
                        // gate was a chicken-and-egg trap: the
                        // cache only warms when something *else*
                        // already rendered the GIF, so a clean
                        // Hood session (with no inline emoticons
                        // yet) always fell through to the text
                        // fallback.
                        GIFImage(name: entry.asset)
                            .frame(width: 28, height: 28)
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
        // UIN intentionally not rendered — see the matching
        // comment in NearbyView. Showing it would let an
        // onlooker punch it into Search and undo the whole
        // anonymous-display-name premise of Hood Chat.
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusIcon(status: target.status, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.nickname)
                            .font(.title3.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                        GenderIcon(gender: target.gender, size: 16)
                    }
                    if target.anonymous {
                        Text("hood.profile.anon".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    } else {
                        Text(String(target.uin))
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
            // Push the CTA to the bottom of the sheet so the
            // user's thumb lands on it without travel — matches
            // the iOS share-sheet idiom of "primary action at
            // the floor".
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

/// Long-press popover for a Hood Chat bubble. Same visual
/// system as `MessageActionOverlay` (no scrim, just a tappable
/// catcher; reactions strip on top, action rows below) but
/// scoped to `HoodMessage` and Hood-specific actions: no
/// forward (Hood is local-by-design), no "delete for me"
/// (everything is server-broadcast — author-side delete is the
/// only meaningful operation).
private struct HoodActionOverlay: View {
    let message: HoodMessage
    let senderNickname: String
    let canDelete: Bool
    let canReply: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private static let assets: [String] = [
        "smile", "biggrin", "shok", "cray", "good", "heart",
    ]

    var body: some View {
        let isMine = message.uin == (AuthService.shared.ownUIN ?? -1)
        return ZStack {
            // Same visible blur as the regular chat overlay.
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 10) {
                reactionsPanel
                VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                    Text(senderNickname)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                    bubblePreview
                }
                .frame(maxWidth: 280, alignment: isMine ? .trailing : .leading)
                actionsPanel.frame(width: 240)
            }
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// Stripped-down copy of the focused Hood bubble — body
    /// only. The original quote-block is intentionally NOT
    /// rendered: when you long-press a reply you're acting on
    /// *that reply*, not on whatever it was quoting, and the
    /// nested quote just made the preview balloon to full
    /// screen height for no payoff. Body itself is line-capped
    /// so a wall-of-text bubble can't take over the screen
    /// either — the original is still readable behind the
    /// scrim.
    private var bubblePreview: some View {
        let isMine = message.uin == (AuthService.shared.ownUIN ?? -1)
        return HStack {
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
            ForEach(Self.assets, id: \.self) { asset in
                Button {
                    onReact(asset)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onDismiss()
                } label: {
                    ZStack {
                        if message.reactions.values.contains(asset) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Theme.Color.accent.opacity(0.3))
                        }
                        GIFImage(name: asset).frame(width: 30, height: 30)
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
