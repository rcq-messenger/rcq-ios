import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: ChatViewModel
    @StateObject private var appState = AppState.shared
    /// Subscribed so the chat header reflects live presence updates the moment a
    /// `presence` event arrives over the WebSocket. Without this, the captured
    /// `Contact` inside `vm.target` is a stale snapshot from the moment of nav.
    @StateObject private var contacts = ContactService.shared
    @StateObject private var groupSvc = GroupService.shared
    @StateObject private var randomChat = RandomChatService.shared
    /// Subscribed so the call buttons in the header grey out the moment a
    /// call (any direction, any peer) becomes active — taps would silently
    /// no-op against `CallService.start`'s `state.isActive` guard otherwise.
    @StateObject private var calls = CallService.shared
    /// Subscribed so the clock badge in the header reflects the live TTL the
    /// moment the user picks a new option (or `wipe()` clears it).
    @StateObject private var chatSettings = ChatSettingsStore.shared
    @StateObject private var tradesSvc = TradesService.shared
    @StateObject private var itemsSvc = ItemsService.shared
    @StateObject private var emoticonUsage = EmoticonUsageStore.shared
    /// Active tab id in the emoji panel. `nil` = default (Kolobok
    /// base, sorted by usage); otherwise = equipped pack kind id.
    @State private var emoticonTab: String? = nil
    @State private var showEmojiPanel = false
    @State private var showInfo = false
    @State private var showAttachmentMenu = false
    /// Premium-content composer sheet (price input + photo/video pick).
    /// Only available in 1:1 + group threads — random chat skips it
    /// because the ephemeral session has no wallet identity to credit.
    @State private var showPremiumComposer: Bool = false
    @State private var showTTLPicker = false
    @State private var showTrade = false
    @State private var showTrades = false
    /// In-chat message search overlay. Mirrors the global search
    /// surface from ContactListView but scoped to messages of this
    /// thread only — see `InChatSearchOverlay`.
    @State private var showInChatSearch = false
    /// User's own call-privacy setting, mirrored from
    /// `/users/me/info` into UserDefaults by `PrivacySettingsView`.
    /// "nobody" hides every call-button affordance (voice + video)
    /// in the chat-thread trailing menu — the user has opted out
    /// of calls altogether.
    @AppStorage("rcq.privacy.callPolicy") private var callPolicy: String = "everyone"
    /// Set to a message id when the user picks a hit in the in-chat
    /// search overlay. The `messageScroll`'s ScrollViewReader watches
    /// this and asks the proxy to scroll the row into view, then
    /// flashes a brief accent highlight via `flashHighlightID` so the
    /// match is locatable inside a long thread. Reset to nil after
    /// the scroll fires.
    @State private var pendingScrollID: UUID?
    /// Currently flashed hit id. Set in lockstep with `pendingScrollID`
    /// when a search result is chosen, cleared after the highlight
    /// fade finishes — drives the `MessageRow`'s background tint.
    @State private var flashHighlightID: UUID?
    /// Specific trade the user tapped on the inline card. Distinct
    /// from `showTrades` (full list) — opens a sheet showing only
    /// that trade with accept / decline / cancel inline.
    @State private var inspectingTrade: Trade?
    @State private var videoError: String?
    /// Composer height — driven by `EmoticonTextField` via its
    /// `dynamicHeight` binding. Starts at the single-line min, grows
    /// up to ~5 lines, then the field switches to internal scroll.
    @State private var composerHeight: CGFloat = 36
    @StateObject private var voiceRecorder = VoiceRecorder.shared
    /// Drag-distance threshold (negative y) past which a release
    /// cancels the recording instead of sending. Tunable; matches
    /// the rough Telegram/WhatsApp feel.
    private static let voiceCancelOffset: CGFloat = 60
    /// Live drag offset of the mic button while held — drives the
    /// "slide ↑ to cancel" arrow's vertical position and the cancel-
    /// armed visual state.
    @State private var micDragOffset: CGFloat = 0
    /// True when the user has dragged past the cancel threshold so
    /// we're previewing a cancel-on-release — the timer pill flips
    /// red to make the state obvious.
    @State private var voiceCancelArmed: Bool = false
    /// Mic permission denial banner — set when `VoiceRecorder.start`
    /// returns false because the user said no in Settings.
    @State private var voicePermissionDenied: Bool = false
    /// Mirror of the system keyboard's presence — flipped by the
    /// will-show / will-hide notifications. SwiftUI gives us no
    /// first-class way to ask "is any text field first responder
    /// right now", so we cache the most recent transition. Drives
    /// the chat-area tap handler: keyboard up → tap dismisses it,
    /// keyboard down + emoji open → tap dismisses the panel.
    @State private var isKeyboardVisible: Bool = false
    /// True iff the chat thread is the user's own UIN (Saved
    /// Messages). Drives "no ellipsis menu" + "no call buttons" +
    /// the bookmark identity glyph in the principal slot.
    private var isSelfThread: Bool {
        if case .peer(let snapshot) = vm.target {
            return snapshot.uin == (AuthService.shared.ownUIN ?? -1)
        }
        return false
    }
    /// True when the chat is scrolled away from the bottom — drives
    /// the floating "scroll to latest" button. Tracked via an
    /// anchor view at the end of the LazyVStack whose
    /// onAppear / onDisappear flips this flag.
    @State private var showScrollToBottom: Bool = false
    /// Set when the user picks "Forward" in the long-press overlay —
    /// drives a sheet that lists contacts/groups to send the
    /// message into. `nil` while no forward is in flight.
    @State private var forwardTarget: Message?

    /// Reply is allowed in every thread type, including random
    /// chat — the wire format already carries `replyTo` on
    /// `.text/.photo/.video`, and the random send path now plumbs
    /// it through alongside the regular contact and group paths.
    private var replyAllowed: Bool { true }
    /// Drives the 1Hz redraw of the random-chat countdown header. Updated
    /// from a Timer publisher whenever the chat target is anonymous.
    @State private var now = Date()
    /// Long-press target — drives the custom MessageActionOverlay
    /// (reactions panel on top + system-style action list below).
    @State private var actionTarget: Message?
    /// Drives the report-with-evidence sheet. Set when the user
    /// picks "Report content" on a non-own media bubble. The
    /// caller pre-loads the decrypted bytes here so the sheet has
    /// everything it needs to upload — avoids an awkward in-sheet
    /// load spinner that could fail mid-flow.
    @State private var evidenceReportTarget: PendingEvidenceReport?

    init(target: ChatTarget) {
        _vm = StateObject(wrappedValue: ChatViewModel(target: target))
    }

    /// Convenience for legacy 1:1 callers that still pass a Contact.
    init(contact: Contact) {
        _vm = StateObject(wrappedValue: ChatViewModel(target: .peer(contact)))
    }

    var body: some View {
        // Header and footer sit in safe-area insets with translucent material,
        // so the message scroll passes underneath them — same blur pattern iOS
        // uses for its own navigation chrome.
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()

            messageScroll

            // In-chat search overlay — same blur-backed surface the
            // global SearchOverlay uses on the contact list, but
            // scoped to this thread's messages. Sits above the chat
            // content; tap-out or Cancel dismisses, tap on a hit
            // closes and scrolls the underlying chat to that row.
            if showInChatSearch {
                InChatSearchOverlay(
                    messages: vm.messages,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.18)) { showInChatSearch = false }
                    },
                    onSelectMessage: { msg in
                        withAnimation(.easeInOut(duration: 0.18)) { showInChatSearch = false }
                        // Defer one runloop tick so the overlay
                        // dismiss animation isn't fighting the
                        // ScrollViewReader's scroll request.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            pendingScrollID = msg.id
                            withAnimation(.easeIn(duration: 0.2)) {
                                flashHighlightID = msg.id
                            }
                            // Fade the highlight back out after a beat.
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

            // Long-press popover: reactions row on top (animated
            // KOLOBOK GIFs that the iOS system menu can't render),
            // bubble preview, system-styled action list below.
            // Material backdrop with tap-outside dismissal — same
            // posture Telegram uses, just without UIContextMenu-
            // Interaction's lift animation (SwiftUI doesn't expose
            // that without a UIKit wrapper).
            if let target = actionTarget {
                MessageActionOverlay(
                    message: target,
                    senderNickname: vm.senderNickname(target.senderUIN),
                    canDeleteForEveryone: target.isFromMe,
                    canReply: replyAllowed,
                    canEdit: target.isFromMe
                        && target.kind == .text
                        && !target.deletedForEveryone,
                    onReact: { asset in vm.toggleReaction(asset, on: target) },
                    onReply: {
                        let copy = target
                        // No `withAnimation` — the inline reply context
                        // appears in one frame inside the pill. Spring-
                        // animating the reply chrome jittered the chat
                        // (safeAreaInset chasing the pill height through
                        // a multi-frame spring), which the user perceived
                        // as lag.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            vm.replyTarget = copy
                        }
                    },
                    onEdit: {
                        let copy = target
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            vm.startEdit(copy)
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
                            // In-place text swap (Argus-style): toggle
                            // the translation cache for this message.
                            // First call kicks off TranslationSession
                            // (see `.translationTask` below); second
                            // call reverts to the original body.
                            vm.toggleTranslate(copy)
                        }
                    },
                    isTranslated: vm.isTranslated(target),
                    onDeleteForMe: { vm.deleteForMe(target) },
                    onDeleteForEveryone: { Task { await vm.deleteForEveryone(target) } },
                    onDismiss: { withAnimation(.easeInOut(duration: 0.18)) { actionTarget = nil } },
                    // Report-with-evidence is gated to:
                    //   • non-own media bubbles
                    //   • photo or premium-photo (video evidence is a v2 follow-up)
                    //   • premium-photos that are unlocked (otherwise the
                    //     local device has no plaintext to attach)
                    onReport: shouldOfferEvidenceReport(target) ? {
                        let copy = target
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            Task { await prepareEvidenceReport(for: copy) }
                        }
                    } : nil,
                )
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
                if let inGroup = vm.target.broadcastReadOnly(viewerUIN: AuthService.shared.ownUIN) {
                    broadcastReadOnlyHint(group: inGroup)
                } else {
                    inputBar
                }
                // Emoji panel sits BELOW the composer inside the
                // safeAreaInset — same posture as the system
                // keyboard would when raised. When `showEmojiPanel`
                // flips, the inset's height changes, the chat above
                // re-flows, and the latest message stays glued to
                // the top of the panel. The whole inset is wrapped
                // in `.animation` below so the growth is one smooth
                // movement instead of an instant snap.
                if showEmojiPanel {
                    emojiPanel
                }
            }
            .animation(.easeOut(duration: 0.22), value: showEmojiPanel)
        }
        // CallMinimizedBar reserves the top row when a minimized
        // call is active. Applied AFTER the header inset so it
        // composes outside it — the bar lands above the chat
        // header instead of overlapping it. SafeAreaInset from a
        // parent doesn't traverse `navigationDestination`, so each
        // root-level screen has to host its own copy.
        .callMinimizedBarInset()
        // System nav bar carries the chrome now: back chevron in
        // its iOS 26 bubble (automatic), centred peer / group /
        // stranger principal, and a single trailing ellipsis menu
        // that fans out into Call / Trade / Disappearing messages
        // (and Skip / Leave for random sessions).
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                principalContent
            }
            // Trailing menu — always present now that "Search
            // messages" lives at its top. Saved Messages
            // (self-thread) used to skip the toolbar item entirely
            // because Call / Trade / TTL didn't apply; with
            // search added, the menu is always non-empty.
            ToolbarItem(placement: .topBarTrailing) {
                trailingMenu
            }
        }
        .enableSwipeBack()
        // Random-chat presents this view inside a `.sheet`, where
        // there's no enclosing NavigationStack — `navigationDestination`
        // would log a "misplaced modifier" warning every render.
        // Skip it for the random path; info isn't reachable there
        // anyway (the header doesn't expose the tap-username
        // affordance for strangers).
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
        // Report-with-evidence sheet — opened when the user picks
        // "Report content" on a non-own media bubble. The decrypted
        // bytes were prepared in `prepareEvidenceReport(for:)` before
        // this sheet appears, so the sheet itself can submit straight
        // away without an inline load step.
        .sheet(item: $evidenceReportTarget) { target in
            ReportEvidenceSheet(
                message: target.message,
                evidenceBytes: target.bytes,
                evidenceMime: target.mime,
                targetUIN: target.message.senderUIN,
                targetNickname: vm.senderNickname(target.message.senderUIN),
            )
        }
        // Pickers are launched imperatively via UIKit on the
        // scene's top view controller (see `ImperativePicker`)
        // rather than via SwiftUI's `.sheet`. Hosting a PHPicker
        // sheet inside the random-chat fullScreenCover triggered an
        // iOS 26 cascade-dismiss bug — the cover collapsed the
        // moment the picker dismissed, dropping the user out of
        // the active session mid-send. Going through UIKit keeps
        // the picker outside SwiftUI's modal stack entirely, so
        // its dismiss can't propagate upward.
        .sheet(isPresented: $showAttachmentMenu) {
            // Bottom sheet attachment picker — on iOS 26
            // `confirmationDialog` from a small UIView (the paperclip
            // button) sometimes anchors as a popover above the
            // button instead of the standard bottom action sheet,
            // putting the picker far from the user's thumb. A native
            // sheet with `[.height(360)]` detent always rises from
            // the bottom edge and reads as the same "card from
            // below" affordance the user expects.
            AttachmentPickerSheet(
                isRandom: { if case .randomPeer = vm.target { return true } else { return false } }(),
                onPhoto: {
                    showAttachmentMenu = false
                    ImperativePicker.pickImages(limit: 5) { images in
                        Task {
                            for img in images {
                                // Surface the FIRST friendly error
                                // we hit (most likely a `tooLarge`
                                // from the 25 MB pre-flight) and
                                // bail — continuing the loop after
                                // a size-cap failure would just
                                // stack the same error per image.
                                if let err = await vm.sendPhoto(img) {
                                    videoError = err
                                    break
                                }
                            }
                        }
                    }
                },
                onVideo: {
                    showAttachmentMenu = false
                    ImperativePicker.pickVideo { url in
                        guard let url else { return }
                        Task {
                            if let err = await vm.sendVideo(from: url) {
                                videoError = err
                            }
                        }
                    }
                },
                onCamera: {
                    showAttachmentMenu = false
                    ImperativePicker.captureFromCamera(mode: .both) { captured in
                        guard let captured else { return }
                        Task {
                            switch captured {
                            case .photo(let img):
                                if let err = await vm.sendPhoto(img) {
                                    videoError = err
                                }
                            case .video(let url):
                                if let err = await vm.sendVideo(from: url) {
                                    videoError = err
                                }
                            }
                        }
                    }
                },
                onPremium: {
                    showAttachmentMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showPremiumComposer = true
                    }
                }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
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
            // Show the live setting underneath the title so it's obvious
            // which option is active without having to read the labels twice.
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
        // Mic permission alert lives at body root, not on the
        // composer inputBar — alert modifiers attached to deeply
        // nested views can trigger redundant layout passes that
        // jiggle the seam between the composer and the message
        // list by 1-2pt every frame the binding is evaluated.
        .alert("chat.voice.permission.title".localized, isPresented: $voicePermissionDenied) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text("chat.voice.permission.body".localized)
        }
        .onAppear {
            vm.onAppear()
            // Refresh pending trade lists so the chat banner can
            // paint immediately if there's a live offer between us
            // and the peer.
            Task { await tradesSvc.refreshAll() }
            // Cosmetic-pack picker reads off ItemsService — pull
            // catalog + inventory if the user opens chat before
            // ever visiting the inventory.
            Task {
                if itemsSvc.catalog == nil { await itemsSvc.refreshCatalog() }
                if itemsSvc.items.isEmpty { await itemsSvc.refreshInventory() }
            }
        }
        .sheet(isPresented: $showTrade) {
            if case .peer(let snapshot) = vm.target {
                TradeProposeView(recipientUIN: snapshot.uin, recipientNickname: snapshot.nickname)
            }
        }
        .sheet(isPresented: $showTrades) {
            TradesListView()
        }
        // In-place translation. Long-press → Translate stages a
        // `pendingTranslationMessage` on the VM; our hidden
        // translation runner kicks the iOS 18+ TranslationSession,
        // writes the result back into `vm.translatedTexts`, and the
        // bubble's text branch swaps over via `vm.displayText(for:)`.
        // No modal, no Apple "Open in Translate" hand-off, no Google.
        .modifier(InPlaceTranslator(vm: vm))
        .sheet(item: $inspectingTrade) { trade in
            SingleTradeSheet(trade: trade)
                .presentationDetents([.fraction(0.5), .large])
        }
        .onChange(of: vm.messages.last?.id) { _ in
            // Live ack: when a new inbound message lands while the chat is open,
            // mark it read immediately so the sender sees the read tick.
            if let last = vm.messages.last { vm.ackIfVisible(last) }
        }
        // 1Hz tick drives the random-chat countdown banner. Cheap to leave
        // running for non-random targets (just bumps a State var nothing else
        // reads), but we could gate it if it ever showed up in profiling.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick in
            if case .randomPeer = vm.target { now = tick }
        }
    }

    // MARK: - pending-trade banner

    /// Live trade between us and this chat's peer, if any. Pulls
    /// from both incoming and outgoing pending lists — either side
    /// of the conversation is allowed to surface the banner from the
    /// other's perspective.
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

    /// Bottom strip shown only in random sessions. Carries the live countdown,
    /// the 60-second warning treatment, and the "Add as contact" button.
    /// Server's `/contacts/request` is idempotent and auto-accepts when both
    /// sides have requested each other, so the moment this stranger ALSO taps
    /// Add, both ends materialise as real contacts via the standard
    /// `contact_response` WS event flow — no random-chat-specific server logic.
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

    /// Centred peer / group / stranger identity for `.principal`.
    /// Status icon (or group / stranger glyph) plus nick stacked
    /// over UIN — fits inside the system nav bar's single row.
    /// Whole stack is tap-to-open-info for peer / group; random
    /// session has no info surface so it stays non-interactive.
    @ViewBuilder
    private var principalContent: some View {
        switch vm.target {
        case .peer(let snapshot):
            let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
            let isSelf = live.uin == (AuthService.shared.ownUIN ?? -1)
            // Saved Messages — render as plain View, not a Button.
            // `Button.disabled(true)` greys child views to ~50%
            // opacity even with `.foregroundColor(...)` set, which
            // is why the bookmark + label looked transparent in
            // self-thread. Keep Button only for tap-to-open-info
            // (peer profile) which doesn't apply to ourselves.
            //
            // Centring: a `Color.clear` of the same fixed width as
            // the leading icon is appended on the trailing side so
            // the HStack balances around its middle. Without it the
            // status icon ate width on the left, shifting the
            // nickname / UIN visibly to the right of the nav-bar
            // centre.
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
                        Text(String(live.uin))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.Color.textMono)
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
                // Group icon was removed by request — name + count
                // alone is enough identity, and the navbar already
                // implies "you're in a group" via the Manage menu.
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

    /// Single ellipsis menu — fans out the actions that used to
    /// sit as separate icons in the custom header. Per target:
    /// peer = Audio call / Video call / Propose trade /
    /// Disappearing messages, group = Disappearing messages,
    /// random = Skip / Leave.
    @ViewBuilder
    private var trailingMenu: some View {
        Menu {
            // Search messages is offered for every thread type that
            // has a persisted history — i.e. peer + group + self
            // thread. Random sessions are ephemeral (RandomChatService
            // holds the buffer, no MessageStore), but searching the
            // in-memory list still works the same way: the overlay
            // reads off `vm.messages` directly.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showInChatSearch = true }
            } label: {
                Label("chat.menu.search_messages".localized, systemImage: "magnifyingglass")
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
                    // Block + Report at the bottom of the 1:1 chat
                    // menu — same shared component used on profile
                    // / group / audio room. Required by App Review
                    // 1.2 (UGC moderation reachable from every
                    // surface where one user surfaces another).
                    UserSafetyActions(
                        targetUIN: snapshot.uin,
                        targetNickname: snapshot.nickname,
                        context: "chat",
                        style: .menu,
                    )
                    // `.tint(.red)` cascades to the inner Block + Report
                    // Buttons. iOS 26 Menu otherwise ignores the per-row
                    // `.foregroundStyle(.red)` we set inside the Label
                    // and inherits the chat's accent (green) for the
                    // SF symbols. Tinting the wrapping Section is the
                    // one knob the Menu template DOES honor for its
                    // child icons.
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
                // Block uses the peer's real UIN so the same person
                // can't reach you via contacts later.
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

    /// Active TTL label for the menu row — shows "Off" when no
    /// disappearing window is set, otherwise the configured option.
    private var disappearingLabel: String {
        if let ttl = chatSettings.ttl(for: vm.target.thread) {
            return String(format: "chat.ttl.disappearing_with".localized, ChatSettingsStore.label(for: ttl))
        }
        return "chat.menu.disappearing".localized
    }

    private var ttlActive: Bool {
        chatSettings.ttl(for: vm.target.thread) != nil
    }

    /// Centered "Say hi" empty-state. Rendered as an overlay above
    /// the (empty) ScrollView rather than as a row inside the
    /// LazyVStack so its position doesn't depend on the scroll
    /// anchor — sits ~1/3 from the top of the viewport, where the
    /// eye lands naturally.
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
            // No info page in random chat — that's the whole point of "anonymous".
            EmptyView()
        }
    }

    /// True if my live record of this peer is blocked. Group and random chats
    /// can't be "blocked" — the property stays false there.
    private var isPeerBlocked: Bool {
        guard case .peer(let snapshot) = vm.target else { return false }
        return contacts.contacts.first(where: { $0.uin == snapshot.uin })?.blocked ?? false
    }


    // MARK: - messages

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
            // Empty-state placeholder lives OUTSIDE the ScrollView so
            // it sits centered in the viewport rather than getting
            // pinned against the input bar by the bottom-anchor
            // logic. Fades out the moment the first message lands.
            if vm.messages.isEmpty {
                emptyChatPlaceholder
                    .transition(.opacity)
                    .zIndex(1)
            }
            ScrollView {
                // Drive the `.transition` on each row from the
                // current message-id list. Without this, the
                // `withAnimation` blocks in `MessageStore.deleteLocal`
                // and `sweepExpired` get swallowed by the Combine
                // receive(on:) hop into ChatViewModel.$messages, so
                // removal animations would never fire — rows just
                // disappeared abruptly.
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(vm.grouped().enumerated()), id: \.offset) { _, group in
                        DateDivider(label: group.label)
                        ForEach(group.items) { msg in
                            MessageRow(
                                message: msg,
                                showSender: vm.target.thread.isGroup && !msg.isFromMe,
                                senderNickname: vm.senderNickname(msg.senderUIN),
                                displayBody: vm.displayText(for: msg),
                                isTranslated: vm.isTranslated(msg),
                                isHighlighted: flashHighlightID == msg.id,
                                onTapReaction: { asset in vm.toggleReaction(asset, on: msg) },
                                onLongPress: {
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
                                    // Quick-react path. Picks the
                                    // "good" KOLOBOK (👍-equivalent in
                                    // our reaction set) — same toggle
                                    // semantics as picking it from the
                                    // long-press overlay, so a second
                                    // double-tap clears the reaction.
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    vm.toggleReaction("good", on: msg)
                                },
                                onTapReplyQuote: { targetID in
                                    // Reuse the same scroll/flash
                                    // pipeline the in-chat search uses
                                    // — set `pendingScrollID`,
                                    // `flashHighlightID`, fade the
                                    // accent tint after a beat. Skip
                                    // silently if the target row isn't
                                    // in the thread anymore (TTL'd
                                    // out, deleted-for-everyone).
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
                                    // Same end-state as long-press →
                                    // Reply: drop a `replyTarget` on
                                    // the VM, the composer's reply
                                    // strip animates in. Spring matches
                                    // the long-press path so the strip
                                    // transition feels identical
                                    // regardless of how the user got
                                    // there.
                                    let copy = msg
                                    vm.replyTarget = copy
                                }
                            )
                            // Visual selection: dim every row that's *not* the
                            // long-pressed one, scale the chosen bubble up just
                            // a touch.
                            // Fade-out (soft delete) takes precedence over the
                            // dim + scale stack for the action overlay so a
                            // bubble vanishing while another is long-pressed
                            // doesn't hold at 30% opacity.
                            .opacity(vm.fadingOutIDs.contains(msg.id)
                                     ? 0
                                     : (actionTarget == nil || actionTarget?.id == msg.id ? 1 : 0.3))
                            .scaleEffect(vm.fadingOutIDs.contains(msg.id)
                                         ? 0.85
                                         : (actionTarget?.id == msg.id ? 1.04 : 1.0),
                                         anchor: msg.isFromMe ? .trailing : .leading)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: actionTarget?.id)
                            // Drives the soft-delete fade — implicit
                            // animation, doesn't need a withAnimation
                            // transaction to inherit (the Combine assign chain
                            // would lose it before SwiftUI re-renders).
                            // Row stays at full height during the fade so
                            // adjacent bubbles don't slide while it's still
                            // visibly in place. The actual layout collapse
                            // happens at MessageStore's phase-2 array removal,
                            // animated by the count-watch on the LazyVStack
                            // (.animation(.easeInOut(.25), value: messages.count)
                            // above) — fade THEN reflow, not both at once.
                            .animation(.easeInOut(duration: 0.3), value: vm.fadingOutIDs.contains(msg.id))
                            .transition(.opacity)
                            .id(msg.id)
                        }
                    }
                    // Pending trade between us and this peer rendered
                    // inline as a system-style chat card. Sits below
                    // the latest message so it reads as the most
                    // recent activity in the thread. Tap →
                    // TradesListView for accept/decline.
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
                    // Bottom anchor — drives both the initial
                    // scroll-to-latest on chat open AND the
                    // floating "scroll to bottom" button visibility.
                    // Sized 1pt high so it's effectively invisible
                    // but still mountable / hit-trackable inside the
                    // LazyVStack. onAppear → at-bottom (hide FAB),
                    // onDisappear → user scrolled up (show FAB).
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
                // No explicit bottom padding — `safeAreaInset(.bottom)`
                // already reserves the composer's height + any reply /
                // emoji-panel chrome. Adding more padding on top of
                // the inset doubled the gap and caused the seam between
                // the last bubble and the input bar to jitter as the
                // inset's measured height settled across renders.
                // Insertion / removal animations driven by the live
                // count. `.count` (vs `.map(\.id)`) keeps the animation
                // off state mutations like edit/react/state-flip,
                // which previously fired a tiny shudder on every
                // send/receive. Duration is back at 0.25 — 0.18 felt
                // snappy on inserts but visually clipped delete fades.
                .animation(.easeInOut(duration: 0.25), value: vm.messages.count)
            }
            // No `defaultScrollAnchor(.bottom)` — it had two failure
            // modes the user kept hitting:
            //   1. When the user scrolls UP and LazyVStack realizes
            //      previously-unrealized rows, content size grows;
            //      the bottom anchor yanks the viewport back to the
            //      bottom mid-scroll. Symptom the user reported as
            //      "иногда начинаю листать и меня возвращает назад".
            //   2. On an empty chat the placeholder gets glued to
            //      the input bar (the bottom edge of the bottom-
            //      anchored ScrollView), instead of sitting near
            //      the top / center of the viewport like a fresh
            //      iMessage thread does.
            // Initial scroll-to-bottom is owned exclusively by the
            // `.task` retry loop below. After that the user owns
            // the scroll position; new-message inserts re-pin via
            // an `onChange(messages.count)` only when the chat is
            // already at the bottom (preserves "scrolled up to
            // re-read" intent).
            // Drag down inside the chat scroll dismisses the keyboard.
            // The `.immediately` mode hides the keyboard the instant a
            // pan starts — feels lighter than `.interactively` for a
            // chat (no rubber-band tracking the keyboard's bottom
            // edge), and a tap elsewhere on the chat surface still
            // closes it via the explicit `.onTapGesture` below.
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture {
                // Tap-anywhere-on-the-chat-area dismiss. Two-step,
                // iMessage-style: if the keyboard is up, drop it
                // first; if it's already down but the emoji panel
                // is open, close the panel. Without the staging the
                // user couldn't pick stickers — the same tap that
                // dismissed the keyboard would also collapse the
                // panel, forcing a re-open every time.
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
            .onChange(of: vm.messages.count) { _ in
                // New message arrived (or sent). Re-anchor to the
                // bottom ONLY if the chat is already parked there —
                // otherwise the user is scrolled up reading older
                // history and yanking them down would be hostile.
                // The `showScrollToBottom` flag is the inverse of
                // "is at bottom" (anchor view is offscreen ⇒ not
                // at bottom), set by the bottom-anchor's onAppear/
                // onDisappear handlers.
                guard !showScrollToBottom else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            // Scroll requested by the in-chat search overlay. The
            // overlay sets `pendingScrollID` after its own dismiss
            // animation; we centre the row in the viewport, then
            // clear the request so a subsequent tap on the same hit
            // still re-fires (assigning the same UUID twice is a
            // no-op for `onChange`, so reset to nil).
            .onChange(of: pendingScrollID) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    pendingScrollID = nil
                }
            }
            // Keyboard-show → snap the chat to its last bubble so
            // the rising composer doesn't reveal an empty stretch
            // above the keyboard. SwiftUI's auto-keyboard-avoidance
            // already shrinks the visible scroll area; this just
            // re-anchors the content. For threads with too few
            // messages to fill the viewport the scrollTo is a
            // no-op (content already top-aligned), which matches
            // the user's expectation that short chats don't get
            // shoved offscreen by keyboard-up.
            // Re-anchor the scroll to the latest bubble on every
            // event that grows OR shrinks the bottom safeAreaInset:
            // keyboard show/hide, emoji panel toggle, reply / edit
            // strip toggle. Earlier code deferred each scroll by
            // ~0.32s past the spring (waiting for layout to settle)
            // — that produced the characteristic "messages stand
            // still then jump" lag the user reported. Synchronous
            // scroll wrapped in a spring matching the binding's
            // animation lets the inset growth and the scroll glide
            // together in one frame, no jump.
            //
            // Both directions are handled — opening AND closing —
            // so dismissing reply via X / closing the emoji panel /
            // keyboard descent all collapse the empty space below
            // the last bubble back against the composer. Without
            // the close-direction handlers there was a 44–180pt
            // empty band hanging under the latest message that
            // only resolved on the next user scroll.
            // Reply / edit / emoji-panel toggle: on iOS 17+, leave the
            // scroll alone — `defaultScrollAnchor(.bottom)` already
            // re-pins the latest bubble against the rising / shrinking
            // composer in lockstep with the safeAreaInset's height
            // change, all in one frame. Stacking a manual `proxy.scrollTo`
            // on top fired a second animation that landed on a stale
            // layout snapshot ~50ms later, producing the visible
            // "jump" the user reported when adding/removing a reply
            // (especially noticeable on media-bubble replies, where
            // ΔH is biggest because the reply row is taller). On
            // pre-17, no system anchor exists, so we still scroll
            // manually.
            // Re-anchor the chat to the bottom whenever the bottom
            // chrome grows: emoji panel opens, reply/edit context
            // appears in the pill, keyboard rises. Without this the
            // last bubble gets hidden under the new chrome — the
            // chat doesn't auto-anchor by itself once we've taken
            // `defaultScrollAnchor` off (it was causing snap-back
            // on user scroll-up). Animation duration matches the
            // 0.22s applied to the safeAreaInset's content above so
            // the scroll glides in lockstep with the inset growth.
            .onChange(of: showEmojiPanel) { _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: vm.replyTarget?.id) { _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: vm.editingTarget?.id) { _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
                if showEmojiPanel {
                    showEmojiPanel = false
                }
                // System keyboard rise is a 0.25s easeOut by default;
                // matching it on our scrollTo lets the chat content
                // glide up in sync with the keyboard instead of
                // landing in a different frame.
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            // Open the chat parked at the bottom anchor. Three-pass
            // retry: 0 / 50 / 200 ms covers the LazyVStack's lazy
            // realization without overlapping into a "user just
            // tapped the input field" window — the longer 700ms
            // tail of the previous loop fired manual scrollTo's
            // mid-keyboard-rise, which was the source of the "rise
            // резкий при первом заходе" jitter.
            .task {
                let delaysMs: [UInt64] = [0, 50, 200]
                for ms in delaysMs {
                    if ms > 0 {
                        try? await Task.sleep(nanoseconds: ms * 1_000_000)
                    }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
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

    /// Stable id for the bottom-of-thread anchor view used by both
    /// the initial scroll-to-latest on open and the floating
    /// scroll-to-bottom button.
    private static let bottomAnchorID = "__rcq_chat_bottom_anchor"

    // MARK: - report-with-evidence helpers

    /// Whether the long-press overlay should offer the "Report
    /// content" action for `message`. The contract:
    ///
    ///   • Must NOT be from the local user (you can't report
    ///     yourself; the row would be a UX dark pattern).
    ///   • Must be image media — `.photo` (any sender) or
    ///     `.premiumPhoto` IF unlocked. Video evidence is a v2
    ///     follow-up; MediaService doesn't yet expose raw decrypted
    ///     video bytes for upload.
    ///   • Must have a `mediaID` (sanity — bubbles in flight don't
    ///     have one yet).
    ///
    /// All other surfaces fall back to the existing reason-only
    /// `Report` action on the contact (lives in the chat header
    /// menu — added in the Block + Report rollout).
    private func shouldOfferEvidenceReport(_ message: Message) -> Bool {
        if message.isFromMe { return false }
        guard message.mediaID != nil else { return false }
        switch message.kind {
        case .photo:
            return true
        case .premiumPhoto:
            return message.premiumUnlocked
        default:
            return false  // video / voice / text / etc.
        }
    }

    /// Decrypts the media + re-encodes as JPEG, then sets
    /// `evidenceReportTarget` to fire the sheet. Pre-loading here
    /// (rather than inside the sheet) keeps the sheet itself a
    /// pure submit-only surface — no spinner, no failure-mid-sheet,
    /// no "open the sheet, see a placeholder, give up".
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
        case .premiumPhoto: raw = "🔒 \("chat.premium.preview_photo".localized)"
        case .premiumVideo: raw = "🔒 \("chat.premium.preview_video".localized)"
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

    /// Pill-style "only the owner can post" affordance. Replaces the
    /// composer in broadcast-mode groups for non-owners. Same height
    /// rhythm as the regular input bar so the layout doesn't pop.
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

    /// Telegram-style composer. Three pieces, bottom-aligned so side
    /// buttons stay glued to the last text line as the pill grows
    /// with multi-line input:
    ///
    ///   [📎 attach]   [ ───── pill field   ☺ ]   [🎤 mic / ➤ send]
    ///
    /// • Attach + Mic/Send sit OUTSIDE the field in 36pt glass
    ///   circles (system .ultraThinMaterial through the parent).
    /// • Smiley toggle lives INSIDE the pill on the trailing edge —
    ///   tap flips between system keyboard and the equipped-smileys
    ///   panel below.
    /// • Voice record gesture (hold-to-record, swipe-up to cancel) is
    ///   the SAME `micButton` from before — TG-style mechanics were
    ///   already correct, only the chrome changed.
    /// • While recording, the pill is replaced wholesale by the
    ///   `recordingPill` strip (red dot + timer + "↑ slide to cancel").
    /// True when the active thread is a Stranger-Mode pair. Hides
    /// every non-text affordance from the composer (attach button,
    /// mic / voice recording) so the surface enforces the
    /// text-only contract Apple's UGC guidance expects from
    /// random-matching surfaces. The chat row itself also strips
    /// links + phone numbers from outgoing text in this mode.
    private var isStrangerMode: Bool {
        if case .randomPeer = vm.target { return true }
        return false
    }

    private var inputBar: some View {
        let trimmed = vm.input.trimmingCharacters(in: .whitespaces)
        let showSend = !trimmed.isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            if voiceRecorder.isRecording {
                // Recording owns the whole row except the mic button
                // on the right (which stays so the user has a visual
                // anchor for the gesture).
                recordingPill
            } else {
                // Attach is hidden in stranger mode — the surface is
                // text-only by design (no media uploads, no voice
                // notes). Keeps the bar simpler and removes the
                // single biggest abuse vector.
                if !isStrangerMode {
                    attachButton
                }
                pillField
            }
            // Right-edge action. Stranger mode pins to send-only:
            // mic / voice are disabled, so the button never flips
            // into mic state. Greyed-disabled when text is empty.
            // Regular threads keep the original send ↔ mic swap.
            if isStrangerMode {
                sendButton
                    .opacity(showSend ? 1.0 : 0.4)
                    .disabled(!showSend)
                    .frame(width: 36, height: 36)
            } else {
                ZStack {
                    if showSend && !voiceRecorder.isRecording {
                        sendButton
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    } else {
                        micButton
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                .frame(width: 36, height: 36)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: showSend)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: voiceRecorder.isRecording)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Paperclip in a 36pt material-blur circle. iOS-system "attach"
    /// affordance — uses `.regularMaterial` so the wallpaper /
    /// chat-content behind reads through, matching the system-bar
    /// aesthetic of Messages / Telegram.
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

    /// Pill-shaped composer. Now hosts an OPTIONAL reply / edit
    /// context row INSIDE the pill (above the typing area), and a
    /// smiley toggle pinned to the trailing edge of the typing
    /// area. The pill's silhouette flips from `Capsule` to a
    /// rounded rect when the context row is present, so the top
    /// edge can carry the reply preview without the capsule
    /// curvature crowding it. Animation is on the context-row
    /// insert/remove so the pill grows / shrinks smoothly instead
    /// of jumping.
    private var pillField: some View {
        let hasContext = (vm.replyTarget != nil) || (vm.editingTarget != nil)
        return VStack(alignment: .leading, spacing: 0) {
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
                // Smiley toggle. Icon flips to "keyboard" while the
                // panel is open so the same button reads as "back to
                // typing" on the second tap.
                Button {
                    // Drive the opacity transition on emojiPanel via
                    // an animation context here. Without it the panel
                    // pops in/out without fade.
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showEmojiPanel.toggle()
                    }
                } label: {
                    Image(systemName: showEmojiPanel ? "keyboard" : "face.smiling")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.Color.textSecondary)
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
        }
        .background(
            Group {
                if hasContext {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
        )
        .overlay(
            Group {
                if hasContext {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                } else {
                    Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
            }
        )
        // No explicit `.animation(...)` here — the callers that flip
        // `vm.replyTarget` / `vm.editingTarget` already wrap the
        // assignment in `withAnimation(.spring(...))`. Adding a second
        // implicit animation modifier on this view stacked TWO
        // animation transactions on top of each other, which is what
        // produced the "lag when removing reply" + jitter the user
        // reported. The transitions on `inlineReplyContext` /
        // `inlineEditContext` still inherit from the caller's
        // withAnimation block, so the row-grow/shrink animation runs
        // exactly once.
    }

    /// Compact reply preview rendered INSIDE the pill at its top
    /// edge. Tapping × clears the reply target; the pill collapses
    /// back to a capsule via the spring animation on
    /// `vm.replyTarget?.id`.
    @ViewBuilder
    private func inlineReplyContext(_ message: Message) -> some View {
        let snippet = Self.replyPreview(for: message)
        let author = vm.senderNickname(message.senderUIN)
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
                Text(snippet)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                vm.replyTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Edit-mode context row, parallel to `inlineReplyContext`.
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
                vm.cancelEdit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Accent-green send button. White paperplane on the brand
    /// colour reads instantly as "go" — no ambiguity with the
    /// glass-circle aesthetic of the side affordances.
    private var sendButton: some View {
        Button { Task { await vm.send() } } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .rotationEffect(.degrees(45))  // TG-style angled send glyph
                .offset(x: -1, y: 1)           // optical centre after rotation
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.Color.accent))
        }
        .buttonStyle(.plain)
    }

    /// Hold-to-record mic. Press starts the recorder; lifting the
    /// finger sends the bubble. Dragging up past `voiceCancelOffset`
    /// arms a cancel — release in that state discards the recording.
    ///
    /// Visual is intentionally *static* between recording / idle
    /// states — no scaleEffect / spring animation. Earlier versions
    /// scaled the button up by 1.15 when recording, and the spring
    /// settle-period (~0.3s after every isRecording flip) caused
    /// 1-2px jitter at the messages/composer seam. The recordingPill
    /// (which replaces the text field) is the visual indicator that
    /// the gesture is live.
    ///
    /// 36pt glass circle to match the paperclip's chrome on the
    /// other side of the bar — symmetric weight reads cleanly.
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
                        if !voiceRecorder.isRecording && micDragOffset == 0 {
                            // First touch — kick the recorder. Permission
                            // prompt happens here on first ever use.
                            Task {
                                let ok = await voiceRecorder.start()
                                if !ok { voicePermissionDenied = true }
                            }
                        }
                        micDragOffset = value.translation.height
                        voiceCancelArmed = value.translation.height < -Self.voiceCancelOffset
                    }
                    .onEnded { _ in
                        let armed = voiceCancelArmed
                        micDragOffset = 0
                        voiceCancelArmed = false
                        if armed {
                            voiceRecorder.cancel()
                        } else if let result = voiceRecorder.finish() {
                            Task {
                                if let err = await vm.sendVoice(fileURL: result.url, durationSec: result.duration) {
                                    videoError = err
                                }
                            }
                        }
                    }
            )
    }

    /// In-bar overlay shown while the mic gesture is live. Pulsing
    /// red dot + elapsed timer + "↑ slide to cancel" hint. The whole
    /// strip flips red when the user has dragged past the threshold
    /// so the cancel-on-release state reads at a glance.
    ///
    /// Capsule shape matches the new pill-style text field — when
    /// recording starts the field morphs into this same outline so
    /// the bar's silhouette stays steady, only the contents change.
    private var recordingPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(voiceRecorder.elapsed.truncatingRemainder(dividingBy: 1.0) < 0.5 ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.5), value: voiceRecorder.elapsed)
            Text(formatRecordingDuration(voiceRecorder.elapsed))
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(voiceCancelArmed ? .red : Theme.Color.textPrimary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: voiceCancelArmed ? "trash.fill" : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                Text(voiceCancelArmed ? "Release to cancel" : "Slide up to cancel")
                    .font(.caption)
            }
            .foregroundColor(voiceCancelArmed ? .red : Theme.Color.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(
            Capsule().fill(
                voiceCancelArmed ? Color.red.opacity(0.12) : Theme.Color.bgSecondary.opacity(0.6)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                Theme.Color.divider.opacity(0.3), lineWidth: 0.5
            )
        )
    }

    private func formatRecordingDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let m = total / 60
        let s = total % 60
        let tenths = Int((secs - Double(total)) * 10)
        return String(format: "%d:%02d.%d", m, s, tenths)
    }

    private var emojiPanel: some View {
        // Floating rounded-card picker. Pulled INSIDE 8pt of
        // horizontal margin (vs the previous edge-to-edge keyboard-
        // style panel) so it reads as a discrete element above the
        // composer pill — same visual rhythm as the input bar's own
        // pieces. `.regularMaterial` matches the composer's
        // material; the chat wallpaper shows through the
        // surrounding margin so the card feels lifted, not nailed
        // to the screen edges.
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

    /// Default tab → Kolobok base set sorted by usage (most used
    /// first, then unused entries in their original order). Pack
    /// tabs → exactly that pack's entries (in manifest order).
    private func emoticonEntries(
        for tab: String?, equippedKinds: [ItemKind],
    ) -> [(asset: String, name: String, primaryCode: String)] {
        if let tabID = tab, equippedKinds.contains(where: { $0.id == tabID }) {
            return CosmeticPacks.entries(for: tabID).map {
                (asset: $0.asset, name: $0.name, primaryCode: $0.primaryCode)
            }
        }
        // Default tab — Kolobok set, frequency-sorted.
        let defaults = Emoticons.paletteAssets
        let usage = emoticonUsage.counts
        return defaults.sorted { a, b in
            let ca = usage[a.asset] ?? 0
            let cb = usage[b.asset] ?? 0
            if ca != cb { return ca > cb }
            return false  // stable for tied entries
        }
    }
}

