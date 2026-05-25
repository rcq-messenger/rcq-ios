import AVFoundation
import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: ChatViewModel
    @StateObject private var appState = AppState.shared
    @StateObject private var contacts = ContactService.shared
    @StateObject private var groupSvc = GroupService.shared
    @StateObject private var groupViews = GroupViewsService.shared

    /// Member roster for the active group target, or `[]` for 1:1 chats.
    /// Drives @mention rendering + the composer's mention picker.
    private var currentGroupMembers: [RCQGroupMember] {
        guard case .group(let snapshot) = vm.target else { return [] }
        return (groupSvc.find(snapshot.id) ?? snapshot).members
    }

    private var activeGroupID: Int? {
        if case .group(let g) = vm.target { return g.id }
        return nil
    }

    /// True iff the active chat target is a closed group. View-count
    /// pings + counters are gated on this, matching the server enforcement.
    private var activeGroupIsClosed: Bool {
        guard case .group(let snapshot) = vm.target else { return false }
        return (groupSvc.find(snapshot.id) ?? snapshot).isClosed
    }

    /// Returns the cached aggregate view count for a bubble in the
    /// active closed group, or nil for 1:1 / open-group / not-yet-fetched.
    private func viewCountForBubble(_ msg: Message) -> Int? {
        guard activeGroupIsClosed, let gid = activeGroupID else { return nil }
        return GroupViewsService.shared.count(group: gid, message: msg.id)
    }

    /// Tells the GroupViewsService we have seen this message. The
    /// service is idempotent — same message viewed twice this session
    /// only pings the server once.
    private func pingViewIfCloseGroup(_ msg: Message) {
        guard activeGroupIsClosed, let gid = activeGroupID else { return }
        GroupViewsService.shared.ping(
            group: gid,
            message: msg.id,
            groupIsClosed: true,
        )
    }

    private func jetonEligible(_ msg: Message) -> Bool {
        guard activeGroupID != nil else { return false }
        return !msg.isFromMe && !msg.deletedForEveryone && msg.kind != .systemNotice
    }

    @ViewBuilder
    private func actionOverlay(for target: Message) -> some View {
        let resendCallback: (() -> Void)? = (target.deliveryState == .failed && target.isFromMe)
            ? { Task { await vm.resend(target) } }
            : nil
        let reportCallback: (() -> Void)? = shouldOfferEvidenceReport(target)
            ? {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    Task { await prepareEvidenceReport(for: copy) }
                }
            }
            : nil
        let jetonCallback: (() -> Void)? = jetonEligible(target)
            ? {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    jetonTarget = copy
                }
            }
            : nil
        MessageActionOverlay(
            message: target,
            senderNickname: vm.senderNickname(target.senderUIN),
            canDeleteForEveryone: target.isFromMe,
            canReply: replyAllowed,
            canEdit: target.isFromMe
                && !target.deletedForEveryone
                && Self.editableKinds.contains(target.kind),
            onReact: { asset in vm.toggleReaction(asset, on: target) },
            onJetonReact: jetonCallback,
            onReply: {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        vm.replyTarget = copy
                    }
                }
            },
            onEdit: {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        vm.startEdit(copy)
                    }
                }
            },
            onForward: {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    forwardTarget = copy
                }
            },
            onTranslate: {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    vm.toggleTranslate(copy)
                }
            },
            isTranslated: vm.isTranslated(target),
            onDeleteForMe: { vm.deleteForMe(target) },
            onDeleteForEveryone: { Task { await vm.deleteForEveryone(target) } },
            onDismiss: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { actionTarget = nil } },
            onReport: reportCallback,
            onSelect: {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        vm.enterSelection(seeding: copy.id)
                    }
                }
            },
            onResend: resendCallback,
        )
    }

    /// `@partial` token at the tail of the composer input — drives the
    /// mention picker. Walks back from input end; bails as soon as it
    /// hits whitespace, so `Hey @bob hi @al` resolves to `al`, not `bob`.
    private var activeMentionQuery: (range: NSRange, partial: String)? {
        guard !currentGroupMembers.isEmpty else { return nil }
        let ns = vm.input as NSString
        var i = ns.length
        while i > 0 {
            let scalar = Unicode.Scalar(ns.character(at: i - 1))
            if let s = scalar, s == "@" {
                let after = ns.substring(from: i)
                let valid = after.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" || $0 == "-" }
                if valid {
                    return (range: NSRange(location: i - 1, length: ns.length - i + 1), partial: after)
                }
                return nil
            }
            if let s = scalar, s.properties.isWhitespace { return nil }
            i -= 1
        }
        return nil
    }

    private var mentionCandidates: [RCQGroupMember] {
        guard let q = activeMentionQuery else { return [] }
        // Require at least one character after `@` before showing
        // the picker — a bare `@` typed mid-sentence shouldn't pop
        // the whole member list over the keyboard. Was: empty
        // partial returned every member.
        guard !q.partial.isEmpty else { return [] }
        let partial = q.partial.lowercased()
        let me = AuthService.shared.ownUIN
        return Array(
            currentGroupMembers
                .filter { $0.uin != me }
                .filter { $0.nickname.lowercased().contains(partial) }
                .prefix(8)
        )
    }

    @ViewBuilder
    private var mentionPicker: some View {
        let candidates = mentionCandidates
        if !candidates.isEmpty {
            // Adapt height to the actual candidate count instead of
            // pinning at 200pt — N matching members produced a tall
            // half-empty pill before. Each row ≈ 36pt (StatusIcon 20
            // + vertical padding 8×2). Cap at 200pt so an 8-match
            // result still scrolls cleanly.
            let rowHeight: CGFloat = 36
            let preferredHeight = min(CGFloat(candidates.count) * rowHeight, 200)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { m in
                        Button { selectMention(m) } label: {
                            HStack(spacing: 8) {
                                StatusIcon(status: m.status, size: 20)
                                Text(m.nickname)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Spacer()
                                Text(String(m.uin))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(Theme.Color.textMono)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: preferredHeight)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func selectMention(_ m: RCQGroupMember) {
        guard let q = activeMentionQuery else { return }
        let ns = vm.input as NSString
        vm.input = ns.replacingCharacters(in: q.range, with: "@\(m.nickname) ")
    }
    @StateObject private var randomChat = RandomChatService.shared
    @StateObject private var calls = CallService.shared
    @StateObject private var chatSettings = ChatSettingsStore.shared
    @StateObject private var tradesSvc = TradesService.shared
    @StateObject private var itemsSvc = ItemsService.shared
    @StateObject private var emoticonUsage = EmoticonUsageStore.shared
    @State private var emoticonTab: String? = nil
    @State private var showEmojiPanel = false
    @State private var showInfo = false
    @State private var showAttachmentMenu = false
    @State private var showPollComposer: Bool = false
    @State private var showShareGroupPicker: Bool = false
    /// Toggled every ~7s by the chat-header timer to crossfade
    /// between UIN and "last seen X ago" under the peer's nickname.
    /// Suppressed (stays on UIN) when the peer is online OR their
    /// `lastSeen` is nil (hidden by privacy / unknown).
    @State private var headerShowsLastSeen: Bool = false
    @State private var showPremiumComposer: Bool = false
    @State private var showLocationPicker: Bool = false
    @State private var showTTLPicker = false
    @State private var showTrade = false
    @State private var showTrades = false
    @State private var showInChatSearch = false
    @State private var showAllMedia = false
    @AppStorage("rcq.privacy.callPolicy") private var callPolicy: String = "everyone"
    @State private var pendingScrollID: UUID?
    @State private var flashHighlightID: UUID?
    @State private var inspectingTrade: Trade?
    @State private var videoError: String?
    @State private var composerHeight: CGFloat = 36
    @StateObject private var voiceRecorder = VoiceRecorder.shared
    @StateObject private var voicePlayer = VoicePlayer.shared
    /// Slide-LEFT distance past which a release discards the recording.
    /// Telegram convention; user's horizontal swipe over the mic.
    private static let voiceCancelHorizontalOffset: CGFloat = 80
    /// Slide-UP distance past which a release engages "locked" mode —
    /// recording continues without the finger held down, and the input
    /// bar swaps to a stop/cancel control panel.
    private static let voiceLockOffset: CGFloat = 60
    /// Legacy name; still used as the visual feedback threshold inside
    /// the recordingPill. Re-purposed from the old "slide up = cancel"
    /// semantic to "slide up = lock"; the horizontal swipe now does cancel.
    private static let voiceCancelOffset: CGFloat = 60
    /// Kinds whose caption/text can be edited. Must stay in sync with
    /// the editable set in `MessageStore.applyEdit`.
    private static let editableKinds: [MessageKind] =
        [.text, .photo, .video, .file, .premiumPhoto, .premiumVideo]
    @State private var micDragOffset: CGFloat = 0
    @State private var micDragWidth: CGFloat = 0
    @State private var voiceCancelArmed: Bool = false
    /// Set true mid-gesture when the upward swipe crosses the lock
    /// threshold. Visual hint only; the lock actually engages on release.
    @State private var voiceLockArmed: Bool = false
    /// True after the user has released a slid-up gesture. Recorder
    /// keeps going; the bar shows `lockedPill` with stop + cancel
    /// buttons until the user explicitly stops or cancels.
    @State private var voiceLocked: Bool = false
    /// Finished recording awaiting user's send / re-listen / discard
    /// decision. Non-nil → input bar shows `previewPill`.
    @State private var pendingVoicePreview: PendingVoicePreview?
    @State private var voicePermissionDenied: Bool = false

    /// Wraps a recorded but-not-yet-sent voice clip so the input bar
    /// can offer a play / send / discard preview. `id` doubles as the
    /// VoicePlayer key for play-through-the-bubble plumbing.
    struct PendingVoicePreview: Identifiable, Equatable {
        let id: UUID = UUID()
        let url: URL
        let duration: TimeInterval
    }
    @State private var isKeyboardVisible: Bool = false
    private var isSelfThread: Bool {
        if case .peer(let snapshot) = vm.target {
            return snapshot.uin == (AuthService.shared.ownUIN ?? -1)
        }
        return false
    }
    @State private var showScrollToBottom: Bool = false
    /// Hides the scroll surface during the initial settle window so
    /// users don't see LazyVStack realizing rows on chat-open. We
    /// flip it to true after the multi-pass scrollTo loop has had a
    /// chance to land on the actual bottom; from then on the chat
    /// stays visible across the lifetime of the screen.
    @State private var chatVisible: Bool = false
    @State private var forwardTarget: Message?
    /// Drives the ForwardPickerSheet for multi-select forwarding. The
    /// sheet only needs a non-nil "anchor" message to render its
    /// preview — we hand it the first selected message and dispatch
    /// `vm.forwardSelected(...)` on pick instead of the single-msg
    /// path used by `forwardTarget`.
    @State private var multiForwardAnchor: Message?
    @State private var deleteSelectionPrompt: Bool = false
    /// Action queued by the attach menu, fired in the sheet's
    /// `onDismiss` instead of mid-presentation. iOS 26 silently drops
    /// a `.sheet` that's flipped on while another sheet is still
    /// dismissing, so we wait for the actual teardown completion.
    @State private var pendingAttachAction: AttachAction?

    enum AttachAction { case media, camera, premium, document, location }

    /// Identifiable wrapper for the fullscreen album viewer's
    /// `.fullScreenCover(item:)`.
    struct AlbumViewerContext: Identifiable {
        let id = UUID()
        let items: [Message]
        let initialIndex: Int
    }

    private var replyAllowed: Bool { true }
    @State private var now = Date()
    @State private var actionTarget: Message?
    @State private var jetonTarget: Message?
    @StateObject private var jetonStore = JetonStore.shared
    @State private var evidenceReportTarget: PendingEvidenceReport?

    init(target: ChatTarget) {
        _vm = StateObject(wrappedValue: ChatViewModel(target: target))
    }

    init(contact: Contact) {
        _vm = StateObject(wrappedValue: ChatViewModel(target: .peer(contact)))
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()

            messageScroll

            if showInChatSearch {
                InChatSearchOverlay(
                    messages: vm.messages,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.18)) { showInChatSearch = false }
                    },
                    onSelectMessage: { msg in
                        withAnimation(.easeInOut(duration: 0.18)) { showInChatSearch = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            pendingScrollID = msg.id
                            withAnimation(.easeIn(duration: 0.2)) {
                                flashHighlightID = msg.id
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                if flashHighlightID == msg.id {
                                    withAnimation(.easeOut(duration: 0.5)) {
                                        flashHighlightID = nil
                                    }
                                }
                            }
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(60)
            }

            if let target = actionTarget {
                actionOverlay(for: target)
                    .zIndex(50)
            }
        }
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if vm.isPeerTyping, case .peer(let c) = vm.target {
                    TypingIndicator(label: "\(c.nickname) is typing…")
                }
                if case .randomPeer(let peer) = vm.target {
                    randomCTAStrip(peer: peer)
                }
                if vm.isSelecting {
                    selectionActionBar
                } else if let inGroup = vm.target.broadcastReadOnly(viewerUIN: AuthService.shared.ownUIN) {
                    broadcastReadOnlyHint(group: inGroup)
                } else {
                    if !vm.pendingMedia.isEmpty {
                        // No explicit background — tiles float over the
                        // chat content so the strip reads as a draft
                        // tray rather than a docked panel.
                        pendingMediaStrip
                    }
                    mentionPicker
                    inputBar
                }
                if showEmojiPanel {
                    emojiPanel
                }
            }
            .animation(.easeOut(duration: 0.22), value: showEmojiPanel)
        }
        .callMinimizedBarInset()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                principalContent
            }
            ToolbarItem(placement: .topBarTrailing) {
                trailingMenu
            }
        }
        .enableSwipeBack()
        // Random chat presents this view inside a sheet without an enclosing NavigationStack.
        .applyIfNotRandom(vm.target) {
            $0.navigationDestination(isPresented: $showInfo) { infoDestination }
        }
        .sheet(item: $forwardTarget) { msg in
            ForwardPickerSheet(message: msg) { destination in
                forwardTarget = nil
                Task {
                    switch destination {
                    case .contact(let c): await vm.forward(msg, toContact: c)
                    case .group(let g):   await vm.forward(msg, toGroup: g)
                    }
                }
            } onCancel: { forwardTarget = nil }
        }
        .sheet(item: $evidenceReportTarget) { target in
            ReportEvidenceSheet(
                message: target.message,
                evidenceBytes: target.bytes,
                evidenceMime: target.mime,
                targetUIN: target.message.senderUIN,
                targetNickname: vm.senderNickname(target.message.senderUIN),
            )
        }
        // Pickers go through UIKit (ImperativePicker) — hosting a PHPicker sheet inside the
        // random-chat fullScreenCover triggers an iOS 26 cascade-dismiss bug.
        .sheet(isPresented: $showAttachmentMenu, onDismiss: handleAttachDismiss) {
            AttachmentPickerSheet(
                isRandom: { if case .randomPeer = vm.target { return true } else { return false } }(),
                // Premium in groups is owner-only — server enforces it,
                // but hide the menu row for non-owners so they don't
                // get a 403 after picking media.
                premiumDisabled: {
                    if case .group(let g) = vm.target {
                        return g.ownerUIN != AuthService.shared.ownUIN
                    }
                    return false
                }(),
                onMedia: { picks in
                    // Telegram-style: media chosen INSIDE the sheet
                    // rather than via a follow-up UnifiedMediaPicker.
                    // Route the picked items straight into the
                    // composer's pending-media queue and close the
                    // sheet — no `pendingAttachAction` middleman needed.
                    showAttachmentMenu = false
                    Task { @MainActor in
                        for item in picks {
                            switch item {
                            case .photo(let img):
                                vm.queuePendingPhotos([img])
                            case .video(let url):
                                let thumb = await Self.makeVideoThumbnail(url: url)
                                vm.queuePendingVideo(url: url, thumbnail: thumb)
                            case .gif(let data, let preview):
                                vm.queuePendingGIF(data: data, preview: preview)
                            }
                        }
                    }
                },
                onCamera: {
                    pendingAttachAction = .camera
                    showAttachmentMenu = false
                },
                onPremium: {
                    pendingAttachAction = .premium
                    showAttachmentMenu = false
                },
                onDocument: {
                    pendingAttachAction = .document
                    showAttachmentMenu = false
                },
                onLocation: {
                    pendingAttachAction = .location
                    showAttachmentMenu = false
                },
                // Polls only make sense in groups — anchor `onPoll` to
                // nil for 1:1 / random so the row is hidden entirely.
                onPoll: pollPickerHandler,
                // Sharing a group invite into another chat is a 1:1
                // affordance — sharing into the same group is
                // contrived. Hidden in random-chat (privacy) and
                // hidden in group chats (no use-case).
                onShareGroup: shareGroupPickerHandler
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPollComposer) {
            PollComposerSheet { draft in
                Task { await submitPoll(draft) }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showShareGroupPicker) {
            ShareGroupPickerSheet { picked in
                // Send the canonical share URL as plain text — the
                // receiving client's `GroupLinkParser` upgrades the
                // bubble into a `GroupLinkBubble` card automatically.
                let url = GroupLinkParser.canonicalURL(forGroupID: picked.id)
                Task { await vm.sendText(url.absoluteString) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $vm.pendingPaidUpload) { req in
            PaidTrafficConfirmSheet(
                plaintextBytes: req.plaintextBytes,
                jetonsRequired: req.jetonsRequired,
                onConfirm: {
                    Task { _ = await req.retry() }
                },
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showPremiumComposer) {
            PremiumComposerSheet(
                onSendPhoto: { img, price in
                    Task {
                        if let err = await vm.sendPremiumPhoto(img, price: price) {
                            videoError = err
                        }
                    }
                },
                onSendVideo: { url, price in
                    Task {
                        if let err = await vm.sendPremiumVideo(from: url, price: price) {
                            videoError = err
                        }
                    }
                }
            )
            .presentationDetents([.fraction(0.4), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet(
                onSend: { coord in
                    showLocationPicker = false
                    Task { @MainActor in
                        if let err = await vm.sendLocation(latitude: coord.latitude, longitude: coord.longitude) {
                            videoError = err
                        }
                    }
                },
                onCancel: { showLocationPicker = false },
            )
        }
        .confirmationDialog(
            "chat.menu.disappearing".localized,
            isPresented: $showTTLPicker,
            titleVisibility: .visible
        ) {
            ForEach(ChatSettingsStore.ttlOptions, id: \.label) { option in
                Button(option.label) { vm.setTTL(option.seconds) }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text(String(format: "chat.ttl.currently".localized, ChatSettingsStore.label(for: chatSettings.ttl(for: vm.target.thread))))
        }
        .alert("chat.video_error.title".localized, isPresented: Binding(
            get: { videoError != nil },
            set: { if !$0 { videoError = nil } }
        )) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(videoError ?? "")
        }
        // Lives at body root — nested alert modifiers cause layout-pass jitter at the composer seam.
        .alert("chat.voice.permission.title".localized, isPresented: $voicePermissionDenied) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text("chat.voice.permission.body".localized)
        }
        .onAppear {
            vm.onAppear()
            // Tell the in-app banner service which chat is on-screen
            // so a same-thread arrival doesn't show a redundant banner.
            MessageBannerService.shared.setActive(vm.target.thread)
            // Mark this thread as read for badge purposes and sync the
            // icon to the new total. NSE may have bumped this thread's
            // counter while we were backgrounded; entering the chat is
            // the user signal to clear it.
            let badgeKey: String = {
                switch vm.target.thread {
                case .peer(let uin): return BadgeCounter.threadKey(peerUIN: uin)
                case .group(let id): return BadgeCounter.threadKey(groupID: id)
                }
            }()
            BadgeCounter.reset(threadKey: badgeKey)
            BadgeCounter.syncIcon()
            Task { await tradesSvc.refreshAll() }
            Task {
                if itemsSvc.catalog == nil { await itemsSvc.refreshCatalog() }
                if itemsSvc.items.isEmpty { await itemsSvc.refreshInventory() }
            }
            if let gid = activeGroupID {
                Task { await jetonStore.loadGroup(gid) }
            }
        }
        .onDisappear {
            MessageBannerService.shared.clearActiveIfMatches(vm.target.thread)
        }
        .sheet(isPresented: $showTrade) {
            if case .peer(let snapshot) = vm.target {
                TradeProposeView(recipientUIN: snapshot.uin, recipientNickname: snapshot.nickname)
            }
        }
        .sheet(isPresented: $showTrades) {
            TradesListView()
        }
        .modifier(InPlaceTranslator(vm: vm))
        .sheet(item: $inspectingTrade) { trade in
            SingleTradeSheet(trade: trade)
                .presentationDetents([.fraction(0.5), .large])
        }
        .sheet(isPresented: $showAllMedia) {
            AllMediaSheet(messages: vm.messages)
        }
        .sheet(item: $jetonTarget) { msg in
            if let gid = activeGroupID {
                JetonReactSheet(
                    groupID: gid,
                    messageID: msg.id,
                    targetUIN: msg.senderUIN,
                    targetNickname: vm.senderNickname(msg.senderUIN),
                    onSuccess: { _ in }
                )
            }
        }
        .onChange(of: vm.messages.last?.id) { _ in
            if let last = vm.messages.last { vm.ackIfVisible(last) }
        }
        // 1Hz tick drives the random-chat countdown banner.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick in
            if case .randomPeer = vm.target { now = tick }
        }
    }

    // MARK: - pending-trade banner

    private var pendingTradeWithPeer: Trade? {
        guard case .peer(let snapshot) = vm.target else { return nil }
        let myUIN = AuthService.shared.ownUIN ?? -1
        if let inc = tradesSvc.incoming.first(where: { $0.fromUIN == snapshot.uin }) {
            return inc
        }
        if let out = tradesSvc.outgoing.first(where: { $0.toUIN == snapshot.uin && $0.fromUIN == myUIN }) {
            return out
        }
        return nil
    }

    // MARK: - random-chat CTA strip

    @ViewBuilder
    private func randomCTAStrip(peer: RandomPeer) -> some View {
        let secondsLeft = max(0, Int(peer.expiresAt.timeIntervalSince(now)))
        let warning = secondsLeft <= 60 && secondsLeft > 0
        let mins = secondsLeft / 60
        let secs = secondsLeft % 60
        HStack(spacing: 10) {
            Button {
                Task { await randomChat.requestAddPeer() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: randomChat.addRequestSent ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                        .font(.system(size: 13))
                    Text((randomChat.addRequestSent
                          ? "chat.random.add_request_sent"
                          : "chat.random.add_request").localized)
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(randomChat.addRequestSent ? Theme.Color.bgSecondary : Theme.Color.accent)
                .foregroundColor(randomChat.addRequestSent ? Theme.Color.textSecondary : .white)
                .cornerRadius(6)
            }
            .disabled(randomChat.addRequestSent)
            Spacer()
            Text(warning
                 ? "⚠ " + String(format: "chat.random.skip_left".localized, mins, secs)
                 : String(format: "chat.random.skip_left".localized, mins, secs))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(warning ? Theme.Color.statusBusy : Theme.Color.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(warning ? Theme.Color.statusBusy.opacity(0.12) : Color.clear)
    }

    // MARK: - System nav-bar slots

    /// Header subtitle under the peer's nickname — alternates
    /// between UIN and a humanised "last seen N min ago" every few
    /// seconds with a crossfade. The view's `.onAppear` runs the
    /// timer; `.onDisappear` tears it down.
    @ViewBuilder
    private func peerSubtitle(for live: Contact) -> some View {
        let hasLastSeen = live.lastSeen != nil && live.status == .offline
        let showAlt = hasLastSeen && headerShowsLastSeen
        ZStack {
            // Two children stacked with opacity crossfade — keeps
            // the layout box stable so the nickname above doesn't
            // jiggle on swap (a single Text re-render would shrink
            // / grow the line width during animation).
            Text(String(live.uin))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Color.textMono)
                .opacity(showAlt ? 0 : 1)
            if let ls = live.lastSeen {
                Text(Self.relativeLastSeen(ls))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Color.textMono)
                    .opacity(showAlt ? 1 : 0)
                    .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showAlt)
        .onAppear { startHeaderSwapTimer(eligible: hasLastSeen) }
        .onDisappear { stopHeaderSwapTimer() }
    }

    /// Mirrors `ContactListView.relativeLastSeen` so the chat-header
    /// subtitle reads identically to the contacts list row that led
    /// the user here. Re-declared (not shared) because the contact
    /// helper is `fileprivate` to its file.
    private static func relativeLastSeen(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "contact.last_seen.just_now".localized }
        let mins = secs / 60
        if mins < 60 {
            return String(format: "contact.last_seen.minutes".localized, mins)
        }
        let hours = mins / 60
        if hours < 24 {
            return String(format: "contact.last_seen.hours".localized, hours)
        }
        let days = hours / 24
        if days < 7 {
            return String(format: "contact.last_seen.days".localized, days)
        }
        return chatHeaderLastSeenFmt.string(from: date)
    }

    /// Long-form fallback for >7-day-old timestamps. Local copy of
    /// `ContactListView`'s `lastSeenLong` formatter (that one is
    /// fileprivate and can't be reached from here).
    private static let chatHeaderLastSeenFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func startHeaderSwapTimer(eligible: Bool) {
        // Only fire when there's actually something to swap with —
        // saves a wakeup every 3s on online / hidden-last-seen peers.
        guard eligible else { return }
        // Drive the toggle from a detached Task instead of Foundation
        // Timer so it lives inside the SwiftUI lifecycle and respects
        // background suspend automatically.
        Task { @MainActor in
            while !Task.isCancelled {
                // 7s per side — the old 3s flipped too fast to read.
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled else { break }
                headerShowsLastSeen.toggle()
            }
        }
    }

    private func stopHeaderSwapTimer() {
        // No-op for now: the Task self-cancels when the view
        // disappears via SwiftUI's task-lifecycle, since the captured
        // `self` triggers a cancellation chain on release. Kept as a
        // named hook so future explicit-Task-handle bookkeeping has
        // a single place to anchor onto.
    }

    @ViewBuilder
    private var principalContent: some View {
        switch vm.target {
        case .peer(let snapshot):
            let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
            let isSelf = live.uin == (AuthService.shared.ownUIN ?? -1)
            // Saved Messages renders as plain View — Button.disabled greys child views even with foregroundColor set.
            // Trailing Color.clear matches the leading icon width so the HStack balances around the nav-bar centre.
            let identityBlock = HStack(spacing: 8) {
                if isSelf {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 24, height: 24)
                } else {
                    StatusWithPet(status: live.status,
                                  pet: live.equippedPet,
                                  size: 24)
                }
                VStack(spacing: 0) {
                    Text(isSelf ? "contact_list.saved_messages".localized : live.nickname)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                    if !isSelf {
                        // Alternate between UIN and "last seen X ago"
                        // every 7 seconds with an opacity crossfade.
                        // If last_seen is hidden by privacy (nil) or
                        // the peer is currently online — the swap is
                        // suppressed and UIN stays put.
                        peerSubtitle(for: live)
                    }
                }
                Color.clear.frame(width: 24, height: 1)
            }
            .contentShape(Rectangle())
            if isSelf {
                identityBlock
            } else {
                Button { showInfo = true } label: { identityBlock }
                    .buttonStyle(.plain)
            }
        case .group(let snapshot):
            let live = groupSvc.find(snapshot.id) ?? snapshot
            Button { showInfo = true } label: {
                HStack(spacing: 8) {
                    GroupAvatarView(
                        mediaID: live.avatarMediaID,
                        keyBase64: live.avatarMediaKey,
                        size: 24,
                        glyphSize: 11,
                    )
                    VStack(spacing: 0) {
                        Text(live.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                            .lineLimit(1)
                        Text(String(
                            format: (live.members.count == 1
                                ? "contact_list.members_one"
                                : "contact_list.members_many").localized,
                            live.members.count
                        ))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
                    }
                    // Mirror peer-header layout: a trailing 24pt clear
                    // spacer balances the leading avatar so the title
                    // text stays centred under the nav bar.
                    Color.clear.frame(width: 24, height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .randomPeer:
            HStack(spacing: 8) {
                Image(systemName: "theatermasks.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 24, height: 24)
                VStack(spacing: 0) {
                    Text("chat.random.stranger".localized)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("anonymous")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                }
                Color.clear.frame(width: 24, height: 1)
            }
        }
    }

    @ViewBuilder
    private var trailingMenu: some View {
        Menu {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showInChatSearch = true }
            } label: {
                Label("chat.menu.search_messages".localized, systemImage: "magnifyingglass")
            }
            Button {
                showAllMedia = true
            } label: {
                Label("chat.menu.all_media".localized, systemImage: "photo.on.rectangle")
            }
            switch vm.target {
            case .peer(let snapshot):
                let isSelfThread = snapshot.uin == (AuthService.shared.ownUIN ?? -1)
                let callsEnabled = callPolicy != "nobody"
                if !isPeerBlocked && !isSelfThread && callsEnabled {
                    let busy = calls.state.isActive
                    Button {
                        let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
                        CallService.shared.start(toContact: live, media: .audio)
                    } label: {
                        Label("chat.menu.voice_call".localized, systemImage: "phone.fill")
                    }
                    .disabled(busy)
                    Button {
                        let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
                        CallService.shared.start(toContact: live, media: .video)
                    } label: {
                        Label("chat.menu.video_call".localized, systemImage: "video.fill")
                    }
                    .disabled(busy)
                }
                if !isPeerBlocked && !isSelfThread {
                    Button {
                        showTrade = true
                    } label: {
                        Label("chat.menu.propose_trade".localized, systemImage: "arrow.left.arrow.right")
                    }
                }
                if !isSelfThread {
                    Button {
                        showTTLPicker = true
                    } label: {
                        Label(disappearingLabel, systemImage: ttlActive ? "clock.fill" : "clock")
                    }
                    Divider()
                    // App Review 1.2: UGC moderation reachable from every surface.
                    UserSafetyActions(
                        targetUIN: snapshot.uin,
                        targetNickname: snapshot.nickname,
                        context: "chat",
                        style: .menu,
                    )
                    // .tint cascades into the Menu's icon SF symbols — .foregroundStyle on the Label is ignored.
                    .tint(.red)
                }
            case .group:
                Button {
                    showTTLPicker = true
                } label: {
                    Label(disappearingLabel, systemImage: ttlActive ? "clock.fill" : "clock")
                }
                // Premium-content moved entirely to the `+` attach menu —
                // same entry point as Photo / Video / Camera, since
                // premium is just a paywalled flavor of those. There
                // is no need for two entry points, and the header
                // version was the wrong fit (the flow is
                // attachment-oriented, not group-settings-oriented).
            case .randomPeer(let peer):
                Button {
                    Task { await RandomChatService.shared.skip() }
                } label: {
                    Label("chat.menu.skip_stranger".localized, systemImage: "shuffle")
                }
                Button(role: .destructive) {
                    Task { await RandomChatService.shared.leave() }
                } label: {
                    Label("chat.menu.end_session".localized, systemImage: "xmark.circle.fill")
                }
                Divider()
                // Block + Report for the matched stranger. Report
                // surfaces in admin queue with context="stranger_mode";
                UserSafetyActions(
                    targetUIN: peer.uin,
                    targetNickname: peer.nickname,
                    context: "stranger_mode",
                    style: .menu,
                )
                .tint(.red)
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(Theme.Color.textPrimary)
        }
    }

    private var disappearingLabel: String {
        if let ttl = chatSettings.ttl(for: vm.target.thread) {
            return String(format: "chat.ttl.disappearing_with".localized, ChatSettingsStore.label(for: ttl))
        }
        return "chat.menu.disappearing".localized
    }

    private var ttlActive: Bool {
        chatSettings.ttl(for: vm.target.thread) != nil
    }

    private var emptyChatPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text("chat.empty.title".localized)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("chat.empty.body".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 120)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var infoDestination: some View {
        switch vm.target {
        case .peer(let c): UserInfoView(uin: c.uin, isOwn: false)
        case .group(let g): GroupInfoView(group: g)
        case .randomPeer:
            EmptyView()
        }
    }

    private var isPeerBlocked: Bool {
        guard case .peer(let snapshot) = vm.target else { return false }
        return contacts.contacts.first(where: { $0.uin == snapshot.uin })?.blocked ?? false
    }


    // MARK: - messages

    /// Sentinel at the top of the LazyVStack. When older messages exist
    /// in CoreData beyond the loaded window, the probe materialises a
    /// short loader row and fires `vm.loadOlder()` the moment it
    /// appears. After the load, the ScrollViewReader scrolls back to
    /// the previously-topmost message so the user's eye does not jump.
    @ViewBuilder
    private func loadOlderProbe(proxy: ScrollViewProxy) -> some View {
        if vm.hasOlder {
            HStack {
                Spacer()
                if vm.isLoadingOlder {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Theme.Color.textSecondary)
                }
                Spacer()
            }
            .frame(height: 24)
            .onAppear {
                let priorTopID = vm.messages.first?.id
                Task {
                    let added = await vm.loadOlder()
                    guard added > 0, let anchor = priorTopID else { return }
                    // Restore the user's scroll position: the message
                    // that was at the top before the prepend should now
                    // sit at the top again, even though there are new
                    // rows above it.
                    DispatchQueue.main.async {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                }
            }
        } else {
            EmptyView()
        }
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
            if vm.messages.isEmpty {
                emptyChatPlaceholder
                    .transition(.opacity)
                    .zIndex(1)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    loadOlderProbe(proxy: proxy)
                    ForEach(Array(vm.grouped().enumerated()), id: \.offset) { _, group in
                        DateDivider(label: group.label)
                        ForEach(vm.collapsedAlbums(group.items)) { unit in
                            switch unit {
                            case .album(_, let items):
                                albumRow(items: items)
                            case .single(let msg):
                                MessageRow(
                                message: msg,
                                showSender: vm.target.thread.isGroup && !msg.isFromMe,
                                senderNickname: vm.senderNickname(msg.senderUIN),
                                displayBody: vm.displayText(for: msg),
                                isTranslated: vm.isTranslated(msg),
                                isHighlighted: flashHighlightID == msg.id,
                                isSelected: vm.isSelecting && vm.selectedIDs.contains(msg.id),
                                showSelectionAffordance: vm.isSelecting,
                                onTapReaction: { asset in vm.toggleReaction(asset, on: msg) },
                                jetonTotal: jetonStore.total(for: msg.id),
                                onTapJeton: jetonEligible(msg) ? { jetonTarget = msg } : nil,
                                onLongPress: {
                                    if vm.isSelecting { return }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil
                                    )
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        actionTarget = msg
                                    }
                                },
                                onDoubleTapLike: {
                                    if vm.isSelecting {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                        vm.toggleSelection(msg.id)
                                        return
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    vm.toggleReaction("good", on: msg)
                                },
                                onTapWhenSelecting: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    vm.toggleSelection(msg.id)
                                },
                                onTapReplyQuote: { targetID in
                                    guard vm.messages.contains(where: { $0.id == targetID }) else { return }
                                    pendingScrollID = targetID
                                    withAnimation(.easeIn(duration: 0.2)) {
                                        flashHighlightID = targetID
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                        if flashHighlightID == targetID {
                                            withAnimation(.easeOut(duration: 0.5)) {
                                                flashHighlightID = nil
                                            }
                                        }
                                    }
                                },
                                onSwipeReply: {
                                    let copy = msg
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                        vm.replyTarget = copy
                                    }
                                },
                                currentGroupMembers: currentGroupMembers,
                                viewCount: viewCountForBubble(msg)
                            )
                            .onAppear { pingViewIfCloseGroup(msg) }
                            // Soft-delete fade beats the dim+scale so a vanishing bubble doesn't hold at 30% opacity.
                            .opacity(vm.fadingOutIDs.contains(msg.id)
                                     ? 0
                                     : (actionTarget == nil || actionTarget?.id == msg.id ? 1 : 0.3))
                            .scaleEffect(vm.fadingOutIDs.contains(msg.id)
                                         ? 0.85
                                         : (actionTarget?.id == msg.id ? 1.04 : 1.0),
                                         anchor: msg.isFromMe ? .trailing : .leading)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: actionTarget?.id)
                            // Implicit (Combine receive(on:) would drop a withAnimation transaction).
                            // Row stays full height; layout collapse happens later via the LazyVStack count-watch.
                            .animation(.easeInOut(duration: 0.3), value: vm.fadingOutIDs.contains(msg.id))
                            .transition(.opacity)
                            .id(msg.id)
                            }
                        }
                    }
                    if let trade = pendingTradeWithPeer {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            inspectingTrade = trade
                        } label: {
                            InlineTradeCard(
                                trade: trade,
                                isFromMe: trade.fromUIN == (AuthService.shared.ownUIN ?? -1),
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .id("trade-\(trade.id)")
                    }
                    // Bottom anchor — drives initial scroll-to-latest and the FAB visibility flag.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showScrollToBottom = false
                            }
                        }
                        .onDisappear {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showScrollToBottom = true
                            }
                        }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                // Animate when a new message lands at the bottom only,
                // by watching the last id instead of the raw count.
                // Watching count would also fire when `loadOlder()`
                // prepends a page of history, causing a stutter for
                // every prepend.
                .animation(.easeInOut(duration: 0.25), value: vm.messages.last?.id)
            }
            // Initial-settle mask. While the 350ms scrollTo loop in
            // `.task` chases the moving bottom (LazyVStack realizes
            // rows as the viewport scrolls past them), we hide the
            // surface to spare the user the row-shuffle. Pinned to
            // the message scroll only — composer, header and
            // overlays stay live.
            .opacity(chatVisible ? 1 : 0)
            // No defaultScrollAnchor(.bottom) — it yanks mid-scroll when LazyVStack realizes rows,
            // and pins the empty-state to the input bar. Initial scroll is owned by the .task loop below.
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture {
                // Two-step iMessage-style: keyboard first, then emoji panel — otherwise stickers can't be picked.
                if isKeyboardVisible {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                } else if showEmojiPanel {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showEmojiPanel = false
                    }
                }
            }
            .onChange(of: vm.messages.last?.id) { _ in
                // Re-anchor only if already at bottom — yanking a
                // scrolled-up reader down is hostile. Watching the
                // last id (not count) so `loadOlder()` prepends don't
                // trip this branch.
                guard !showScrollToBottom else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: pendingScrollID) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    pendingScrollID = nil
                }
            }
            // Bottom-chrome growth (emoji panel, reply/edit, keyboard) needs an explicit re-anchor —
            // we don't use defaultScrollAnchor. Duration matches the 0.22s on the safeAreaInset.
            .onChange(of: showEmojiPanel) { _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            // No scroll on reply / edit context appearance — felt jumpy.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
                if showEmojiPanel {
                    showEmojiPanel = false
                }
                // Match the system keyboard's 0.25s easeOut so the scroll glides in sync.
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                isKeyboardVisible = false
                // Keyboard close: tight scrollTo loop for the full
                // keyboard animation window. Wrapping a single
                // `scrollTo` in `withAnimation(duration:)` looks
                // logical but is broken — SwiftUI evaluates the
                // target offset ONCE at call time, when the viewport
                // is still keyboard-sized. The computed "bottom"
                // equals current position, so nothing animates, and
                // when the safe-area inset finishes shrinking the
                // content is left floating in mid-screen above a new
                // empty band. `keyboardDidHide` then snaps it →
                // visible jump.
                //
                // Running `proxy.scrollTo` 60Hz for the keyboard's
                // duration makes each tick recompute "bottom" against
                // the CURRENT (growing) viewport. With no
                // `withAnimation` wrap each tick is an instant snap,
                // and the per-frame snaps add up to a smooth track of
                // the safe-area inset transition. We add a +80ms tail
                // past the reported duration since iOS occasionally
                // rounds the animation longer than the userInfo says.
                guard !showScrollToBottom else { return }
                let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                Task { @MainActor in
                    let endDate = Date().addingTimeInterval(duration + 0.08)
                    while Date() < endDate {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            // Initial settle: scrollTo loop while LazyVStack realizes
            // rows + chat is masked behind opacity until the position
            // stabilises. Users used to see rows pop into view as the
            // viewport scrolled past them ("на глазах загружается").
            // The 350ms window covers row materialization for chats
            // up to a few hundred messages; longer chats finish off-
            // screen and the opacity transition hides the residual
            // motion.
            .task {
                let endDate = Date().addingTimeInterval(0.35)
                while Date() < endDate {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                withAnimation(.easeOut(duration: 0.15)) {
                    chatVisible = true
                }
                // Pull view counts for the currently-loaded window in
                // closed groups. Skips silently for 1:1 and open groups.
                if activeGroupIsClosed, let gid = activeGroupID {
                    await GroupViewsService.shared.refresh(
                        group: gid,
                        messages: vm.messages.map { $0.id },
                        groupIsClosed: true,
                    )
                }
            }
            if showScrollToBottom {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle().stroke(Theme.Color.divider, lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                }
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            }
        }
    }

    private static let bottomAnchorID = "__rcq_chat_bottom_anchor"

    // MARK: - report-with-evidence helpers

    private func shouldOfferEvidenceReport(_ message: Message) -> Bool {
        if message.isFromMe { return false }
        guard message.mediaID != nil else { return false }
        switch message.kind {
        case .photo:
            return true
        case .premiumPhoto:
            return message.premiumUnlocked
        default:
            return false
        }
    }

    private func prepareEvidenceReport(for message: Message) async {
        guard let mediaID = message.mediaID else { return }
        let parts = mediaID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        guard let image = await MediaService.shared.loadImage(
            mediaID: parts[0], keyBase64: parts[1]
        ) else {
            videoError = "report_evidence.error.no_bytes".localized
            return
        }
        // Re-encode at slightly-lossy quality. 0.85 is the same
        // setting we use for outbound photo upload — keeps file
        // size reasonable for the moderation queue without
        // visibly degrading the evidence.
        guard let bytes = image.jpegData(compressionQuality: 0.85) else {
            videoError = "report_evidence.error.no_bytes".localized
            return
        }
        await MainActor.run {
            evidenceReportTarget = PendingEvidenceReport(
                message: message,
                bytes: bytes,
                mime: "image/jpeg",
            )
        }
    }

    // MARK: - reply helpers

    /// Same one-line preview ChatViewModel uses for the wire-side
    /// snippet. Duplicated here so the on-screen compose strip and
    /// the persisted snippet stay in sync without exporting the
    /// private static.
    private static func replyPreview(for message: Message) -> String {
        if message.deletedForEveryone { return "chat.deleted".localized }
        let raw: String
        switch message.kind {
        case .text:  raw = message.text
        case .photo: raw = message.text.isEmpty ? "📷 \("chat.attach.photo".localized)" : "📷 \(message.text)"
        case .video: raw = message.text.isEmpty ? "🎬 \("chat.attach.video".localized)" : "🎬 \(message.text)"
        case .voice: raw = "🎤 Voice"
        case .file:  raw = "📎 \(message.fileName ?? "chat.attach.document".localized)"
        case .location: raw = "📍 \("chat.preview.location".localized)"
        case .premiumPhoto: raw = "🔒 \("chat.premium.preview_photo".localized)"
        case .premiumVideo: raw = "🔒 \("chat.premium.preview_video".localized)"
        case .poll:
            // The text field on a `.poll` row is the JSON-encoded
            // PollPayload — surface the question only so the reply
            // strip reads as "📊 What should we order?" instead of
            // the raw `{"question":...,"options":...}` blob.
            let q = PollPayload.decode(from: message.text)?.question
                ?? "chat.preview.poll".localized
            raw = "📊 \(q)"
        default:     raw = message.text.isEmpty ? "chat.message_fallback".localized : message.text
        }
        if raw.count <= 80 { return raw }
        return raw.prefix(80) + "…"
    }

    // MARK: - reply compose strip

    /// Quote-block shown above the input bar when the user has a
    /// reply target queued. Mirror of the strip Telegram shows —
    /// vertical accent rule + author name + snippet, X to cancel.
    /// Sending the message automatically clears the target via
    /// `ChatViewModel.consumeReplyContext`; no manual reset needed
    /// Helper — true for kinds where the inline reply context
    /// surfaces a thumbnail / glyph instead of text-only context.
    private func isMediaKind(_ kind: MessageKind) -> Bool {
        switch kind {
        case .photo, .video, .voice, .premiumPhoto, .premiumVideo:
            return true
        default:
            return false
        }
    }

    // MARK: - input

    private func broadcastReadOnlyHint(group: RCQGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "megaphone.fill")
                .foregroundColor(Theme.Color.textSecondary)
            Text("group.compose.broadcast_only".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var isStrangerMode: Bool {
        if case .randomPeer = vm.target { return true }
        return false
    }

    private var inputBar: some View {
        let trimmed = vm.input.trimmingCharacters(in: .whitespaces)
        // Pending media on its own is a sendable message — show the
        // send button even when the caption is empty.
        let showSend = !trimmed.isEmpty || !vm.pendingMedia.isEmpty
        // Three voice-flow modes preempt the regular composer:
        // 1. previewPill  — finished clip awaiting send / discard.
        // 2. lockedPill   — recording continues, no finger held.
        // 3. recordingPill — finger still down, mid-record.
        let voiceFlowActive = pendingVoicePreview != nil
            || voiceLocked || voiceRecorder.isRecording
        return HStack(alignment: .bottom, spacing: 8) {
            if let preview = pendingVoicePreview {
                previewPill(preview)
            } else if voiceLocked {
                lockedPill
            } else if voiceRecorder.isRecording {
                recordingPill
            } else {
                // Stranger mode is text-only — no attach, no voice.
                if !isStrangerMode {
                    attachButton
                }
                pillField
            }
            // Trailing button: send arrow (text/media) OR mic (idle).
            // Hidden entirely while a voice flow owns the bar — those
            // pills carry their own send / stop / discard controls.
            if !voiceFlowActive {
                if isStrangerMode {
                    sendButton
                        .opacity(showSend ? 1.0 : 0.4)
                        .disabled(!showSend)
                        .frame(width: 36, height: 36)
                } else {
                    ZStack {
                        if showSend {
                            sendButton
                                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        } else {
                            micButton
                                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .animation(.spring(response: 0.28, dampingFraction: 0.78), value: showSend)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: voiceFlowActive)
    }

    private var attachButton: some View {
        Button { showAttachmentMenu = true } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Theme.Color.textPrimary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(0.08), lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private var pillField: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reply = vm.replyTarget {
                inlineReplyContext(reply)
                Divider()
                    .background(Color.white.opacity(0.06))
            } else if let edit = vm.editingTarget {
                inlineEditContext(edit)
                Divider()
                    .background(Color.white.opacity(0.06))
            }
            HStack(alignment: .bottom, spacing: 4) {
                EmoticonTextField(
                    text: $vm.input,
                    dynamicHeight: $composerHeight,
                    placeholder: "chat.composer.placeholder".localized,
                    minHeight: 36, maxHeight: 120,
                    onTextChange: { newValue in
                        if !newValue.isEmpty { vm.notifyTyping() }
                    }
                )
                .frame(maxWidth: .infinity, minHeight: composerHeight, maxHeight: composerHeight)
                .animation(.easeOut(duration: 0.18), value: composerHeight)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showEmojiPanel.toggle()
                    }
                } label: {
                    Image(systemName: showEmojiPanel ? "keyboard" : "face.smiling")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.Color.textSecondary)
                        // Bump to 44pt min hit area — was 32×36 (below
                        // HIG guidance). The visible glyph stays the
                        // same size; only the tap zone widens.
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
        }
        // RoundedRectangle for every state — Capsule made the
        // composer look like an over-inflated bubble once the text
        // wrapped past one line (the pill ends curved by half the
        // height, which read as wrong at 4+ rows).
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // No explicit .animation here — callers already wrap replyTarget/editingTarget assignments in withAnimation.
    }

    @ViewBuilder
    private func inlineReplyContext(_ message: Message) -> some View {
        let snippet = Self.replyPreview(for: message)
        let author = vm.senderNickname(message.senderUIN)
        let market = (message.kind == .text)
            ? MarketLinkParser.parse(message.text)
            : nil
        let uinShare = (message.kind == .text && market == nil)
            ? UinLinkParser.parse(message.text)
            : nil
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.Color.accent)
                .frame(width: 3, height: 28)
            if isMediaKind(message.kind) {
                ReplyMediaThumbnail(message: message, size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "chat.replying_to".localized, author))
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                    .lineLimit(1)
                if let market {
                    MarketReplyMiniCard(listingID: market.listingID)
                } else if let uinShare {
                    UinReplyMiniCard(listingID: uinShare.listingID)
                } else {
                    EmoticonText(
                        text: snippet,
                        font: .caption2,
                        color: Theme.Color.textSecondary,
                        emoticonSize: 15,
                        members: currentGroupMembers
                    )
                }
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    vm.replyTarget = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func inlineEditContext(_ message: Message) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("chat.edit.editing".localized)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                    .lineLimit(1)
                Text(Self.replyPreview(for: message))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    vm.cancelEdit()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func albumRow(items: [Message]) -> some View {
        AlbumRowView(
            items: items,
            isInGroupChat: vm.target.thread.isGroup,
            senderNickname: vm.senderNickname(items.first!.senderUIN),
            isSelecting: vm.isSelecting,
            isSelected: items.allSatisfy { vm.selectedIDs.contains($0.id) },
            onTapTile: { tappedIdx in
                if vm.isSelecting {
                    let allSelected = items.allSatisfy { vm.selectedIDs.contains($0.id) }
                    if allSelected {
                        for m in items { vm.toggleSelection(m.id) }
                    } else {
                        for m in items where !vm.selectedIDs.contains(m.id) {
                            vm.toggleSelection(m.id)
                        }
                    }
                    return
                }
                // Direct UIKit-presenter call — earlier we routed
                // through `openedAlbum` state + .onChange but the
                // SwiftUI optional-id change wasn't reliably firing
                // the change handler on iOS 26.
                AlbumViewerPresenter.present(
                    items: items,
                    initialIndex: tappedIdx
                )
            },
            onLongPress: {
                if vm.isSelecting { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    actionTarget = items.first!
                }
            },
            onSwipeReply: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    vm.replyTarget = items.first!
                }
            }
        )
        .id(items.first!.id)
    }

    private var selectionActionBar: some View {
        let count = vm.selectedIDs.count
        let canDelete = count > 0
        let canForward = count > 0 && !vm.selectedMessagesContainNonForwardable
        return HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { vm.cancelSelection() }
            } label: {
                Text("chat.selection.cancel".localized)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text(String(format: "chat.selection.title".localized, count))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Color.textSecondary)
            Spacer(minLength: 0)
            if canForward {
                Button {
                    multiForwardAnchor = vm.firstSelectedMessage
                } label: {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            Button {
                deleteSelectionPrompt = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(canDelete ? .red : Theme.Color.divider)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.Color.bgSecondary)
        .confirmationDialog(
            String(format: "chat.selection.delete".localized, count),
            isPresented: $deleteSelectionPrompt,
            titleVisibility: .visible
        ) {
            Button("chat.action.delete_for_me".localized, role: .destructive) {
                vm.deleteSelectedForMe()
            }
            if vm.selectionAllRetractable {
                Button("chat.action.delete_for_everyone".localized, role: .destructive) {
                    Task { await vm.deleteSelectedForEveryone() }
                }
            }
            Button("common.cancel".localized, role: .cancel) {}
        }
        .sheet(item: $multiForwardAnchor) { anchor in
            ForwardPickerSheet(message: anchor) { destination in
                multiForwardAnchor = nil
                Task {
                    switch destination {
                    case .contact(let c): await vm.forwardSelected(toContact: c)
                    case .group(let g):   await vm.forwardSelected(toGroup: g)
                    }
                }
            } onCancel: { multiForwardAnchor = nil }
        }
    }

    @ViewBuilder
    private var pendingMediaStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.pendingMedia) { item in
                    pendingMediaTile(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func pendingMediaTile(_ item: ChatViewModel.PendingMediaItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch item {
                case .photo(_, let img):
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                case .video(_, _, let thumb):
                    ZStack {
                        if let t = thumb {
                            Image(uiImage: t)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Theme.Color.bgSecondary
                        }
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.85))
                    }
                case .gif(_, let data, _):
                    // Animate the GIF right in the pending tile so the
                    // user sees what they're about to send. Same
                    // renderer as the inline bubble path.
                    AnimatedGIFView(data: data, contentMode: .fill)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button {
                vm.removePendingMedia(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    // Enlarged hit area so the 18pt glyph doesn't
                    // require a precise tap right next to the
                    // pending-tile thumbnail.
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    private var sendButton: some View {
        Button {
            Task {
                if !vm.pendingMedia.isEmpty {
                    if let err = await vm.sendPendingMediaWithCaption() {
                        videoError = err
                    }
                } else {
                    await vm.send()
                }
            }
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .rotationEffect(.degrees(45))
                .offset(x: -1, y: 1)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.Color.accent))
        }
        .buttonStyle(.plain)
    }

    /// Composer "Poll" row handler. `nil` for 1:1 / random chats so
    /// `AttachmentPickerSheet` hides the row entirely. For groups,
    /// closing the attach sheet first then presenting the composer
    /// avoids the iOS 26 sheet-after-sheet bug (matching the same
    /// pattern as `pendingAttachAction`).
    private var pollPickerHandler: (() -> Void)? {
        guard case .group = vm.target else { return nil }
        return {
            showAttachmentMenu = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                showPollComposer = true
            }
        }
    }

    /// Composer "Share group" handler. Hidden only in random-chat
    /// (privacy — a stranger shouldn't see a member's group list).
    /// Available in both 1:1 AND group chats — sharing a group into
    /// another group is a legit "invite the whole crew to this other
    /// chat" pattern.
    private var shareGroupPickerHandler: (() -> Void)? {
        switch vm.target {
        case .peer, .group:
            return {
                showAttachmentMenu = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showShareGroupPicker = true
                }
            }
        case .randomPeer:
            return nil
        }
    }

    /// Wire a finished poll-composer draft into the send pipeline:
    /// create the server-side poll (gets back `poll_id`), then
    /// broadcast a `.poll` envelope so every group member's chat
    /// renders a fresh `PollBubble` ready to vote.
    private func submitPoll(_ draft: PollComposerSheet.PollDraft) async {
        guard case .group(let g) = vm.target else { return }
        let messageID = UUID()
        do {
            let pollID = try await PollService.shared.createPoll(
                inGroupID: g.id,
                messageID: messageID.uuidString,
                numOptions: draft.options.count,
                singleChoice: draft.singleChoice,
                anonymous: draft.anonymous
            )
            try await MessageService.shared.sendPoll(
                envelopeID: messageID,
                pollID: pollID,
                question: draft.question,
                options: draft.options,
                singleChoice: draft.singleChoice,
                anonymous: draft.anonymous,
                to: g
            )
        } catch {
            // Surface to the user via the existing toast plumbing if
            // available; for v1 we just print so the dev console
            // shows the failure path.
            print("[poll] submit failed: \(error)")
        }
    }

    /// Drains the pending attach action AFTER the menu sheet has
    /// fully torn down. The media picker is presented via UIKit
    /// (`UnifiedMediaPickerPresenter`) instead of a SwiftUI `.sheet`
    /// because iOS 26 silently drops a sheet-after-sheet chain. The
    /// other actions are imperative anyway (UIImagePicker), so they
    /// avoid the bug naturally.
    private func handleAttachDismiss() {
        let action = pendingAttachAction
        pendingAttachAction = nil
        DispatchQueue.main.async {
            switch action {
            case .media:
                UnifiedMediaPickerPresenter.present(
                    limit: vm.pendingMediaSlotsLeft,
                    onDone: { items in
                        Task { @MainActor in
                            for item in items {
                                switch item {
                                case .photo(let img):
                                    vm.queuePendingPhotos([img])
                                case .video(let url):
                                    let thumb = await Self.makeVideoThumbnail(url: url)
                                    vm.queuePendingVideo(url: url, thumbnail: thumb)
                                case .gif(let data, let preview):
                                    vm.queuePendingGIF(data: data, preview: preview)
                                }
                            }
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                        }
                    }
                )
            case .camera:
                ImperativePicker.captureFromCamera(mode: .both) { captured in
                    guard let captured else { return }
                    Task { @MainActor in
                        switch captured {
                        case .photo(let img):
                            vm.queuePendingPhotos([img])
                        case .video(let url):
                            let thumb = await Self.makeVideoThumbnail(url: url)
                            vm.queuePendingVideo(url: url, thumbnail: thumb)
                        case .gif:
                            // Camera capture never produces GIFs, but
                            // the enum case must be handled to satisfy
                            // exhaustiveness.
                            break
                        }
                    }
                }
            case .premium:
                showPremiumComposer = true
            case .document:
                DocumentPickerPresenter.present(
                    onPick: { picked in
                        Task { @MainActor in
                            if let err = await vm.sendFile(
                                fileURL: picked.url,
                                fileName: picked.fileName,
                                mime: picked.mime,
                                sizeBytes: picked.sizeBytes,
                            ) {
                                videoError = err
                            }
                        }
                    }
                )
            case .location:
                showLocationPicker = true
            case .none:
                break
            }
        }
    }

    /// Off-thread first-frame extraction for video preview thumbs.
    /// Best-effort: a generation failure just means we render a
    /// placeholder play-icon over the gray tile.
    fileprivate static func makeVideoThumbnail(url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            do {
                let cg = try gen.copyCGImage(at: .zero, actualTime: nil)
                return UIImage(cgImage: cg)
            } catch {
                return nil
            }
        }.value
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 18))
            .foregroundColor(voiceRecorder.isRecording ? .red : Theme.Color.textPrimary)
            .frame(width: 36, height: 36)
            .background {
                if voiceRecorder.isRecording {
                    Circle().fill(Color.red.opacity(0.18))
                } else {
                    Circle().fill(.regularMaterial)
                }
            }
            .overlay(
                Circle().strokeBorder(
                    Color.white.opacity(0.08), lineWidth: 0.5
                )
            )
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !voiceRecorder.isRecording && !voiceLocked
                            && micDragOffset == 0 && micDragWidth == 0 {
                            // First touch fires the mic permission prompt.
                            Task {
                                let ok = await voiceRecorder.start()
                                if !ok { voicePermissionDenied = true }
                            }
                        }
                        micDragOffset = value.translation.height
                        micDragWidth = value.translation.width
                        voiceCancelArmed = value.translation.width < -Self.voiceCancelHorizontalOffset
                        voiceLockArmed = value.translation.height < -Self.voiceLockOffset
                    }
                    .onEnded { _ in
                        let cancelArmed = voiceCancelArmed
                        let lockArmed = voiceLockArmed
                        micDragOffset = 0
                        micDragWidth = 0
                        voiceCancelArmed = false
                        voiceLockArmed = false
                        // Always go through a Task so we can await any
                        // in-flight `start()` before deciding what to do
                        // with the recorder. Without this a fast tap
                        // could fire `finish()` while `startImpl()` was
                        // still running and leave the recorder orphaned,
                        // breaking every subsequent mic press.
                        Task {
                            if cancelArmed {
                                await voiceRecorder.cancel()
                            } else if lockArmed {
                                // Lock engages: recording continues with
                                // no finger needed. Bar switches to
                                // `lockedPill` until the user taps stop
                                // (→ preview) or cancel (→ discard).
                                voiceLocked = true
                            } else if let result = await voiceRecorder.finish() {
                                // Default flow: release without lock or
                                // cancel → go to preview, NOT auto-send.
                                // The user wants a chance to re-listen
                                // before committing.
                                pendingVoicePreview = PendingVoicePreview(
                                    url: result.url, duration: result.duration
                                )
                            }
                        }
                    }
            )
    }

    private var recordingPill: some View {
        // Three exclusive visual states: armed-to-cancel (red, "release"),
        // armed-to-lock (accent, "release to lock"), neutral (hint hints).
        let textColor: Color = {
            if voiceCancelArmed { return .red }
            if voiceLockArmed { return Theme.Color.accent }
            return Theme.Color.textPrimary
        }()
        let hintIcon: String = {
            if voiceCancelArmed { return "trash.fill" }
            if voiceLockArmed { return "lock.fill" }
            return "chevron.up"
        }()
        let hintKey: String = {
            if voiceCancelArmed { return "chat.voice.cancel_armed" }
            if voiceLockArmed { return "chat.voice.lock_armed" }
            return "chat.voice.swipe_hints"
        }()
        return HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(voiceRecorder.elapsed.truncatingRemainder(dividingBy: 1.0) < 0.5 ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.5), value: voiceRecorder.elapsed)
            Text(formatRecordingDuration(voiceRecorder.elapsed))
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: hintIcon)
                    .font(.system(size: 12, weight: .semibold))
                Text(hintKey.localized)
                    .font(.caption)
            }
            .foregroundColor(
                voiceCancelArmed ? .red
                : voiceLockArmed ? Theme.Color.accent
                : Theme.Color.textSecondary
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(
            Capsule().fill(
                voiceCancelArmed ? Color.red.opacity(0.12)
                : voiceLockArmed ? Theme.Color.accent.opacity(0.12)
                : Theme.Color.bgSecondary.opacity(0.6)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                Theme.Color.divider.opacity(0.3), lineWidth: 0.5
            )
        )
    }

    /// Shown after the user slides up past the lock threshold and lifts
    /// their finger. Recorder is still running; the bar gives the user
    /// explicit stop (→ preview) and cancel (→ discard) controls.
    private var lockedPill: some View {
        HStack(spacing: 10) {
            Button {
                voiceLocked = false
                Task { await voiceRecorder.cancel() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Color.accent)
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(voiceRecorder.elapsed.truncatingRemainder(dividingBy: 1.0) < 0.5 ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.5), value: voiceRecorder.elapsed)
            Text(formatRecordingDuration(voiceRecorder.elapsed))
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
            Spacer()
            Button {
                voiceLocked = false
                Task {
                    if let result = await voiceRecorder.finish() {
                        await MainActor.run {
                            pendingVoicePreview = PendingVoicePreview(
                                url: result.url, duration: result.duration
                            )
                        }
                    }
                }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.Color.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(Capsule().fill(Theme.Color.bgSecondary.opacity(0.6)))
        .overlay(Capsule().strokeBorder(Theme.Color.divider.opacity(0.3), lineWidth: 0.5))
    }

    /// Shown when the user has a finished but-not-yet-sent voice clip.
    /// Play/pause via the shared VoicePlayer, trash to discard, arrow
    /// to send. The clip stays in a tmp file until either action; we
    /// clean up the file on discard.
    private func previewPill(_ preview: PendingVoicePreview) -> some View {
        let isThisPlaying = voicePlayer.playingMessageID == preview.id && voicePlayer.isPlaying
        return HStack(spacing: 10) {
            Button {
                voicePlayer.stop()
                try? FileManager.default.removeItem(at: preview.url)
                pendingVoicePreview = nil
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.red)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Button {
                voicePlayer.playLocal(id: preview.id, url: preview.url)
            } label: {
                Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Color.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.Color.bgSecondary.opacity(0.8)))
            }
            .buttonStyle(.plain)
            Text(formatRecordingDuration(
                isThisPlaying ? voicePlayer.elapsed : preview.duration
            ))
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(Theme.Color.textPrimary)
            Spacer()
            Button {
                voicePlayer.stop()
                pendingVoicePreview = nil
                Task {
                    if let err = await vm.sendVoice(
                        fileURL: preview.url, durationSec: preview.duration
                    ) {
                        videoError = err
                    }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.Color.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Capsule().fill(Theme.Color.bgSecondary.opacity(0.6)))
        .overlay(Capsule().strokeBorder(Theme.Color.divider.opacity(0.3), lineWidth: 0.5))
    }

    private func formatRecordingDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let m = total / 60
        let s = total % 60
        let tenths = Int((secs - Double(total)) * 10)
        return String(format: "%d:%02d.%d", m, s, tenths)
    }

    private var emojiPanel: some View {
        let equippedKinds: [ItemKind] = itemsSvc.items
            .filter { $0.equipped }
            .compactMap { itemsSvc.catalog?.kind(by: $0.kindID) }
            .filter { $0.appliesAs == .cosmeticSmileys }
        return VStack(spacing: 0) {
            tabStrip(equippedKinds: equippedKinds)
            grid(for: emoticonTab, equippedKinds: equippedKinds)
        }
        .frame(height: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func tabStrip(equippedKinds: [ItemKind]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tabButton(id: nil, label: nil, systemIcon: "face.smiling")
                ForEach(equippedKinds, id: \.id) { kind in
                    tabButton(id: kind.id, label: ItemDisplay.name(for: kind.id), systemIcon: nil)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 34)
    }

    private func tabButton(id: String?, label: String?, systemIcon: String?) -> some View {
        let isOn = emoticonTab == id
        return Button {
            emoticonTab = id
        } label: {
            HStack(spacing: 4) {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 13, weight: .semibold))
                }
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundColor(isOn ? .white : Theme.Color.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? Theme.Color.accent : Theme.Color.bgSecondary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func grid(for tab: String?, equippedKinds: [ItemKind]) -> some View {
        let entries = emoticonEntries(for: tab, equippedKinds: equippedKinds)
        let cols = [GridItem](repeating: GridItem(.flexible(), spacing: 8), count: 8)
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(entries, id: \.asset) { entry in
                    Button {
                        vm.input += entry.primaryCode
                        emoticonUsage.bump(entry.asset)
                    } label: {
                        if GIFImage.cachedImage(for: entry.asset) != nil {
                            GIFImage(name: entry.asset)
                                .frame(width: 34, height: 34)
                        } else {
                            Text(entry.primaryCode).font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                                .frame(width: 34, height: 34)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func emoticonEntries(
        for tab: String?, equippedKinds: [ItemKind],
    ) -> [(asset: String, name: String, primaryCode: String)] {
        if let tabID = tab, equippedKinds.contains(where: { $0.id == tabID }) {
            return CosmeticPacks.entries(for: tabID).map {
                (asset: $0.asset, name: $0.name, primaryCode: $0.primaryCode)
            }
        }
        let defaults = Emoticons.paletteAssets
        let usage = emoticonUsage.counts
        return defaults.sorted { a, b in
            let ca = usage[a.asset] ?? 0
            let cb = usage[b.asset] ?? 0
            if ca != cb { return ca > cb }
            return false
        }
    }
}

private struct BottomAnchoredScroll: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active, #available(iOS 17.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

private struct DateDivider: View {
    let label: String
    var body: some View {
        HStack {
            Rectangle().fill(Theme.Color.divider).frame(height: 1)
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.horizontal, 6)
            Rectangle().fill(Theme.Color.divider).frame(height: 1)
        }
        // Extra top breathing room so the FIRST divider doesn't butt
        // against the navbar / safe-area when a chat opens with
        // content at the top. Bottom stays minimal so following
        // bubbles sit close to their day's label.
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct TypingIndicator: View {
    let label: String
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.Color.textSecondary)
                        .frame(width: 5, height: 5)
                        .opacity(phase == i ? 1 : 0.35)
                }
            }
            Text(label)
                .font(.caption2.italic())
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}


struct PendingEvidenceReport: Identifiable {
    let message: Message
    let bytes: Data
    let mime: String
    var id: UUID { message.id }
}