/// On iOS 17+ pins the ScrollView's bottom edge to the viewport's
/// bottom across layout changes — so a growing safeAreaInset (reply
/// strip slides in, emoji panel pops up, keyboard rises) keeps the
/// latest bubble glued to the composer instead of drifting upward
/// while we wait for our own scrollTo handler to catch up.
///
/// Pre-iOS-17 falls through to the manual `anchorToLatest` calls
/// stitched onto each binding's `.onChange` — slightly less crisp
/// than the native anchor but no janky jump-after-settle.
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
        .padding(.vertical, 4)
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

private struct MessageRow: View {
    let message: Message
    let showSender: Bool
    let senderNickname: String
    /// Translation-aware body text — equal to `message.text` when no
    /// translation is active, or to the cached translated body when
    /// the user toggled "Translate" via long-press. Computed at the
    /// call site (`vm.displayText(for:)`) so MessageRow stays
    /// VM-agnostic.
    let displayBody: String
    /// `true` when `displayBody` is the translated version. Drives
    /// the small "Translated · tap to revert" footer under the bubble
    /// so the user never wonders why the text suddenly changed.
    let isTranslated: Bool
    /// True when this row was just selected from the in-chat search
    /// overlay — drives a brief accent-tinted background flash so the
    /// match is locatable inside a long thread. Reset by the host
    /// `ChatView` after the fade.
    let isHighlighted: Bool
    let onTapReaction: (String) -> Void
    let onLongPress: () -> Void
    /// Double-tap-anywhere shortcut for the most common reaction
    /// (the KOLOBOK "good" thumbs-up). Modeled after Telegram's
    /// double-tap-to-like — caller toggles, so a second double-tap
    /// clears it. Long-press path stays available for the full
    /// reaction palette + actions menu.
    let onDoubleTapLike: () -> Void
    /// Tap on the in-bubble reply quote-block jumps the chat to
    /// the original message (same scroll/flash mechanism the
    /// in-chat search uses). No-op if the original is no longer
    /// in the thread (expired, deleted, fell off the rehydrate
    /// cap) — caller decides.
    let onTapReplyQuote: (UUID) -> Void
    /// Swipe-left-on-bubble enters reply-mode for this message —
    /// same effect as picking Reply from the long-press menu, just
    /// faster. Caller decides what to do (typically set
    /// `vm.replyTarget`).
    let onSwipeReply: () -> Void

    /// Live x-offset of the bubble under finger during a leftward
    /// swipe. Snaps back to 0 on release; if the drag passed the
    /// trigger threshold first, `onSwipeReply` fires before the
    /// snap-back animation.
    @State private var swipeOffset: CGFloat = 0
    /// True once the current drag passed the trigger distance —
    /// gates the haptic feedback (one buzz per swipe, not
    /// continuous) and tells `onEnded` whether to fire reply.
    @State private var swipeArmed: Bool = false
    /// True while finger is held down on the bubble (during the
    /// long-press window). Drives a subtle scale-down on the
    /// bubble so the user gets an instant "pushed in" cue before
    /// the long-press menu actually fires. Cleared on release or
    /// when the menu pops.
    @State private var bubblePressed: Bool = false
    /// Drives the confirm-before-paying flow on a locked premium
    /// bubble. Set true when the user taps the in-bubble Unlock CTA;
    /// the `.confirmationDialog` shows the price + Pay/Cancel options.
    @State private var showUnlockConfirm: Bool = false
    /// Set by the unlock attempt when the server returns 402 / network
    /// error. Drives the `.alert` so the user sees why the unlock
    /// didn't go through (typically insufficient tokens).
    @State private var unlockError: String?
    /// True while the unlock POST is in-flight — disables the Pay
    /// button so the user can't double-charge themselves on a slow
    /// network.
    @State private var unlockInFlight: Bool = false

    /// Distance (px leftward) the bubble must travel before the
    /// reply trigger arms. Past this point the bubble decelerates
    /// (rubber-band) and the user gets a haptic confirmation that
    /// release-now would reply.
    private static let swipeTriggerDistance: CGFloat = 60
    /// Hard cap on bubble travel — past this, additional drag is
    /// absorbed (rubber-band feel) so the bubble can't slide
    /// arbitrarily off-screen.
    private static let swipeMaxDistance: CGFloat = 80

    var body: some View {
        if message.kind == .systemNotice {
            HStack {
                Spacer()
                Text(message.text)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                ZStack(alignment: .trailing) {
                    // Reveal icon — slides into view from behind the
                    // right edge as the bubble is dragged left. Opacity
                    // and scale ramp linearly with drag distance up to
                    // the trigger threshold; past it, the icon stays
                    // pegged + tinted-accent so the user has a clear
                    // "release-now-to-reply" affordance. Hidden when
                    // not actively swiping.
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
                        // Tap / long-press are scoped to the bubble
                        // itself — the wider row is the swipe-only
                        // hit target (see `.contentShape` below).
                        // Otherwise a double-tap on empty space next
                        // to a short incoming bubble would silently
                        // toggle a reaction.
                        bubble
                            .scaleEffect(bubblePressed ? 0.96 : 1.0, anchor: message.isFromMe ? .trailing : .leading)
                            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: bubblePressed)
                            .onTapGesture(count: 2) {
                                guard !message.deletedForEveryone, message.kind != .systemNotice else { return }
                                onDoubleTapLike()
                            }
                            .onLongPressGesture(
                                minimumDuration: 0.18,
                                pressing: { isPressing in
                                    // No haptic in `pressing:` — it
                                    // fires on every touch-down (incl.
                                    // taps and scroll-starts), which
                                    // made the chat feel buzzy. The
                                    // `onLongPress` parent already
                                    // fires medium-impact when the menu
                                    // actually arms.
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
                    HStack {
                        if message.isFromMe { Spacer(minLength: 40) }
                        ReactionsBar(message: message, onTap: onTapReaction)
                        if !message.isFromMe { Spacer(minLength: 40) }
                    }
                }
            }
            // Make the row span the full chat width so the swipe
            // gesture below has something to hit even when the
            // bubble itself is short. Without this an incoming
            // single-word bubble would only reply-arm if the user's
            // finger started on the ~30pt-wide bubble.
            .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
            // Search-hit flash. ~1.4s tinted band behind the bubble
            // row, fades out via the host's withAnimation when
            // `flashHighlightID` is cleared. Bare RoundedRectangle so
            // the bubble itself keeps its own corner radius.
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.Color.accent.opacity(isHighlighted ? 0.18 : 0))
            )
            // Make the entire row hit-testable for the swipe gesture
            // below. The transparent background above doesn't extend
            // the hit area, so without this `.gesture` only fires on
            // the bubble itself — the user has to actually touch the
            // bubble to swipe-reply, which is awkward for short
            // incoming messages. With `Rectangle` the empty Spacer
            // beside the bubble becomes a valid swipe target too.
            .contentShape(Rectangle())
            // Swipe-left → enter reply-mode for this bubble. Mirrors
            // Telegram/WhatsApp; faster path than long-press → Reply.
            // We require horizontal dominance over vertical so the
            // outer ScrollView's pan gesture still wins for diagonal
            // / vertical scrolls. Tombstones skip — nothing to reply
            // to once the original message is gone. Past the trigger
            // distance we fire one haptic; past `swipeMaxDistance`
            // the bubble decelerates instead of sliding off-screen.
            //
            // `.simultaneousGesture` (not `.gesture`) is what lets
            // iOS's screen-edge pan recognizer keep working — with
            // exclusive `.gesture`, this DragGesture claims every
            // horizontal touch on the row, including right-swipes
            // that originate near the leading edge, blocking the
            // system back-swipe so the user had to grab the very
            // last pixel of the screen edge to pop the chat.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard !message.deletedForEveryone, message.kind != .systemNotice else { return }
                        // Drags that originate near the leading edge
                        // are reserved for iOS's interactive-pop
                        // gesture (swipe right to back). Bailing on
                        // those before our recognizer claims them
                        // makes the back-swipe predictable from any
                        // starting Y rather than only at the very
                        // last 20pt the system natively reserves.
                        if value.startLocation.x < 32 {
                            if swipeOffset != 0 { swipeOffset = 0 }
                            swipeArmed = false
                            return
                        }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        // Vertical wins → bail; the ScrollView is
                        // probably handling the gesture as a scroll.
                        if abs(dy) > abs(dx) {
                            if swipeOffset != 0 { swipeOffset = 0 }
                            swipeArmed = false
                            return
                        }
                        // Right-swipes ignored — only left = reply.
                        if dx >= 0 {
                            if swipeOffset != 0 { swipeOffset = 0 }
                            swipeArmed = false
                            return
                        }
                        // Linear track up to the trigger distance,
                        // then rubber-band: each extra pixel of finger
                        // movement only moves the bubble half a pixel
                        // until we hit the hard cap.
                        let raw = -dx  // positive magnitude
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
                            // Drag retracted past the trigger — disarm
                            // so a second outward push re-fires the
                            // haptic cleanly.
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
            // Confirm-before-paying for paywalled-media unlock. Triggered
            // by the in-bubble Unlock CTA (PremiumLockedBubble.onUnlock).
            // Native confirmationDialog mirrors the destructive-action
            // pattern users already know from Delete-for-everyone.
            .confirmationDialog(
                String(format: "chat.premium.confirm.title".localized, message.premiumPriceTokens ?? 0),
                isPresented: $showUnlockConfirm,
                titleVisibility: .visible
            ) {
                Button(String(format: "chat.premium.confirm.pay".localized, message.premiumPriceTokens ?? 0)) {
                    Task { await performUnlock(message) }
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("chat.premium.confirm.body".localized)
            }
            .alert(
                "chat.premium.error.title".localized,
                isPresented: Binding(
                    get: { unlockError != nil },
                    set: { if !$0 { unlockError = nil } }
                ),
                actions: { Button("common.ok".localized, role: .cancel) {} },
                message: { Text(unlockError ?? "") }
            )
        }
    }

    private var bubble: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
            if showSender {
                Text(senderNickname)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
            }
            if let fwdName = message.forwardedFromName, !fwdName.isEmpty {
                // Forwarded-message attribution. Rendered above the
                // bubble's own content as a small italic note. Per
                // spec we only carry the nickname — no UIN, no
                // status — so a forwarded message can't double as a
                // contact-discovery vector.
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 9))
                    Text(String(format: "chat.forwarded_from".localized, fwdName))
                        .font(.caption2.italic())
                }
                .foregroundColor(Theme.Color.textSecondary)
            }
            if let snippet = message.replyToSnippet, !snippet.isEmpty {
                // Reply quote-block: vertical accent rule + author
                // + snippet, sits inside the bubble above the actual
                // content. The outer frame inherits the bubble's
                // side — incoming hugs `.leading`, outgoing hugs
                // `.trailing` — so the quote sits *over* the
                // sender's bubble instead of drifting to screen
                // centre. Earlier code hard-coded `.leading` which
                // looked correct only for incoming messages.
                //
                // The whole block is a `Button` so a tap jumps to
                // the original via `onTapReplyQuote`. `.buttonStyle(.plain)`
                // keeps the visual styling identical to the previous
                // non-tappable shape — only the hit-target is new.
                Button {
                    if let target = message.replyToID {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onTapReplyQuote(target)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Theme.Color.accent)
                            .frame(width: 2)
                        VStack(alignment: .leading, spacing: 1) {
                            if let author = message.replyToAuthorName, !author.isEmpty {
                                Text(author)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(Theme.Color.accent)
                                    .lineLimit(1)
                            }
                            Text(snippet)
                                .font(.caption2)
                                .foregroundColor(Theme.Color.textSecondary)
                                .lineLimit(2)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .frame(
                        maxWidth: 240,
                        alignment: message.isFromMe ? .trailing : .leading
                    )
                }
                .buttonStyle(.plain)
            }
            if message.receivedWhileAway {
                Text(String(format: "chat.received_while_away".localized, DateFormatters.receivedWhileAway.string(from: message.sentAt)))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .padding(.bottom, 2)
            }
            HStack(alignment: .bottom, spacing: 6) {
                bubbleContent
            }
            HStack(spacing: 4) {
                Text(DateFormatters.timeOfDay.string(from: message.sentAt))
                    .font(Theme.Font.timestamp)
                    .foregroundColor(Theme.Color.textSecondary)
                if message.editedAt != nil {
                    // "(edited)" suffix — surfaces the fact that
                    // body text isn't the original. Italic to match
                    // the visual weight of timestamps; deliberately
                    // not a full timestamp itself because the user
                    // mostly cares about "edited or not", not when.
                    Text("chat.edited_suffix".localized)
                        .font(Theme.Font.timestamp.italic())
                        .foregroundColor(Theme.Color.textSecondary)
                }
                if message.ttlSeconds != nil {
                    // Tiny clock badge on disappearing bubbles. No animation —
                    // a per-row countdown would burn battery for very little
                    // value at the typical TTL scale we offer (≥1 minute).
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.Color.textSecondary)
                }
                if message.isFromMe {
                    deliveryIcon
                }
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
            // Media bubbles render the image as the bubble itself — no surrounding
            // colored frame. Caption (if any) gets its own text bubble underneath.
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                PhotoBubble(message: message)
                if !displayBody.isEmpty {
                    EmoticonText(text: displayBody)
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
                    EmoticonText(text: displayBody)
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
        } else if message.kind == .premiumPhoto || message.kind == .premiumVideo {
            // Single component handles BOTH locked and unlocked states
            // so the unlock transition is a smooth in-place blur
            // dissolve rather than a hard swap to PhotoBubble. The
            // size is locked to the thumbnail's aspect so the bubble
            // never resizes on unlock.
            let size = Self.premiumBubbleSize(thumbnailB64: message.thumbnailB64)
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                PremiumLockedBubble(message: message, onUnlock: { askUnlock(message) }, size: size)
                if !displayBody.isEmpty {
                    EmoticonText(text: displayBody)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                        .cornerRadius(Theme.Metrics.bubbleRadius)
                    if isTranslated { translatedFooter }
                }
            }
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                EmoticonText(text: displayBody)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                    .cornerRadius(Theme.Metrics.bubbleRadius)
                if isTranslated { translatedFooter }
                // Telegram-style link preview attached underneath
                // when the message text carries a URL. Read off the
                // ORIGINAL body (`message.text`) so a translation
                // that omits / mangles the URL doesn't drop the
                // preview card.
                if let url = LinkDetector.firstURL(in: message.text) {
                    LinkPreviewCard(url: url)
                }
            }
        }
    }

    /// Tiny "Translated · tap to revert" footer under translated
    /// bubbles — the affordance Argus uses on its mission cards.
    /// Tapping it would normally clear the translation, but the
    /// row's tap surface is already claimed by reply-jump and
    /// long-press handlers; the user reverts via long-press →
    /// "Show original" instead. Footer is informational only.
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

    /// Compute the locked + unlocked bubble dimensions for a premium
    /// media message from the included thumbnail. Width is fixed at
    /// 240 (matches PhotoBubble's normal maxWidth); height derives
    /// from the thumbnail's aspect ratio, capped at 240×1.4 (336pt)
    /// so a very tall portrait photo doesn't dominate the chat. When
    /// no thumbnail is decodable, defaults to 4:3 — same fallback
    /// PhotoBubble's placeholder uses.
    fileprivate static func premiumBubbleSize(thumbnailB64: String?) -> CGSize {
        let width: CGFloat = 240
        let maxHeight: CGFloat = width * 1.4
        let defaultHeight: CGFloat = width * 0.75  // 4:3 fallback
        guard let b64 = thumbnailB64,
              !b64.isEmpty,
              let data = Data(base64Encoded: b64),
              let img = UIImage(data: data),
              img.size.width > 0, img.size.height > 0 else {
            return CGSize(width: width, height: defaultHeight)
        }
        let aspect = img.size.width / img.size.height
        let height = min(maxHeight, max(120, width / aspect))
        return CGSize(width: width, height: height)
    }

    /// Bridge from `PremiumLockedBubble.onUnlock` → confirmation. Two-
    /// step flow so the user can't lose tokens to an accidental tap:
    /// the in-bubble pill flips this flag, the parent `body` mounts a
    /// `.confirmationDialog` that asks "Pay N tokens?" before firing
    /// the actual `MessageService.unlockPremium` POST.
    fileprivate func askUnlock(_ message: Message) {
        showUnlockConfirm = true
    }

    /// Confirmed unlock — POST to `/premium/contents/{id}/unlock`,
    /// debit the wallet, splice the unwrapped key into the row.
    /// Errors land in `unlockError` so the parent `.alert` surfaces
    /// them (typically 402 insufficient tokens, sometimes a generic
    /// network failure).
    fileprivate func performUnlock(_ message: Message) async {
        if unlockInFlight { return }
        unlockInFlight = true
        defer { unlockInFlight = false }
        do {
            _ = try await MessageService.shared.unlockPremium(message: message)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch let APIError.http(402, body) {
            // Server's 402 detail JSON carries `required` + `have`. We
            // could parse for a precise message; for v1 a generic
            // "insufficient tokens" line is enough — the user can see
            // their balance from the wallet badge.
            _ = body
            unlockError = "chat.premium.error.insufficient".localized
        } catch APIError.http(404, _) {
            unlockError = "chat.premium.error.gone".localized
        } catch {
            unlockError = "chat.premium.error.generic".localized
        }
    }
}

/// In-flight report-with-evidence target. Carries the message being
/// reported AND the pre-decoded media bytes so `ReportEvidenceSheet`
/// can submit immediately. Identifiable via the message UUID for
/// SwiftUI's `.sheet(item:)` binding.
struct PendingEvidenceReport: Identifiable {
    let message: Message
    let bytes: Data
    let mime: String
    var id: UUID { message.id }
}
