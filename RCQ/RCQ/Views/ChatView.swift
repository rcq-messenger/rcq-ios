import AVFoundation
import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: ChatViewModel
    /// Write-only from this view (pendingJoinGroup* on link taps) — a plain
    /// accessor, NOT @StateObject: observing AppState re-ran this whole body
    /// (all visible rows) on every typingByUIN ping and every other AppState
    /// mutation anywhere in the app. The one read this view needs
    /// (typingByUIN for the open peer) arrives via vm.isPeerTyping.
    private var appState: AppState { AppState.shared }
    @StateObject private var contacts = ContactService.shared
    @StateObject private var aliasStore = ContactAliasStore.shared
    @StateObject private var groupSvc = GroupService.shared

    /// Member roster for the active group target, or `[]` for 1:1 chats.
    /// Drives @mention rendering + the composer's mention picker. Cached in
    /// the model (fed by GroupService) — the computed version here re-ran
    /// GroupService.find's linear scan on every call in every body pass.
    private var currentGroupMembers: [RCQGroupMember] { vm.groupMembers }

    private var activeGroupID: Int? {
        if case .group(let g) = vm.target { return g.id }
        return nil
    }

    /// A sender's row in the active group's roster — where their picture lives.
    private func groupMember(_ uin: Int?) -> RCQGroupMember? {
        guard let uin else { return nil }
        return currentGroupMembers.first { $0.uin == uin }
    }

    /// "Delete for everyone" is offered for your own message, OR (in a group)
    /// when you're a moderator: the owner, an admin, or a member the owner
    /// granted the `delete` cap (founder batch 21.08, item 3; web precedent:
    /// Chat.tsx canModerate). Recipients re-check the same rule on receipt
    /// against their own roster, so this button grants nothing the group did
    /// not already grant.
    private func canDeleteForEveryone(_ message: Message) -> Bool {
        // Saved messages: there is no "everyone" to delete for. Every message
        // there is your own, so the plain isFromMe rule below offered "Delete
        // for everyone" on a note to yourself — harmless (the send short
        // circuits) but a promise about a person who is not in the thread.
        if case .peer(let c) = vm.target, c.uin == AuthService.shared.ownUIN { return false }
        if message.isFromMe { return true }
        guard case .group(let snapshot) = vm.target else { return false }
        let live = groupSvc.find(snapshot.id) ?? snapshot
        guard let me = myUIN(in: live) else { return false }
        return live.moderator(me)
    }

    /// The island a group actually lives on, for one we joined as a GUEST on
    /// another island: its host plus the id it has over there. `nil` for a group
    /// on our own island.
    ///
    /// ⚠ A guest group is addressed locally by a NEGATIVE alias id
    /// (`VisitedIslandsStore.aliasFor`), which is not a group id anywhere on any
    /// island. Anything that talks to the server about the group has to
    /// translate back through here first - the same shape `MessageService` uses
    /// before it deposits a cross-island send.
    private func foreignGroupRef(_ group: RCQGroup) -> (host: String, remoteId: Int)? {
        guard let host = group.host,
              let ref = VisitedIslandsStore.shared.refByAlias(group.id) else { return nil }
        return (host, ref.remoteId)
    }

    /// Our own UIN *inside this group*. A guest group's roster, its `ownerUIN`
    /// and every permission on it are expressed in the HOST island's uin space,
    /// and our uin over there is the guest one, not the primary. Checking the
    /// primary uin against a foreign roster finds nobody, so every capability
    /// this screen asks about (pin, delete for everyone, may I post) quietly
    /// answered "no" in a cross-island group even for its owner.
    ///
    /// ⚠ Memoized, because `readOnlyGroup` below reads this from `body`.
    /// Resolving it for a guest group reaches UserDefaults and decodes the alias
    /// table, and doing that on every body pass of the chat screen is exactly
    /// the kind of per-render work this file has spent months taking back out. A
    /// reference box rather than `@State`, the same trick `CaretBox` uses here:
    /// the answer cannot change while one chat is open (same account, same
    /// group, same island) and filling it in should invalidate nothing.
    private func myUIN(in group: RCQGroup) -> Int? {
        if groupUINBox.groupID == group.id { return groupUINBox.resolved }
        let resolved: Int?
        if let ref = foreignGroupRef(group) {
            resolved = CrossIslandGroups.foreignCreds(host: ref.host, ownUIN: AuthService.shared.ownUIN)?.uin
        } else {
            resolved = AuthService.shared.ownUIN
        }
        groupUINBox.groupID = group.id
        groupUINBox.resolved = resolved
        return resolved
    }

    /// See `myUIN(in:)`. `groupID` doubles as the "already resolved" flag so a
    /// legitimately nil uin is not recomputed forever.
    private final class GroupUINBox {
        var groupID: Int?
        var resolved: Int?
    }
    @State private var groupUINBox = GroupUINBox()

    /// The live group behind the open target, or nil for a 1:1 / random thread.
    private var liveGroup: RCQGroup? {
        guard case .group(let snapshot) = vm.target else { return nil }
        return groupSvc.find(snapshot.id) ?? snapshot
    }

    /// The group this viewer may not post in, or nil when they may.
    ///
    /// `ChatTarget` used to carry this rule, asked with the PRIMARY uin. On a
    /// guest island that is the wrong number: the roster is written in the host
    /// island's uin space, so the owner of a foreign group was told they could
    /// not post in it. Asked here with `myUIN(in:)` instead, and the version on
    /// `ChatTarget` is gone so nobody can reach for the wrong one.
    private var readOnlyGroup: RCQGroup? {
        guard let live = liveGroup else { return nil }
        guard let me = myUIN(in: live) else { return nil }
        return live.canPost(me) ? nil : live
    }

    // MARK: - Room rules

    /// Exempt from this room's content rules - links off, files off, slow mode:
    /// the owner, an admin, or a member holding ANY granted cap.
    ///
    /// This is not a house rule of the client. It is the set the ISLAND
    /// exempts (`_enforce_group_slowmode` in `messages.py`: owner, `role ==
    /// "admin"`, or a non-empty `permissions`), and the set the web composer
    /// keys on (`roomExempt` in `Chat.tsx`). Matching it exactly is the whole
    /// point: a composer that gates where the server does not takes an ability
    /// away from a moderator, and one that does not gate where the server does
    /// promises a send the island answers with a 429.
    ///
    /// ⚠ Asked with `myUIN(in:)`, never the primary uin: a guest group's
    /// roster, its `ownerUIN` and every permission on it live in the HOST
    /// island's uin space. See `readOnlyGroup` for the same trap.
    ///
    /// A 1:1 or a stranger thread has no room, so it is exempt by definition.
    /// A member whose roster has not been fetched yet is NOT exempt: the list
    /// is polled `?members=0` and `members` can legitimately be empty, so
    /// "nobody found" has to mean "no cap", the same answer the island gives.
    private var roomExempt: Bool {
        guard let live = liveGroup else { return true }
        guard let me = myUIN(in: live) else { return false }
        if me == live.ownerUIN { return true }
        guard let mine = live.members.first(where: { $0.uin == me }) else { return false }
        return mine.role == "admin" || !mine.permissions.isEmpty
    }

    /// The owner-set rules of the open room, already resolved for this viewer.
    ///
    /// Read as ONE value rather than three computed properties because every
    /// one of them would re-run `liveGroup` (a linear scan of the group list)
    /// and `roomExempt` on every body pass, and the message list reads it per
    /// render. Call sites bind it once and pass the booleans down.
    ///
    /// ⚠ A cross-island group is addressed by a NEGATIVE alias id that the
    /// rules map is not keyed by (`GroupService.roomRules` is filled from the
    /// own-island `/groups` payload only), so a guest room reads as fully
    /// permissive. That is the same answer an island that predates the fields
    /// gives, and it fails OPEN: the host island still refuses what it refuses.
    private var roomPolicy: (linksAllowed: Bool, filesAllowed: Bool, slowmodeSec: Int) {
        guard let live = liveGroup, !roomExempt else { return (true, true, 0) }
        let rules = groupSvc.rules(live.id)
        return (rules.linksAllowed, rules.filesAllowed, rules.slowmodeSec)
    }

    private var linksAllowed: Bool { roomPolicy.linksAllowed }
    private var filesAllowed: Bool { roomPolicy.filesAllowed }

    /// Does [text] carry something a links-off room refuses? Same test the web
    /// runs before it hands a draft to the wire (`/https?:\/\//i`), plus the
    /// `rcq://` group-invite scheme, which is a link by any other name.
    private static func carriesLink(_ text: String) -> Bool {
        text.range(of: "(?:https?://|rcq://)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Gate every outgoing path on the room's rules. Returns true when the send
    /// must NOT happen, having said why.
    ///
    /// It sits on the send paths and not inside the envelope builder on
    /// purpose: a retry of an old row, or a re-send of something already in the
    /// log, must never be eaten by a rule the room only just grew.
    ///
    /// `isAttachment` is a document, a photo, a video or a GIF: `files_allowed`
    /// is one rule for every attachment on every client (founder, 2026-09-02).
    /// A voice note is NOT one - it is a spoken message - so the mic path asks
    /// with the default and stays open in a files-off room.
    private func roomRulesBlockSend(text: String? = nil, isAttachment: Bool = false) -> Bool {
        let policy = roomPolicy
        if let text, !policy.linksAllowed, Self.carriesLink(text) {
            roomRuleNotice = "chat.links_off.notice".localized
            return true
        }
        if isAttachment, !policy.filesAllowed {
            roomRuleNotice = "chat.files_off.notice".localized
            return true
        }
        guard policy.slowmodeSec > 0, let gid = activeGroupID else { return false }
        let left = Int(ceil(SlowmodeClock.until[gid].map { $0.timeIntervalSinceNow } ?? 0))
        if left > 0 {
            roomRuleNotice = String(format: "chat.slowmode.wait".localized, left)
            return true
        }
        return false
    }

    /// Start the room's cooldown once a send leaves. Armed at initiation, not
    /// on the receipt: the point is pacing the person, not their network.
    private func armSlowmode() {
        let sec = roomPolicy.slowmodeSec
        guard sec > 0, let gid = activeGroupID else { return }
        SlowmodeClock.until[gid] = Date().addingTimeInterval(TimeInterval(sec))
    }

    /// Refuse a picture at the door of the pending strip, not only at Send: a
    /// paste, or a sheet that was already open when the owner flipped the
    /// switch, hears the sentence as the picture arrives instead of after it
    /// sat in the strip. Only the files rule is asked here, on purpose: slow
    /// mode paces the SEND, and a pick made during the pause is not a send.
    private func attachmentRefused() -> Bool {
        if filesAllowed { return false }
        roomRuleNotice = "chat.files_off.notice".localized
        return true
    }

    /// Owner / info-moderator may pin a chat message into the group's single
    /// pin slot. Only in groups (1:1 has no pin).
    private func canPinMessage() -> Bool {
        guard let live = liveGroup, let me = myUIN(in: live) else { return false }
        return live.members.first { $0.uin == me }?.canManageInfo(ownerUIN: live.ownerUIN) == true
    }

    /// The plaintext that goes into the pin slot for a message: its text/caption,
    /// or a short attachment label for media without text (the slot is plaintext
    /// by design so new joiners see it before key exchange). Cut to the slot the
    /// server has: a longer body is a 422, and a 422 leaves the OLD pin up.
    private func pinTextFor(_ message: Message) -> String {
        // ⚠ Two kinds keep something in `text` that is NOT the prose the
        // bubble shows, and the pin slot is plaintext on the island so new
        // joiners can read it before key exchange.
        //   `.poll`  rows received before the removal still hold the whole
        //            PollPayload JSON there (question, options, and the
        //            anonymous flag), while the bubble draws "no longer
        //            supported". Pinning one would publish the body of a poll
        //            marked anonymous, in the clear, to the whole room.
        //   `.relay` holds an rcq-relay:// token, credentials included.
        // Both pin as the label their bubble shows instead.
        switch message.kind {
        case .poll:  return "chat.poll.removed".localized
        case .relay: return "relay.share.title".localized
        default:     break
        }
        let t = GroupService.clampPinnedText(message.text)
        if !t.isEmpty { return t }
        return "chat.pin.attachment".localized
    }

    private func pinMessage(_ message: Message) {
        guard case .group(let snapshot) = vm.target else { return }
        let live = groupSvc.find(snapshot.id) ?? snapshot
        let text = pinTextFor(message)
        let previous = live.pinnedText
        // Optimistic + instant: swap the displayed pin right away, expand the
        // banner so the change is obvious, then PATCH (which reconciles via
        // upsert). Makes the new pin replace the old one immediately.
        groupSvc.applyPinnedTextLocally(groupID: snapshot.id, pinnedText: text)
        expandPin(groupID: snapshot.id)
        let foreign = foreignGroupRef(live)
        let me = AuthService.shared.ownUIN
        Task {
            do {
                if let foreign {
                    // ⚠ Cross-island / guest group. `GroupService.setPinnedText`
                    // PATCHes OUR island at `/groups/<id>`, and this group's
                    // local id is a negative alias, so that request asked our
                    // own island to change a group it has never heard of.
                    // Pinning here could not work at all: the call failed, the
                    // optimistic swap was rolled back, and the pin read as one
                    // that "does not replace anything". Send it to the island
                    // the group lives on, with the guest token.
                    try await ChatPinRouting.setForeignPinnedText(
                        host: foreign.host,
                        remoteId: foreign.remoteId,
                        ownUIN: me,
                        pinnedText: GroupService.clampPinnedText(text)
                    )
                } else {
                    try await groupSvc.setPinnedText(groupID: snapshot.id, pinnedText: text)
                }
            } catch {
                // A rejected pin used to be invisible: the optimistic swap stayed
                // on screen until the next poll quietly put the old text back, so
                // pinning read as "it just does not replace anything". Undo the
                // swap and say so.
                groupSvc.applyPinnedTextLocally(groupID: snapshot.id, pinnedText: previous ?? "")
                pinError = GroupService.pinFailureMessage(error)
            }
        }
    }

    // Per-bubble view counts used to live here: an eye-count under every
    // owner post in a broadcast group, fed by a server-side table that
    // recorded which member had read which message. That table is exactly the
    // kind of per-person metadata this app exists to not keep, so the island
    // dropped it and the endpoints with it. Nothing replaces the badge.

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
        MessageActionOverlay(
            message: target,
            senderNickname: vm.senderNickname(target.senderUIN),
            canDeleteForEveryone: canDeleteForEveryone(target),
            canReply: replyAllowed,
            canEdit: target.isFromMe
                && !target.deletedForEveryone
                && Self.editableKinds.contains(target.kind),
            onReact: { asset in vm.toggleReaction(asset, on: target) },
            onReply: {
                let copy = target
                // Deferred so the action overlay is off screen first — asking
                // for the keyboard while it is still up gets the focus taken
                // straight back off the composer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    beginReply(to: copy)
                }
            },
            onEdit: {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        vm.startEdit(copy)
                    }
                    // Reply raises the keyboard; edit left it down and the
                    // chip sat over an unfocused field.
                    composerFocusToken &+= 1
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
            onPin: canPinMessage() ? {
                let copy = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pinMessage(copy) }
            } : nil,
        )
    }

    private var mentionCandidates: [RCQGroupMember] {
        // The `@partial` tail token is parsed in the model (it depends on
        // the composer text, which this body no longer observes per
        // keystroke); the picker just filters the roster against it.
        guard let q = vm.activeMentionQuery else { return [] }
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
                                Text(verbatim: "\(m.uin)")
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
        guard let q = vm.activeMentionQuery else { return }
        let ns = vm.input as NSString
        vm.setInput(ns.replacingCharacters(in: q.range, with: "@\(m.nickname) "))
    }
    @StateObject private var randomChat = RandomChatService.shared
    @StateObject private var calls = CallService.shared
    @StateObject private var chatSettings = ChatSettingsStore.shared
    @StateObject private var emoticonUsage = EmoticonUsageStore.shared
    @StateObject private var emojiPrefs = EmoticonPrefsStore.shared
    @StateObject private var chatBackground = ChatBackgroundStore.shared
    @Environment(\.colorScheme) private var colorScheme

    /// How this screen's own chrome paints itself over the chat wallpaper.
    ///
    /// The same rule the home screen decides by (`WallpaperSurface.mode`): flat
    /// when no wallpaper is set, so nothing moves for the people who never set
    /// one; translucent over a blur when one is, so the picture reads through
    /// the chrome instead of being visible only around it; and the theme
    /// reasserted when, and only when, a CUSTOM image has been measured to
    /// stand on the wrong side of the active theme. The built-in presets can
    /// never get there, they are authored per theme.
    private var wallpaperSurfaceMode: WallpaperSurface {
        chatBackground.surface(home: false, isLightTheme: colorScheme == .light)
    }

    /// Ground for the round floating buttons over the message list.
    ///
    /// `.ultraThinMaterial` alone takes its tone from what is BEHIND it, which
    /// over a wallpaper is the wallpaper: a white photo under the dark theme
    /// turns the disc light while the glyph on it stays `textPrimary` (#EDEDED),
    /// and the button is gone. That is the empty-chat CTA's bug one layer up,
    /// so only that case gets the theme colour put back; every other case draws
    /// exactly what it draws today.
    private var floatingButtonGround: some View {
        Circle()
            .fill(Theme.Color.bgPrimary.opacity(
                wallpaperSurfaceMode == .reasserted ? WallpaperSurface.reasserted.tint : 0
            ))
            .background(.ultraThinMaterial, in: Circle())
    }
    @State private var showEmojiPanel = false
    @State private var showEmojiPicker = false
    @State private var showInfo = false
    @State private var showAttachmentMenu = false
    /// The keyboard was up when the paperclip was tapped, so it comes back
    /// when the sheet goes (Telegram returns it; we left the field cold).
    @State private var keyboardUpBeforeAttach = false
    /// A send just happened: the arrow holds its place briefly so a second
    /// tap lands on nothing rather than on the microphone.
    @State private var sendHold = false
    /// The smiley was tapped while the keyboard was up: the panel opens in
    /// keyboardWillHide, so the two SWAP instead of stacking.
    @State private var emojiPanelAfterKeyboard = false
    // Per-conversation screen-secure: whether protection is currently armed
    // for this open chat, plus the live screenshot-detection observer token.
    @State private var screenSecured = false
    @State private var screenshotObserver: NSObjectProtocol?

    /// True only for a 1:1 thread that has screen-secure mode on.
    private var threadIsSecure: Bool {
        if case .peer = vm.target.thread { return chatSettings.isSecure(thread: vm.target.thread) }
        return false
    }

    /// Arm or disarm screen-secure for this open chat to match its flag —
    /// called on appear and whenever the flag flips (local toggle or a peer
    /// `secureScreen` arriving while we're viewing).
    private func reconcileScreenSecure() {
        if threadIsSecure, !screenSecured {
            ScreenSecurity.shared.enterChat()
            installScreenshotObserver()
            screenSecured = true
        } else if !threadIsSecure, screenSecured {
            teardownScreenSecure()
        }
    }

    private func teardownScreenSecure() {
        guard screenSecured else { return }
        ScreenSecurity.shared.leaveChat()
        if let o = screenshotObserver {
            NotificationCenter.default.removeObserver(o)
            screenshotObserver = nil
        }
        screenSecured = false
    }

    private func installScreenshotObserver() {
        guard screenshotObserver == nil, case .peer(let snap) = vm.target else { return }
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let live = ContactService.shared.contacts.first(where: { $0.uin == snap.uin }) ?? snap
                await MessageService.shared.reportScreenshot(to: live)
            }
        }
    }
    // Polls (14a) and in-chat relay sharing (14b) both used to open a composer
    // from here. Both compose paths are gone; see `MessageRow` for what an
    // incoming one of either still does.
    @State private var showShareGroupPicker: Bool = false
    @State private var headerShowsLastSeen: Bool = false
    @State private var showLocationPicker: Bool = false
    @State private var showTTLPicker = false
    @State private var showInChatSearch = false
    @State private var showAllMedia = false
    @State private var pendingScrollID: UUID?
    /// #1 reply-jump return: the reply message the user was reading when they
    /// tapped its quote, so the scroll-to-bottom chevron takes them BACK there
    /// (Telegram-style) instead of all the way to the latest message.
    @State private var replyReturnID: UUID?
    @State private var flashHighlightID: UUID?
    /// Cursor into `mentionIDs` for the @-mention jump FAB. Each tap steps to
    /// the next mentioning message and wraps around.
    @State private var mentionCursor: Int = 0
    @State private var videoError: String?
    /// Non-nil = the last pin-from-chat was refused and the banner has been put
    /// back to what it showed before. Shown as an alert; silence here is what
    /// made a rejected pin look like a pin that simply did not replace.
    @State private var pinError: String?
    /// Non-nil = the composer refused a send because of the room's rules
    /// (links off, files off, slow mode still running). Said as a sentence
    /// rather than swallowed: the alternative is a send that simply does not
    /// happen, or the raw 429 the island answers with.
    @State private var roomRuleNotice: String?
    @State private var composerHeight: CGFloat = 36
    /// Tracks the last seen `composerHeight` so the scroll handler can
    /// detect SHRINK (send cleared a long draft) vs GROW (typing into
    /// a wrapping line). Only shrink triggers a re-anchor — growing
    /// the composer mid-typing already plays nicely with the system.
    @State private var lastComposerHeight: CGFloat = 36
    /// Mirror of VoiceRecorder.isRecording, fed by onReceive with
    /// removeDuplicates — the input bar only branches on the flag.
    /// Observing the recorder (or the player) as @StateObject here made
    /// their 10-20Hz elapsed/level ticks re-run this whole body; the live
    /// numbers now render inside VoiceRecordingPill / VoicePreviewPill,
    /// which observe those singletons themselves.
    @State private var isVoiceRecording = false
    /// Kinds whose caption/text can be edited. Must stay in sync with
    /// the editable set in `MessageStore.applyEdit`.
    private static let editableKinds: [MessageKind] =
        [.text, .photo, .video, .file]
    /// Non-nil = the pinned-announcement expansion sheet is open.
    @State private var pinnedExpansion: PinExpansion?
    /// Measured natural height of the expanded-pin content, so the pin's
    /// ScrollView shrinks to fit short pins instead of always reserving the
    /// 240pt cap (#13). Capped at 240 with scroll beyond.
    @State private var pinContentHeight: CGFloat = 0
    /// Non-nil = a `#<uin>` mention in the pin (for a current group member)
    /// was tapped; opens that member's profile.
    @State private var pinnedMemberUIN: Int?
    /// Per-group set of pins the user has COLLAPSED (not dismissed).
    /// In the collapsed state the banner shrinks to a single-line
    /// pin-icon strip that the user can tap to expand back. Persisted
    /// across launches via UserDefaults so the collapse state survives
    /// app restart but never "permanently" removes the pin.
    @State private var collapsedPinGroups: Set<Int> = Set(
        (UserDefaults.standard.array(forKey: "rcq.pin.collapsed_groups") as? [Int]) ?? []
    )
    struct PinExpansion: Identifiable {
        let id = UUID()
        let text: String
        // The pinned group's host, so bare `/g/<id>` links inside the pin
        // resolve to the SAME island the group lives on (cross-island cards).
        var host: String? = nil
    }

    struct MentionTarget: Identifiable {
        var id: Int { uin }
        let uin: Int
    }

    /// Finished recording awaiting user's send / re-listen / discard
    /// decision. Non-nil → input bar shows `previewPill`.
    @State private var pendingVoicePreview: PendingVoicePreview?
    @State private var voicePermissionDenied: Bool = false
    /// Caret position in the composer, in plain-string units. Mirrored
    /// from EmoticonTextField via caretPlainLocation. The emoji panel
    /// splices a shortcode at this index instead of appending to the
    /// end of input — previously every smiley landed at the end no
    /// matter where the user had placed the cursor.
    ///
    /// A reference box behind a hand-rolled Binding, NOT `@State Int`:
    /// the caret moves on every keystroke, and a caret write into @State
    /// re-ran this whole body per character even after the composer text
    /// itself stopped being observed. Nothing in any body READS the
    /// caret — it's only consulted inside the splice actions — so its
    /// movement doesn't need to invalidate anything.
    private final class CaretBox { var value: Int = 0 }
    @State private var composerCaret = CaretBox()
    private var composerCaretBinding: Binding<Int> {
        Binding(
            get: { composerCaret.value },
            set: { composerCaret.value = $0 }
        )
    }
    /// Bumped whenever something should hand the keyboard to the composer
    /// without the user tapping it — today that is only "reply". Swiping a
    /// message (or picking Reply in its menu) used to set `vm.replyTarget`
    /// and nothing else, so the reply chip appeared over an unfocused
    /// composer and the answer could not be typed until you tapped the field.
    ///
    /// A token rather than @FocusState: the composer is `EmoticonTextField`,
    /// a UIViewRepresentable around UITextView, and SwiftUI's focus binding
    /// does not reach inside a representable. The token changing is what the
    /// representable watches to call `becomeFirstResponder()`.
    @State private var composerFocusToken: Int = 0

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

    /// Mentions the user hasn't stepped to yet (ids live in vm.mentionIDs,
    /// derived off the view's render path). The @-FAB steps WITHOUT
    /// wrapping and HIDES at 0 — tapping the last mention dismisses it instead
    /// of leaving the FAB up forever with the full count (the "собачка always
    /// shows" bug). A new inbound mention grows the list past the cursor and
    /// brings the FAB back for it.
    private var mentionsLeft: Int { max(0, vm.mentionIDs.count - mentionCursor) }

    /// Scroll to `id` (centered) and pulse the transient bubble highlight,
    /// clearing it after the same 1.4s window the reply-jump uses. Shared by
    /// the mention-jump FAB and the reaction-jump-on-open.
    @MainActor private func jumpAndFlash(to id: UUID, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(id, anchor: .center)
        }
        withAnimation(.easeIn(duration: 0.2)) {
            flashHighlightID = id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if flashHighlightID == id {
                withAnimation(.easeOut(duration: 0.5)) {
                    flashHighlightID = nil
                }
            }
        }
    }
    /// Jump-down arrow visibility. Driven by the bottom sentinel's
    /// onAppear/onDisappear (lifecycle events — reliable on iOS 26, unlike
    /// the geometry probes/onScrollGeometryChange that regressed it). On
    /// open scrolled to an unread message the `.task` insurance turns it on.
    @State private var showScrollToBottom: Bool = false
    /// Hides the scroll surface during the initial settle window so
    /// users don't see LazyVStack realizing rows on chat-open. Lifted
    /// by whichever proves the open position first: the bottom
    /// sentinel realizing (geometry — the common open-at-bottom case)
    /// or the `.task` insurance after the settle re-check (open-at-
    /// unread, where the sentinel may never materialize). From then on
    /// the chat stays visible across the lifetime of the screen.
    @State private var chatVisible: Bool = false
    /// True once the `.task` has re-asserted the open position. Until then a
    /// realizing bottom sentinel is not proof of anything — see its onAppear.
    @State private var settleDone: Bool = false
    /// The opening position is chosen once, on the first appear. See the guard
    /// at the top of the settle task.
    @State private var didSettleOpen: Bool = false

    /// Lift the initial-settle mask exactly once, first caller wins.
    @MainActor private func revealChat() {
        guard !chatVisible else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            chatVisible = true
        }
    }
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

    enum AttachAction { case media, camera, document, location }

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
    /// Long-pressing a reaction chip opens a "who reacted" sheet for this message.
    @State private var reactorsSheetMessage: Message?
    @State private var evidenceReportTarget: PendingEvidenceReport?

    init(target: ChatTarget) {
        _vm = StateObject(wrappedValue: ChatViewModel(target: target))
    }

    init(contact: Contact) {
        _vm = StateObject(wrappedValue: ChatViewModel(target: .peer(contact)))
    }

    // Per-chat PIN lock: when this chat is locked + a PIN is set, the content is
    // hidden behind a PIN gate until the real PIN is entered (cancel pops back).
    @State private var chatPinUnlocked = false
    @State private var showChatLockGate = false
    private var chatIsLocked: Bool {
        guard PanicPINService.shared.isConfigured else { return false }
        switch vm.target {
        case .peer(let c): return LockedChatsStore.shared.contains(peer: c.uin)
        case .group(let g): return LockedChatsStore.shared.contains(group: g.id)
        case .randomPeer: return false
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Color.bgPrimary.ignoresSafeArea()
            // Global chat wallpaper behind the messages (Android parity). Renders
            // nothing on the default ("") so the theme bg shows through.
            ChatBackgroundView().ignoresSafeArea()

            messageScroll

            // Pinned announcement floats inside the chat ZStack as a
            // capsule at the top — this places it BELOW the action
            // overlay's `.regularMaterial` during long-press (because
            // both live inside the same ZStack), so the pin reads as
            // "under the blur" automatically. Previously the pin sat
            // outside the ZStack via `safeAreaInset(.top)` and stayed
            // brightly visible above an otherwise-blurred chat.
            pinnedBanner
                .padding(.horizontal, 10)
                .padding(.top, 6)

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
                    // `chat.typing` has carried the "%@ is typing" wording in
                    // all seven catalogues the whole time; this call site was
                    // simply built by hand and never asked for it, so the one
                    // line of chat chrome that names a person stayed English
                    // for every non-English user.
                    TypingIndicator(label: "chat.typing".localized(
                        aliasStore.displayName(for: c.uin, fallback: c.nickname)
                    ))
                    // ⚠ Animated in and out. Inserted bare, this line stepped
                    // the whole bar up 22pt with no motion the moment the peer
                    // started typing and dropped it again when they stopped,
                    // the most frequent "the field twitches" in a 1:1 chat.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if case .randomPeer(let peer) = vm.target {
                    randomCTAStrip(peer: peer)
                }
                if vm.isSelecting {
                    selectionActionBar
                } else if readOnlyGroup != nil {
                    // A composer you cannot type in, NOT a strip of text where
                    // the composer was (24). Two reasons. The screen keeps the
                    // shape every other chat has, so "I cannot write here" is
                    // read off a greyed-out field the way it is read everywhere
                    // else on the platform, instead of off a sentence. And the
                    // bar keeps taking part in layout: the message list's bottom
                    // inset comes from whatever this branch renders, and the
                    // composer's own `composerHeight` only ever moves while
                    // `EmoticonTextField` is mounted - swapping in a shorter
                    // notice moves the seam under the list for no reason the
                    // reader can connect to anything.
                    readOnlyComposer
                } else {
                    if !vm.pendingMedia.isEmpty {
                        // No explicit background — tiles float over the
                        // chat content so the strip reads as a draft
                        // tray rather than a docked panel.
                        pendingMediaStrip
                            // ⚠ Animated in and out: the strip stepped the bar
                            // by 80pt in one frame on attach and again on send
                            // (audit, 05.09).
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    mentionPicker
                    inputBar
                }
                if showEmojiPanel {
                    emojiPanel
                }
            }
            .animation(.easeOut(duration: 0.22), value: showEmojiPanel)
            .animation(.easeOut(duration: 0.18), value: vm.isPeerTyping)
            .animation(.easeOut(duration: 0.18), value: vm.pendingMedia.isEmpty)
        }
        .modifier(ChatRoomChrome(target: vm.target, notice: $roomRuleNotice, vm: vm))
        // ⚠⚠ ONE place speaks a refusal, for every send path. The composer's
        // own gate above catches what this client can see coming (slow mode it
        // is counting down itself, links, files); this catches what only the
        // ISLAND knows - the newcomer waiting period, and slow mode after a
        // relaunch, when our countdown is empty. Photo, voice, file, share and
        // retry all go through the same detached send, so they get the sentence
        // too instead of answering a room rule with a red bubble (#836).
        .onReceive(SendRefusalStore.shared.$latest.compactMap { $0 }) { _ in
            if let sentence = SendRefusalStore.shared.take() { roomRuleNotice = sentence }
        }
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
        .sheet(isPresented: $showEmojiPicker) {
            EmoticonPickerSheet()
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
        .sheet(isPresented: $showAttachmentMenu, onDismiss: handleAttachDismiss) { attachmentSheet }
        .sheet(isPresented: $showShareGroupPicker) { shareGroupSheet }
        .sheet(isPresented: $showLocationPicker) { locationSheet }
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
        .alert("chat.pin.error.title".localized, isPresented: Binding(
            get: { pinError != nil },
            set: { if !$0 { pinError = nil } }
        )) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(pinError ?? "")
        }
        // Lives at body root — nested alert modifiers cause layout-pass jitter at the composer seam.
        .alert("chat.voice.permission.title".localized, isPresented: $voicePermissionDenied) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text("chat.voice.permission.body".localized)
        }
        // Per-chat PIN: cover the content + present the gate until unlocked.
        .overlay {
            if chatIsLocked && !chatPinUnlocked {
                Theme.Color.bgPrimary.ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showChatLockGate, onDismiss: {
            if !chatPinUnlocked { dismiss() }   // cancelled → leave the chat
        }) {
            PINVerifySheet(title: "pin_verify.title.chat".localized) { chatPinUnlocked = true }
        }
        .task {
            // The chat list is fetched without rosters, and this screen needs
            // one for more than sending: an author's name, an @mention, and a
            // moderator's own delete/pin rights all come out of the roster, and
            // without it the screen shows bare uins where names belong. A no-op
            // when it is already here or the group lives on another island.
            if let gid = activeGroupID { await groupSvc.ensureRoster(gid) }
        }
        .onAppear {
            if chatIsLocked && !chatPinUnlocked { showChatLockGate = true }
            // The unread-below badge counter is seeded in ChatViewModel.init
            // (#15) — onAppear is too late, rows realize before it runs.
            vm.onAppear()
            // Per-conversation screen-secure: arm blanking + screenshot
            // detection only if THIS chat has secure mode on.
            reconcileScreenSecure()
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
        }
        .onDisappear {
            teardownScreenSecure()
            MessageBannerService.shared.clearActiveIfMatches(vm.target.thread)
            // Leaving from the bottom means the thread was read to its end,
            // which is what the next open needs to know to land at the bottom
            // instead of hunting for an unread that is not there.
            vm.noteLeavingChat()
            // Persist the reading spot NOW (13a) - a scroll that came to rest
            // inside the 300ms debounce window would otherwise be lost when
            // the VM goes away with the popped screen - and then stop
            // tracking, so the rows reporting out during teardown can't be
            // mistaken for the reader scrolling. Resumes on the pop back from
            // a push, when rows realize again.
            vm.endReadPosTracking()
            // Mark every currently-loaded @mention as seen so the @-jump FAB
            // doesn't resurface for them when this read thread is reopened.
            if vm.target.thread.isGroup {
                let me = AuthService.shared.ownUIN ?? -1
                if let newest = vm.messages
                    .filter({ $0.senderUIN != me && MessageService.shared.bodyMentionsMe($0.text) })
                    .map({ $0.sentAt }).max() {
                    MentionSeenStore.shared.markSeen(group: vm.target.thread.rawKey, upTo: newest)
                }
            }
        }
        .onChange(of: chatSettings.secureByThread) { _ in reconcileScreenSecure() }
        .onReceive(VoiceRecorder.shared.$isRecording.removeDuplicates()) { isVoiceRecording = $0 }
        // The seen cut-off advancing (nav push fires onDisappear → markSeen)
        // empties mentionIDs while the cursor keeps its old position, and a
        // NEW mention then hid behind max(0, count - cursor) forever. Any
        // shrink below the cursor means the cut-off moved, so everything
        // remaining is unseen — start stepping from the first again.
        .onChange(of: vm.mentionIDs) { ids in
            if ids.count < mentionCursor { mentionCursor = 0 }
        }
        .modifier(InPlaceTranslator(vm: vm))
        .sheet(isPresented: $showAllMedia) {
            AllMediaSheet(messages: vm.messages)
        }
        .sheet(item: $reactorsSheetMessage) { msg in
            ReactionsWhoSheet(
                reactions: msg.reactions,
                nameFor: { vm.senderNickname($0) },
                avatarFor: { vm.senderAvatar($0) },
            )
        }
        .sheet(item: $pinnedExpansion) { exp in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Text runs and group cards in document order, so
                        // each card sits under its own introducing line —
                        // tapping a card dismisses this sheet first, then
                        // the root presents the join sheet.
                        ForEach(Array(pinnedSegments(exp.text, defaultHost: exp.host).enumerated()), id: \.offset) { _, seg in
                            switch seg {
                            case .text(let t):
                                Text(pinnedAttributed(t, linkable: true))
                                    .font(.body)
                                    .foregroundColor(Theme.Color.textPrimary)
                                    .tint(Theme.Color.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            case .group(let gid, let ghost):
                                PinnedGroupChip(groupID: gid, host: ghost) { tappedGID in
                                    pinnedExpansion = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        appState.pendingJoinGroupHost = Multihome.isOwnHost(ghost) ? nil : ghost
                                        appState.pendingJoinGroupID = tappedGID
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .background(Theme.Color.bgPrimary.ignoresSafeArea())
                .navigationTitle("chat.pin.title".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.close".localized) {
                            pinnedExpansion = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            // A `rcq://member/<uin>` mention tap opens that member's profile;
            // a group-share link opens the in-app join sheet; other
            // http(s) links open in the in-app browser.
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "rcq", url.host == "member", let uin = Int(url.lastPathComponent) {
                    pinnedExpansion = nil
                    // Same gate as the reactions sheet and the album header:
                    // this is a card opened from a name the subject never
                    // chose to be a link. A mention carries nothing but the
                    // number, so the island's verdict is looked up in the
                    // rosters this client already holds.
                    guard ProfileCardPrivacy.canOpenCard(
                        uin: uin,
                        openable: ProfileCardPrivacy.verdict(for: uin),
                        myUIN: AuthService.shared.ownUIN,
                        isContact: ContactService.shared.contacts.contains { $0.uin == uin }
                    ) else { return .handled }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pinnedMemberUIN = uin }
                    return .handled
                }
                if let hit = GroupLinkParser.parse(url.absoluteString) {
                    pinnedExpansion = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        appState.pendingJoinGroupHost = Multihome.isOwnHost(hit.host) ? nil : hit.host
                        appState.pendingJoinGroupID = hit.groupID
                    }
                    return .handled
                }
                return InAppBrowser.open(url)
            })
        }
        .sheet(item: Binding(
            get: { pinnedMemberUIN.map { MentionTarget(uin: $0) } },
            set: { pinnedMemberUIN = $0?.uin }
        )) { t in
            NavigationStack {
                UserInfoView(uin: t.uin, isOwn: t.uin == (AuthService.shared.ownUIN ?? -1))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.close".localized) { pinnedMemberUIN = nil }
                        }
                    }
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
            // ⚠⚠ The two halves must not fade AT THE SAME TIME. One
            // `.animation` over the ZStack did exactly that: both sat at half
            // opacity for the whole crossfade and the one drawn on top smeared
            // over the one arriving, which reads as a lag in ONE direction.
            // The outgoing half goes first, the incoming one waits for it. Same
            // bug and same cure as the web header and as `AltText`.
            Text(verbatim: "\(live.uin)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Color.textMono)
                .opacity(showAlt ? 0 : 1)
                .animation(.easeInOut(duration: Self.headerFade).delay(showAlt ? 0 : Self.headerFade),
                           value: showAlt)
            if let ls = live.lastSeen {
                Text(Self.relativeLastSeen(ls))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Color.textMono)
                    .opacity(showAlt ? 1 : 0)
                    .lineLimit(1)
                    .animation(.easeInOut(duration: Self.headerFade).delay(showAlt ? Self.headerFade : 0),
                               value: showAlt)
            }
        }
        // ⚠ `.task(id:)`, not `onAppear`. The old timer was a bare `Task {}`
        // that nothing held and nothing cancelled - `Task.isCancelled` inside
        // it never became true, and `stopHeaderSwapTimer` was a no-op with a
        // comment claiming SwiftUI would tear it down. Every re-entry into a
        // chat left another one running, all toggling the same flag. This one
        // SwiftUI cancels when the view goes away, and restarts if the peer
        // stops having a last seen to swap with.
        .task(id: hasLastSeen) {
            // Only tick when there is actually something to swap with: saves a
            // wakeup every 7s on online / hidden-last-seen peers.
            guard hasLastSeen else { return }
            while !Task.isCancelled {
                // 7s per side - the old 3s flipped too fast to read.
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if Task.isCancelled { return }
                headerShowsLastSeen.toggle()
            }
        }
    }

    /// Half of the header crossfade: the outgoing text takes this long to go,
    /// then the incoming one takes the same to arrive.
    private static let headerFade: Double = 0.2

    /// Mirrors `ContactListView.relativeLastSeen` so the chat-header
    /// subtitle reads identically to the contacts list row that led
    /// the user here. Re-declared (not shared) because the contact
    /// helper is `fileprivate` to its file.
    ///
    /// ⚠ Keep the two in step. This copy still said "47m ago" for a build
    /// where the list had already moved to words, which would have printed
    /// raw keys the moment the numeric strings were dropped (caught 31.08).
    private static func relativeLastSeen(_ date: Date) -> String {
        LastSeenText.relative(date)
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
                    PersonAvatarView(
                        mediaID: live.avatarMediaID, keyBase64: live.avatarMediaKey,
                        status: live.status, host: live.host, size: 30,
                        crossIsland: live.host != nil
                    )
                }
                VStack(spacing: 0) {
                    // My own name for them, when I gave one — the list already
                    // used it and the chat header did not, so a renamed contact
                    // read one way in the list and another inside the chat.
                    HStack(spacing: 5) {
                        Text(isSelf
                             ? "contact_list.saved_messages".localized
                             : aliasStore.displayName(for: live.uin, fallback: live.nickname))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(Theme.Color.textPrimary)
                            .lineLimit(1)
                        if !isSelf { BadgeMark(kind: live.badge, size: 12) }
                    }
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
                        host: live.host,
                        size: 24,
                        glyphSize: 11,
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 5) {
                            Text(live.name)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                                .lineLimit(1)
                            // The island's mark on the room, in the header as
                            // well as in the list (founder, 05.09).
                            BadgeMark(kind: live.badge, size: 12)
                        }
                        // Proportional, not monospaced: the rest of the app
                        // stopped using mono (see `Theme.Font.mono`) and a
                        // count is not a column that has to line up with
                        // anything. Compact from a thousand up so a big room
                        // does not push the name off the bar.
                        Text(MemberCountLabel.text(live.memberCount))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Color.textSecondary)
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
            // A stranger has no avatar and no UIN to show, so the header is
            // just the title. The theatre-masks glyph read as decoration on a
            // bar where every other chat shows a face, and the subtitle under
            // it was a hardcoded, never-localized "anonymous".
            Text("chat.random.stranger".localized)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
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
                // Gate the call buttons on the PEER's call_policy (do THEY
                // accept calls from us), NOT our own setting. Our own
                // "who can call me" only governs who may call US, and is
                // enforced server-side on the call_offer.
                let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
                let callsEnabled = (live.callable ?? true)
                if !isPeerBlocked && !isSelfThread && callsEnabled {
                    let busy = calls.state.isActive
                    Button {
                        CallService.shared.start(toContact: live, media: .audio)
                    } label: {
                        Label("chat.menu.voice_call".localized, systemImage: "phone.fill")
                    }
                    .disabled(busy)
                    Button {
                        CallService.shared.start(toContact: live, media: .video)
                    } label: {
                        Label("chat.menu.video_call".localized, systemImage: "video.fill")
                    }
                    .disabled(busy)
                }
                if !isSelfThread {
                    Button {
                        showTTLPicker = true
                    } label: {
                        Label(disappearingLabel, systemImage: ttlActive ? "clock.fill" : "clock")
                    }
                    // Per-conversation screen-secure: blanks THIS chat's
                    // screenshots/recording on BOTH sides (propagated to the
                    // peer) + posts a "took a screenshot" line on either screenshot.
                    Button {
                        let on = !chatSettings.isSecure(thread: .peer(uin: snapshot.uin))
                        chatSettings.setSecure(on, for: .peer(uin: snapshot.uin))
                        let live = contacts.contacts.first(where: { $0.uin == snapshot.uin }) ?? snapshot
                        Task { await MessageService.shared.sendSecureScreen(on: on, to: live) }
                    } label: {
                        let on = chatSettings.isSecure(thread: .peer(uin: snapshot.uin))
                        Label(
                            on ? "secscreen.menu_on".localized : "secscreen.menu_off".localized,
                            systemImage: on ? "eye.slash.fill" : "eye.slash"
                        )
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
                // Hide the disappearing-timer toggle when you can't post here
                // (owner-only broadcast group, non-owner): setting a TTL you can't
                // act on is meaningless. Read-only => readOnlyGroup != nil.
                if readOnlyGroup == nil {
                    Button {
                        showTTLPicker = true
                    } label: {
                        Label(disappearingLabel, systemImage: ttlActive ? "clock.fill" : "clock")
                    }
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

    /// The "say hi" empty state, or nothing at all in a room the viewer may not
    /// post in (24). A CTA that asks for a first message from somebody the room
    /// will not let speak is worse than an empty screen.
    @ViewBuilder
    private var emptyChatPlaceholder: some View {
        if readOnlyGroup == nil {
            emptyChatCTA
        }
    }


    /// The three composer sheets, lifted out of `body`.
    ///
    /// ⚠ Their CONTENT, not their presentation: the `.sheet` modifiers stay
    /// where they were, in the same order, so nothing about when they present
    /// changes. What moves is the several hundred tokens of view-building that
    /// used to sit inside `body`'s single expression. The type checker budgets
    /// one expression at a time, and this one is forty-odd modifiers long: with
    /// the sheet bodies inline, one more argument anywhere in the chain tipped
    /// the whole file into "unable to type-check this expression in reasonable
    /// time", reported against a line three hundred rows away from the change.
    private var attachmentSheet: some View {
        AttachmentPickerSheet(
            isRandom: { if case .randomPeer = vm.target { return true } else { return false } }(),
            filesAllowed: filesAllowed,
            onMedia: { picks in
                // Telegram-style: media chosen INSIDE the sheet
                // rather than via a follow-up UnifiedMediaPicker.
                // Route the picked items straight into the
                // composer's pending-media queue and close the
                // sheet, no `pendingAttachAction` middleman needed.
                showAttachmentMenu = false
                if !picks.isEmpty, attachmentRefused() { return }
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
            onDocument: {
                pendingAttachAction = .document
                showAttachmentMenu = false
            },
            onLocation: {
                pendingAttachAction = .location
                showAttachmentMenu = false
            },
            // Sharing a group invite into another chat is a 1:1
            // affordance: sharing into the same group is
            // contrived. Hidden in random-chat (privacy) and
            // hidden in group chats (no use-case).
            //
            // The Poll (14a) and Share-a-connection (14b) chips that used to
            // sit beside it are gone with their features.
            onShareGroup: shareGroupPickerHandler
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var shareGroupSheet: some View {
        ShareGroupPickerSheet { picked in
            // Send the canonical share URL as plain text. The
            // receiving client's `GroupLinkParser` upgrades the
            // bubble into a `GroupLinkBubble` card automatically.
            let url = GroupLinkParser.canonicalURL(forGroupID: picked.host != nil ? (VisitedIslandsStore.shared.refByAlias(picked.id)?.remoteId ?? picked.id) : picked.id, host: picked.host ?? Multihome.ownHost())
            // An invite IS a link: a room with links off means all of them.
            if roomRulesBlockSend(text: url.absoluteString) { return }
            armSlowmode()
            Task { await vm.sendText(url.absoluteString) }
        }
        .presentationDetents([.medium, .large])
    }

    private var locationSheet: some View {
        LocationPickerSheet(
            onSend: { coord in
                showLocationPicker = false
                if roomRulesBlockSend() { return }
                armSlowmode()
                Task { @MainActor in
                    if let err = await vm.sendLocation(latitude: coord.latitude, longitude: coord.longitude) {
                        videoError = err
                    }
                }
            },
            onCancel: { showLocationPicker = false },
        )
    }

    private var emptyChatCTA: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 38, weight: .light))
                // ⚠ NOT `Theme.Color.divider`. That token is a hairline colour
                // (#303030 in dark) chosen to be nearly invisible against a flat
                // background, and this glyph is drawn over the chat WALLPAPER:
                // on the graphite preset (#232526) it scored about 1.18:1 and
                // the CTA simply was not there. A hairline token is never a
                // glyph colour, least of all on a surface we do not control.
                .foregroundColor(Theme.Color.textSecondary)
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
                // ⚠ NOT WHILE THE CHAT IS STILL OPENING. A LazyVStack builds
                // from content offset 0, so this probe is the first row to
                // appear on every open, before the settle below has moved the
                // viewport anywhere. It then loaded a page of history and
                // scrolled to the row that had been at the top of the window,
                // which is about a hundred messages back, landing whenever the
                // async load happened to finish: sometimes before the settle,
                // sometimes after it, sometimes after the chat was already
                // visible. That is the "opens in a random place" the founder
                // kept seeing and could find no pattern in, because the pattern
                // was a race. History paging belongs to a reader who has
                // actually scrolled up to the top of the window; the probe
                // re-appears when they do.
                guard settleDone else { return }
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
        // Bound ONCE here rather than read per row: `roomPolicy` re-runs
        // `liveGroup` (a linear scan of the group list) and the roster lookup
        // in `roomExempt`, and this list re-renders on every incoming frame.
        // The rows take it as a value, so `MessageRow.==` still diffs it.
        let linksOK = linksAllowed
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
            if vm.messages.isEmpty {
                emptyChatPlaceholder
                    .transition(.opacity)
                    .zIndex(1)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    // Spacer at the top of the scroll content so the
                    // floating pinned banner (rendered as an overlay
                    // in the parent ZStack) doesn't sit over the
                    // first message bubble. Sized to clear the full
                    // expanded pin; the collapsed strip is shorter
                    // and leaves a small gap, which is fine.
                    if hasFloatingPin {
                        Color.clear.frame(height: 72)
                    }
                    loadOlderProbe(proxy: proxy)
                    // Identify day-groups by their (unique-per-day) label,
                    // NOT array offset. With offset identity, loadOlder()
                    // prepending a page of history shifts every index —
                    // offset 0 flips from e.g. "12 May" to "7 May" — and
                    // SwiftUI re-renders the whole list as if every group
                    // changed, producing a visible jump that fights the
                    // scroll-back-to-anchor in loadOlderProbe. Stable
                    // label identity lets SwiftUI see new groups inserted
                    // at the top while existing ones keep their place.
                    ForEach(vm.groupedUnits, id: \.label) { group in
                        DateDivider(label: group.label, surface: wallpaperSurfaceMode)
                        ForEach(Array(group.units.enumerated()), id: \.element.id) { idx, unit in
                            // The line that says WHY the chat opened here. iOS
                            // had none: the view jumped to the first unread and
                            // left the reader to work out what they were looking
                            // at, which reads as landing somewhere at random.
                            // Android and every other messenger draw it.
                            if unit.id == vm.unreadDividerID {
                                UnreadDivider(surface: wallpaperSurfaceMode)
                                    .id(Self.unreadDividerAnchorID)
                            }
                            switch unit {
                            case .album(let albumID, let items):
                                albumRow(items: items, unitID: albumID)
                                    // Same badge decrement as the single-message
                                    // rows below — albums used to skip it, so a
                                    // photo-heavy backlog never shrank the count.
                                    .onAppear {
                                        if let last = items.last { vm.sawRow(last.id) }
                                        // Reading-position tracking (13a) is
                                        // in ROW space: a collapsed album is
                                        // one row and reports the album id,
                                        // which is also its scrollTo target.
                                        vm.rowRealized(unit.id)
                                    }
                                    .onDisappear { vm.rowDerealized(unit.id) }
                            case .single(let msg):
                                MessageRow(
                                message: msg,
                                // Group: show the sender name only on the first
                                // message of a consecutive run from that person
                                // (WA/TG style), not on every bubble.
                                showSender: vm.target.thread.isGroup && !msg.isFromMe && Self.startsSenderRun(group.units, idx),
                                senderNickname: vm.senderNickname(msg.senderUIN),
                                replyAuthorOverride: vm.replyIsMine(msg) ? "chat.you".localized : nil,
                                displayBody: vm.displayText(for: msg),
                                isTranslated: vm.isTranslated(msg),
                                isHighlighted: flashHighlightID == msg.id,
                                isSelected: vm.isSelecting && vm.selectedIDs.contains(msg.id),
                                showSelectionAffordance: vm.isSelecting,
                                onTapReaction: { asset in vm.toggleReaction(asset, on: msg) },
                                onShowReactors: {
                                    reactorsSheetMessage = msg
                                    // The roster we hold carries the presence of
                                    // whenever it was fetched; ask for a fresh
                                    // one as the sheet opens.
                                    if case .group(let g) = vm.target, g.host == nil {
                                        Task { _ = await GroupService.shared.ensureRoster(g.id, refresh: true) }
                                    }
                                },
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
                                    // Remember the reply we jumped FROM so the chevron returns here.
                                    replyReturnID = msg.id
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
                                    beginReply(to: msg)
                                },
                                currentGroupMembers: currentGroupMembers,
                                linksAllowed: linksOK
                            )
                            // Skip re-running this row's body unless its own
                            // value inputs changed (see MessageRow.==). Stops
                            // the per-keystroke/-reaction re-render storm.
                            .equatable()
                            .onAppear {
                                // Monotonic: as deeper rows appear, fewer unread
                                // remain below — badge shrinks to 0 at the newest.
                                vm.sawRow(msg.id)
                                // Reading-position tracking (13a): the set of
                                // realized rows is how the VM knows roughly
                                // where the viewport is - there is no scroll
                                // offset to read with the geometry probes
                                // reverted. `unit.id` == `msg.id` here; going
                                // through the unit keeps both row kinds on
                                // one identity space.
                                vm.rowRealized(unit.id)
                            }
                            .onDisappear { vm.rowDerealized(unit.id) }
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
                            // ⚠ Insertion eases OUT, and fast. With a plain
                            // `.opacity` under the list's old ease-in-out the
                            // bubble took its space at once (the list jumped)
                            // and then sat invisible for the slow start of the
                            // curve: filmed at 20 fps on 05.09 as jump, hole,
                            // fade on every send. Removal keeps the soft fade.
                            .transition(.asymmetric(
                                insertion: msg.isFromMe
                                    ? .move(edge: .bottom).combined(with: .opacity).animation(.easeOut(duration: 0.18))
                                    : .opacity.animation(.easeOut(duration: 0.14)),
                                removal: .opacity
                            ))
                            .id(msg.id)
                            }
                        }
                    }
                    // Bottom anchor — the scrollTo target AND the arrow's
                    // visibility driver. onAppear/onDisappear are lifecycle
                    // events (they fire on iOS 26 too, unlike the geometry-
                    // preference probes that froze mid-scroll there and the
                    // onScrollGeometryChange gap math that mis-counted the
                    // composer inset and showed the arrow even at the bottom —
                    // both regressions, reverted). When this 1pt sentinel is
                    // realized at the list's end you're effectively at the
                    // bottom → hide; when it scrolls off → show. The open-at-
                    // unread case is handled by the insurance in `.task`.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear {
                            // Once the open position has been re-asserted, the
                            // sentinel materializing IS the geometry proof that
                            // the scroll landed at the bottom — lift the
                            // initial-settle mask here instead of waiting out
                            // the rest of the insurance window. Before that it
                            // only means LazyVStack realized the row, which
                            // happens mid-scroll and proves nothing.
                            if settleDone { revealChat() }
                            withAnimation(.easeInOut(duration: 0.18)) { showScrollToBottom = false }
                            // Reached the bottom on your own → drop any stale reply-return target.
                            replyReturnID = nil
                            // At the bottom there is nothing to resume - the
                            // saved reading spot is cleared (13a), so the next
                            // open is the plain bottom open as today.
                            vm.noteAtBottom(true)
                        }
                        .onDisappear {
                            withAnimation(.easeInOut(duration: 0.18)) { showScrollToBottom = true }
                            vm.noteAtBottom(false)
                        }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                // Animate when a new message lands at the bottom only,
                // by watching the last id instead of the raw count.
                // Watching count would also fire when `loadOlder()`
                // prepends a page of history, causing a stutter for
                // every prepend.
                // ⚠ Same curve and length as the composer's collapse (0.18
                // ease-out), so a send moves the list, the bubble and the
                // field on ONE timeline instead of three.
                .animation(.easeOut(duration: 0.18), value: vm.messages.last?.id)
            }
            // Initial-settle mask. While the open-position scrollTo in
            // `.task` lands (LazyVStack realizes rows as the viewport
            // scrolls past them), we hide the surface to spare the
            // user the row-shuffle. Pinned to the message scroll only
            // — composer, header and overlays stay live.
            .opacity(chatVisible ? 1 : 0)
            // No defaultScrollAnchor(.bottom) — it yanks mid-scroll when LazyVStack realizes rows,
            // and pins the empty-state to the input bar. Initial scroll is owned by the .task loop below.
            // ⚠ Interactively, not immediately: a glance one message up while
            // typing dropped the keyboard and the draft had to be tapped back
            // into. Telegram and Messages let the keyboard follow a finger
            // dragged down over it and otherwise leave it alone.
            .scrollDismissesKeyboard(.interactively)
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
                // Your OWN send always jumps to the new bubble, even if
                // you'd scrolled up — you initiated it and expect to see
                // it (iMessage behaviour). Previously this hit the
                // !showScrollToBottom guard below and a send while
                // scrolled up left your message off-screen.
                // ⚠ "From me" is not "from here". A carbon of a message typed
                // on another device, or a delete that exposes an older own
                // message as last, is incoming for this screen and follows the
                // incoming rule below (audit, 05.09).
                if vm.messages.last?.isFromMe == true && vm.sentFromHereJustNow {
                    // Own send: the new bubble already animates in via the
                    // `.animation(value:)` above. Wrapping the scroll in its
                    // OWN `withAnimation` ran a SECOND 0.25s curve against the
                    // still-growing content height, so the offset chased a
                    // moving target and the list visibly jumped/overshot.
                    // Defer one runloop (so the new row's layout is committed)
                    // and scroll WITHOUT a competing animation — the viewport
                    // settles at the final bottom while the bubble animates in.
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                    return
                }
                // Incoming message: re-anchor only if already at bottom —
                // yanking a scrolled-up reader down is hostile. Watching
                // the last id (not count) so `loadOlder()` prepends don't
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
            // ONLY when already at the bottom: a reader scrolled up into
            // history must stay where they are (founder report — opening the
            // emoji panel yanked the chat to the newest message).
            // The typing line and the reply strip change the bottom inset
            // exactly like the emoji panel does, and got none of its care:
            // the newest bubble slid under the bar when either appeared and
            // a blank band opened when either left. Same rule, same curve.
            .onChange(of: vm.isPeerTyping) { _ in
                guard !showScrollToBottom else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: vm.pendingMedia.isEmpty) { _ in
                guard !showScrollToBottom else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: vm.replyTarget?.id) { id in
                guard !showScrollToBottom else { return }
                if id != nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                } else {
                    // The strip leaves on a spring; track the moving edge the
                    // way the composer collapse does.
                    Task { @MainActor in
                        let endDate = Date().addingTimeInterval(0.32)
                        while Date() < endDate {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                            try? await Task.sleep(nanoseconds: 16_000_000)
                        }
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: showEmojiPanel) { _ in
                guard !showScrollToBottom else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            // Send-and-clear from a multi-line draft shrinks the composer
            // from ~90pt back to 36pt, which pulls the bottom safe-area
            // inset up by the same delta and shifts the visible bottom
            // of the message list. Keyboard didn't move, so the keyboard
            // handlers below don't fire. Tick scrollTo for the composer
            // height-collapse animation window so the bottom anchor
            // tracks the moving viewport edge instead of jumping at the
            // tail. Only on SHRINK — grow happens mid-typing and the
            // natural layout pass handles it without re-anchor.
            .onChange(of: composerHeight) { newH in
                let prev = lastComposerHeight
                lastComposerHeight = newH
                guard abs(newH - prev) > 0.5 else { return }
                guard !showScrollToBottom else { return }
                if newH > prev {
                    // ⚠ Growth too, not only the collapse. The bar grows by a
                    // line while typing, the bottom inset grows with it in the
                    // same pass, and the content offset stays where it was, so
                    // the newest bubble slid under the bar (filmed 05.09).
                    // Growth is not animated (see the field's frame), so one
                    // re-anchor in the same pass is the whole correction.
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    return
                }
                Task { @MainActor in
                    // .easeOut(0.18) on the composer height + small slack.
                    let endDate = Date().addingTimeInterval(0.22)
                    while Date() < endDate {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            // No scroll on reply / edit context appearance — felt jumpy.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
                if showEmojiPanel {
                    showEmojiPanel = false
                }
                // Same at-bottom-only rule as the emoji panel above: the
                // keyboard must not yank a reader out of history either
                // (keyboardWillHide already had this guard).
                guard !showScrollToBottom else { return }
                // Match the system keyboard's 0.25s easeOut so the scroll glides in sync.
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                isKeyboardVisible = false
                if emojiPanelAfterKeyboard {
                    emojiPanelAfterKeyboard = false
                    // Same curve and length as the system keyboard's exit, so
                    // the panel rises as the keyboard sinks.
                    withAnimation(.easeOut(duration: 0.25)) { showEmojiPanel = true }
                }
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
            // Initial settle: jump to the open position while the chat
            // is masked behind opacity. Users used to see rows pop
            // into view as the viewport scrolled past them ("на глазах
            // загружается"). One scrollTo + one re-assert after
            // LazyVStack's realization pass replaces the old 350ms
            // 60Hz loop — the first jump exposes unrealized rows,
            // their real sizes shift the content, the second call pins
            // the final position; the mask lifts on geometry (bottom
            // sentinel), not on a clock.
            .task {
                // Snapshot any unseen-reaction targets BEFORE the settle loop —
                // row acks (markThreadSeen) consume the inbox once bubbles
                // appear, so we must read it first. We jump to the first one
                // after settle, then clear the thread so it doesn't re-flash on
                // reopen. Filtered to ids actually loaded in this window.
                let reactedJumpID: UUID? = {
                    let pending = ReactionInboxStore.shared.reactedIDs(vm.target.thread)
                    guard !pending.isEmpty else { return nil }
                    let loaded = Set(vm.messages.map { $0.id })
                    return pending.first { loaded.contains($0) }
                }()
                // Open scrolled to the first unread message if there are unread
                // (every-messenger behaviour); otherwise settle at the bottom.
                // ⚠ ONCE per screen. This `.task` re-runs every time the view
                // re-appears, and coming back from the peer's profile or the
                // group header is a re-appear. The second run re-settled off a
                // snapshot frozen at init, against a list that had grown, with
                // the mask already lifted, so the chat visibly jumped for no
                // reason the reader could connect to anything they did.
                if didSettleOpen { return }
                didSettleOpen = true
                let unreadID = vm.openFirstUnreadID
                // Pin the line to the same row the landing uses, before the
                // first settle, so the row exists by the time we scroll to it.
                vm.pinUnreadDivider(unreadID)
                // The quiet re-entry (founder batch 21.08, item 13a): no unread,
                // but a saved reading spot - resume there instead of the bottom,
                // the way every messenger does. The unread divider always wins:
                // new messages move the landing to where reading actually
                // stopped, which the divider marks better than the saved spot.
                // ⚠ No saved-spot restore any more. "Reopen where reading
                // stopped" (item 13a) sounds right and reads as random: the
                // spot came from which rows the LazyVStack had realized, which
                // is not what the reader saw, and any jump that stilled the
                // list (a reply-quote tap, a search hit, an @-mention step)
                // wrote a spot deep in history that the next open then
                // restored. The founder asked for the rule every modern
                // messenger uses instead: unread means the unread line,
                // nothing unread means the bottom. Two outcomes, both
                // explainable from the screen. The saved spot stays on disk
                // and unread; nothing reads it at open.
                let restoreID: UUID? = nil
                // Arrow on immediately when opening scrolled up (#15) — the
                // geometry observers correct it within the first layout if
                // the unread block actually fits on one screen.
                if unreadID != nil, vm.openUnreadCount > 2 {
                    showScrollToBottom = true
                }
                // Same insurance for a resumed spot: the bottom sentinel starts
                // unrealized up there, so nothing else would flip the arrow on.
                if restoreID != nil {
                    showScrollToBottom = true
                }
                // @MainActor so the nested function shares the .task's main-actor
                // isolation — otherwise it captures the non-Sendable ScrollViewProxy
                // and the main-actor static anchor from a nonisolated context.
                @MainActor func settle() {
                    // Anchor on the LINE, not on the first unread row: the
                    // reader should see "unread messages" at the top of the
                    // screen with the new ones under it, which is the whole
                    // point of the line. Falls back to the row itself if the
                    // line has not been realized (it is drawn in the same
                    // pass, so this is belt and braces).
                    // A shade below the very top, not flush against it: the
                    // navigation bar and the pinned banner float OVER the
                    // scroll view, so a row parked at the top edge sits behind
                    // them. Seen on the simulator with `.top`: the line landed
                    // under the chrome and the reader saw only the messages
                    // below it, which is the whole thing the line exists to
                    // explain. `scrollTo` maps the row's anchor point onto the
                    // viewport's, so a positive fraction lands the row that
                    // fraction of a screen down: about 110 pt here, which
                    // clears the bar and the banner both.
                    if unreadID != nil {
                        proxy.scrollTo(Self.unreadDividerAnchorID, anchor: UnitPoint(x: 0.5, y: 0.13))
                    }
                    // anchor .top, exactly like the unread anchor above and
                    // like Android's scrollToItem: the spot is saved off the
                    // TOP row of the reader's screen, so pinning it to the
                    // top edge re-shows the screenful they left. It used to
                    // save the bottommost REALIZED row and pin that to the
                    // bottom edge - realization reaches well past the
                    // viewport, so the landing sat an unpredictable distance
                    // below the real spot and skipped messages.
                    else if let rid = restoreID { proxy.scrollTo(rid, anchor: .top) }
                    else { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                settle()
                try? await Task.sleep(nanoseconds: 32_000_000)
                settle()
                // Only from here may geometry lift the mask: the sentinel
                // realizes during the FIRST scrollTo whenever the open anchor
                // sits within a screenful of the bottom, which is most of the
                // open-at-unread cases — revealing there would show exactly
                // the row-shuffle the mask exists to hide.
                settleDone = true
                // Insurance for the open-at-unread anchor (top of the unread
                // block — the bottom sentinel may never realize there) and
                // any layout where the geometry callback doesn't come: after
                // the re-assert has had a frame to land, pin the position one
                // last time and lift the mask ourselves. revealChat() is
                // idempotent, so a sentinel that realized after the settle has
                // usually beaten us here.
                try? await Task.sleep(nanoseconds: 48_000_000)
                settle()
                revealChat()
                // Only from here may reading-position saves persist (13a) -
                // the rows that realized during the settle jumps above are
                // landing artifacts, not where reading is. Handing the VM the
                // restored row lets it tell its own landing apart from a
                // scroll the reader made, so an untouched chat stores the
                // same spot every time instead of creeping upward per open.
                vm.armReadPosSaves(restored: restoreID)
                // Reaction-jump-on-open: someone reacted to my message while I
                // was away — scroll to + flash it once the layout has settled,
                // then consume the thread's reacted set so reopening is quiet.
                // ⚠ Only when the open landed at the bottom. This jump runs
                // AFTER the mask has lifted and it animates, so on a chat that
                // opened at its first unread it visibly walked the reader away
                // from the very thing they came to read, to an old message of
                // their own. The unread rule wins; the reaction keeps its badge.
                if let reactedJumpID, unreadID == nil, restoreID == nil {
                    // Let the settle's final scroll land first, then override it
                    // with the reaction target (a small delay beats the residual
                    // settle motion the same way the chevron tap-burst does).
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    jumpAndFlash(to: reactedJumpID, proxy: proxy)
                    ReactionInboxStore.shared.clear(vm.target.thread)
                }
            }
            // @-mention jump FAB — a second circular button directly above the
            // scroll-to-bottom chevron, stepping through the open thread's
            // messages that @mention me (Telegram-style). Shown whenever the
            // thread has any such message, independent of scroll position.
            if mentionsLeft > 0 {
                Button {
                    let ids = vm.mentionIDs
                    guard !ids.isEmpty else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let idx = min(mentionCursor, ids.count - 1)
                    jumpAndFlash(to: ids[idx], proxy: proxy)
                    // Advance WITHOUT wrapping: stepping past the last mention
                    // takes the cursor to count, hiding the FAB (mentionsLeft 0).
                    mentionCursor = idx + 1
                } label: {
                    Image(systemName: "at")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(floatingButtonGround)
                        .overlay(
                            Circle().stroke(Theme.Color.divider, lineWidth: 0.5)
                        )
                        // Remaining-count badge: how many mentioning messages
                        // are still in the thread (mirrors the chevron's unread
                        // badge styling).
                        .overlay(alignment: .topTrailing) {
                            if mentionsLeft > 1 {
                                Text(mentionsLeft > 99 ? "99+" : "\(mentionsLeft)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                    .background(Theme.Color.accent, in: Capsule())
                                    .offset(x: 6, y: -6)
                            }
                        }
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                }
                .padding(.trailing, 14)
                // Sit just above the scroll-to-bottom chevron (38pt tall +
                // its 12pt bottom inset + a small gap).
                .padding(.bottom, showScrollToBottom ? 62 : 12)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            if showScrollToBottom {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if let ret = replyReturnID {
                        // Return to the reply a quote-jump came FROM, not the bottom.
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(ret, anchor: .center)
                        }
                        replyReturnID = nil
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                        // A tap mid-fling used to do nothing: the deceleration's
                        // own offset updates override the animated scrollTo (beta
                        // report; Telegram honours the tap). After the animation
                        // window, re-assert the target for a short burst — each
                        // tick re-snaps against the CURRENT offset, beating any
                        // leftover momentum.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            let endDate = Date().addingTimeInterval(0.25)
                            while showScrollToBottom, Date() < endDate {
                                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                                try? await Task.sleep(nanoseconds: 16_000_000)
                            }
                            // The jump consumed everything below, even rows that
                            // never got to fire onAppear on the way down.
                            vm.clearUnreadBelow()
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(floatingButtonGround)
                        .overlay(
                            Circle().stroke(Theme.Color.divider, lineWidth: 0.5)
                        )
                        // Unread count badge (#15): how many unread still sit
                        // below the viewport — decremented live as you scroll
                        // down, gone by the time you reach the newest.
                        .overlay(alignment: .topTrailing) {
                            if vm.unreadBelow > 0 {
                                Text(vm.unreadBelow > 99 ? "99+" : "\(vm.unreadBelow)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                    .background(Theme.Color.accent, in: Capsule())
                                    .offset(x: 6, y: -6)
                            }
                        }
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
    /// Scroll identity of the unread line. The open anchors on THIS rather
    /// than on the first unread message, so the line itself is the first thing
    /// on screen and everything below it is new.
    private static let unreadDividerAnchorID = "__rcq_chat_unread_divider"

    // MARK: - report-with-evidence helpers

    private func shouldOfferEvidenceReport(_ message: Message) -> Bool {
        if message.isFromMe { return false }
        guard message.mediaID != nil else { return false }
        switch message.kind {
        case .photo:
            return true
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
        case .poll:
            // Polls are gone (14a). The `text` of an old `.poll` row is still a
            // JSON blob on disk, so this branch must stay and must never fall
            // through to `raw = message.text` - that would print raw braces into
            // a reply strip.
            raw = "📊 \("chat.poll.removed".localized)"
        default:     raw = message.text.isEmpty ? "chat.message_fallback".localized : message.text
        }
        // Quote the replied-to message generously so the bubble shows it in
        // full for normal-length messages (no more tiny mid-word "…" that forced
        // a tap to read). Only a very long quote is clipped, and at a word
        // boundary so it never cuts mid-word.
        if raw.count <= 280 { return raw }
        let cut = raw.prefix(280)
        if let lastSpace = cut.lastIndex(of: " "), lastSpace > cut.startIndex {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
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
        case .photo, .video, .voice:
            return true
        default:
            return false
        }
    }

    // MARK: - input

    /// True when the unit at `index` starts a new run of messages from a sender
    /// (the previous unit is from someone else, or it's the first of the day
    /// group). Used to show the group sender name once per run, WA/TG style.
    private static func startsSenderRun(_ units: [ChatViewModel.RenderUnit], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        func sender(_ u: ChatViewModel.RenderUnit) -> Int {
            switch u {
            case .single(let m): return m.senderUIN
            case .album(_, let items): return items.first?.senderUIN ?? -1
            }
        }
        return sender(units[index]) != sender(units[index - 1])
    }

    /// The composer for a room this viewer may not post in (24): the same bar,
    /// the same height, the same seam under the message list, with everything
    /// dead. The placeholder says why, so the greyed-out field is not a mystery.
    ///
    /// Deliberately built out of the same pieces as `inputBar` rather than
    /// reusing it disabled: the live bar carries a UIViewRepresentable text view
    /// that becomes first responder on a token bump, and a first responder we
    /// never want to hand the keyboard to is worse than one that does not exist.
    private var readOnlyComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "paperclip")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Color.textSecondary)
                Text("group.compose.broadcast_only".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14).padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            Image(systemName: "mic.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(0.55)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("group.compose.broadcast_only".localized))
    }

    private var isStrangerMode: Bool {
        if case .randomPeer = vm.target { return true }
        return false
    }

    /// Sticky banner above the message list showing the group's pinned
    /// announcement. Only renders for groups with a non-empty pin.
    /// New joiners (who can't read encrypted history) see the rules
    /// the moment they enter the chat. The X button COLLAPSES the
    /// banner to a one-line strip that the user can tap to expand
    /// back; the pin is never destroyed from the user's view —
    /// they can always get it back.
    @ViewBuilder
    private var pinnedBanner: some View {
        if case .group(let snapshot) = vm.target,
           let live = groupSvc.find(snapshot.id) ?? Optional(snapshot),
           let text = live.pinnedText,
           !text.isEmpty {
            if collapsedPinGroups.contains(live.id) {
                collapsedPinStrip(group: live, text: text)
            } else {
                fullPinBanner(group: live, text: text)
            }
        }
    }

    /// One-line strip shown when the user collapsed the pin. Tap
    /// anywhere expands the banner back to its full form.
    private func collapsedPinStrip(group: RCQGroup, text: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandPin(groupID: group.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                Text(pinnedAttributed(pinnedDisplayText(text), linkable: false))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Opaque (16). This strip floats in the chat ZStack directly over
            // live message rows, and at 0.96 the bubbles underneath showed
            // through it as moving ghosts while the list scrolled.
            .background(Capsule().fill(Theme.Color.bgSecondary))
            .overlay(
                Capsule().strokeBorder(Theme.Color.divider.opacity(0.3), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The visible "Pinned" word was dropped (the icon says it), but
        // VoiceOver derived the button's name from that Text; keep the name.
        .accessibilityLabel("chat.pin.title".localized)
    }

    /// Full banner with title, multi-line text, and a chevron-up
    /// button that collapses the banner back to a strip. Rendered
    /// as a rounded floating panel inside the chat area so the
    /// long-press action overlay's material naturally covers it.
    private func fullPinBanner(group: RCQGroup, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Color.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                // Cap the expanded pin's height and scroll inside it — a pin with
                // many group links used to grow unbounded, pushing the chat down
                // and hiding rows past ~13 with no way to scroll (#5).
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // Text runs and group cards laid out IN ORDER, so each card
                        // sits under the line that introduced it (raw URLs stripped).
                        ForEach(Array(pinnedSegments(text, defaultHost: group.host).enumerated()), id: \.offset) { _, seg in
                            switch seg {
                            case .text(let t):
                                Text(pinnedAttributed(t, linkable: false))
                                    .font(.callout)
                                    .foregroundColor(Theme.Color.textPrimary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .group(let gid, let ghost):
                                PinnedGroupChip(groupID: gid, host: ghost) { tapped in
                                    appState.pendingJoinGroupHost = Multihome.isOwnHost(ghost) ? nil : ghost
                                    appState.pendingJoinGroupID = tapped
                                }
                            }
                        }
                    }
                    // Measure the content so the ScrollView fits short pins
                    // instead of always reserving the full cap (#13).
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: PinHeightKey.self, value: geo.size.height)
                    })
                }
                // Shrink to content, cap at 240 (scroll beyond).
                .frame(height: min(pinContentHeight, 240))
                .onPreferenceChange(PinHeightKey.self) { pinContentHeight = $0 }
            }
            Spacer(minLength: 6)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    collapsePin(groupID: group.id)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Opaque (16). The expanded pin is a panel floating over the message
        // list inside the same ZStack, and the 0.96 fill let whole bubbles read
        // through it - scrolling behind a pin made the pin's own text move.
        // The long-press overlay still covers it, because that draws above.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Color.bgSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.Color.divider.opacity(0.3), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            pinnedExpansion = PinExpansion(text: text, host: group.host)
        }
    }

    /// The pinned text with group-share links stripped, for DISPLAY only.
    /// Those links render as tappable group chips (see `PinnedGroupChip`),
    /// so leaving the raw `rcq.app/g/<id>` URL in the text too is just
    /// noise. Collapses the whitespace/blank lines the removal leaves.
    private func pinnedDisplayText(_ text: String) -> String {
        var s = text.replacingOccurrences(
            of: "(?:https?://rcq\\.app/g/\\d+|rcq://group/\\d+)",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n[ \\t]*\\n[ \\t]*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An ordered piece of a pinned announcement: a run of text, or a
    /// group-share link (rendered as a card). Used to lay the pin out
    /// IN DOCUMENT ORDER so each group card sits directly under the line
    /// that introduced it, instead of all cards bunched at the bottom.
    enum PinSegment {
        case text(String)
        case group(Int, String?)
    }

    private func pinnedSegments(_ text: String, defaultHost: String? = nil) -> [PinSegment] {
        // Links off: the announcement still says what it says, but an invite in
        // it does not become a join card - a join card is the most clickable
        // link there is. Web drops the same card behind `linksAllowed`.
        guard linksAllowed else { return [.text(text)] }
        guard let rx = try? NSRegularExpression(
            pattern: "(?:https?://rcq\\.app/g/(\\d+)(?:@([a-z0-9.-]+))?|rcq://group/(\\d+)(?:@([a-z0-9.-]+))?)", options: [.caseInsensitive]
        ) else { return [.text(text)] }
        let ns = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(text)] }
        var out: [PinSegment] = []
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { out.append(.text(chunk)) }
            }
            // groups: (1)=https id (2)=https host (3)=scheme id (4)=scheme host
            let g1 = m.range(at: 1), g2 = m.range(at: 2), g3 = m.range(at: 3), g4 = m.range(at: 4)
            let idStr = g1.location != NSNotFound ? ns.substring(with: g1)
                : (g3.location != NSNotFound ? ns.substring(with: g3) : "")
            let hostRange = g1.location != NSNotFound ? g2 : g4
            let host: String? = hostRange.location != NSNotFound ? ns.substring(with: hostRange).lowercased() : defaultHost
            if let gid = Int(idStr), gid > 0 { out.append(.group(gid, host)) }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { out.append(.text(tail)) }
        }
        return out
    }

    /// Plain pinned text → AttributedString with URLs accent-coloured. With
    /// `linkable` they're also tappable + underlined (the expanded pin view);
    /// without it they're colour-only (the banner preview), so a tap falls
    /// through to the banner's "expand" gesture.
    static func linkified(_ text: String, linkable: Bool = true) -> AttributedString {
        var attr = AttributedString(text)
        let types = NSTextCheckingResult.CheckingType.link.rawValue
        guard let detector = try? NSDataDetector(types: types) else { return attr }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url,
                  let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: attr),
                  let hi = AttributedString.Index(r.upperBound, within: attr) else { continue }
            attr[lo..<hi].foregroundColor = Theme.Color.accent
            if linkable {
                attr[lo..<hi].link = url
                attr[lo..<hi].underlineStyle = .single
            }
        }
        return attr
    }

    /// Pinned text → AttributedString with URLs AND `#<uin>` / `UIN <uin>`
    /// member mentions. A mention whose UIN is a CURRENT group member renders
    /// as that member's nickname in accent; a mention NOT in this group stays
    /// inert plain text (so the announcement can't point the group at an
    /// outsider). With `linkable` the mentions/URLs are tappable (the expanded
    /// view); without it they're colour-only (the banner), so the whole banner
    /// taps to expand and the user clicks the link/nick there.
    private func pinnedAttributed(_ text: String, linkable: Bool) -> AttributedString {
        // A links-off room keeps the URL as prose: not tappable, not even
        // accent-coloured, because colouring it is the promise of a tap.
        let linkable = linkable && linksAllowed
        let plainURLs = !linksAllowed
        let nickByUIN: [Int: String] = Dictionary(
            currentGroupMembers.map { ($0.uin, $0.nickname) }, uniquingKeysWith: { a, _ in a }
        )
        // Matches both `#<uin>` and `UIN <uin>` (the format used in real pins).
        func run(_ chunk: String) -> AttributedString {
            plainURLs ? AttributedString(chunk) : ChatView.linkified(chunk, linkable: linkable)
        }
        guard let regex = try? NSRegularExpression(pattern: "(?:#|UIN\\s+)(\\d{3,})", options: [.caseInsensitive]) else {
            return run(text)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return run(text) }

        var result = AttributedString()
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                result.append(run(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            let token = ns.substring(with: m.range)            // "#911" / "UIN 911"
            let uin = Int(ns.substring(with: m.range(at: 1)))  // 911
            if let uin, let nick = nickByUIN[uin] {
                var mention = AttributedString(nick)
                mention.foregroundColor = Theme.Color.accent
                if linkable { mention.link = URL(string: "rcq://member/\(uin)") }
                result.append(mention)
            } else {
                result.append(AttributedString(token))         // inert plain text
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result.append(run(ns.substring(from: cursor)))
        }
        return result
    }

    /// True when the active chat target is a group with a non-empty
    /// pinned announcement. Used by `messageScroll` to reserve space
    /// at the top of the LazyVStack so the floating pin capsule
    /// doesn't overlap the first message row.
    private var hasFloatingPin: Bool {
        if case .group(let snap) = vm.target,
           let live = groupSvc.find(snap.id) ?? Optional(snap),
           let text = live.pinnedText, !text.isEmpty {
            return true
        }
        return false
    }

    private func collapsePin(groupID: Int) {
        collapsedPinGroups.insert(groupID)
        UserDefaults.standard.set(Array(collapsedPinGroups), forKey: "rcq.pin.collapsed_groups")
    }

    private func expandPin(groupID: Int) {
        collapsedPinGroups.remove(groupID)
        UserDefaults.standard.set(Array(collapsedPinGroups), forKey: "rcq.pin.collapsed_groups")
    }

    private var inputBar: some View {
        // Pending media on its own is a sendable message — show the
        // send button even when the caption is empty. composerNonEmpty is
        // the model's gated mirror of the input's trimmed-emptiness.
        let showSend = vm.composerNonEmpty || !vm.pendingMedia.isEmpty || sendHold
        // Two voice-flow modes preempt the regular composer:
        // 1. previewPill   — finished clip awaiting send / discard.
        // 2. recordingPill — recording in progress; tap stop → preview.
        let voiceFlowActive = pendingVoicePreview != nil
            || isVoiceRecording
        return HStack(alignment: .bottom, spacing: 8) {
            if let preview = pendingVoicePreview {
                previewPill(preview)
            } else if isVoiceRecording {
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
        Button {
            keyboardUpBeforeAttach = isKeyboardVisible
            showAttachmentMenu = true
        } label: {
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
                    },
                    onImagePaste: { image in
                        // Pasted screenshot / copied photo flows
                        // straight into the pending-media queue,
                        // same path as a gallery pick - and through
                        // the same door: a files-off room says no here.
                        if attachmentRefused() { return }
                        vm.queuePendingPhotos([image])
                    },
                    caretPlainLocation: composerCaretBinding,
                    focusRequest: composerFocusToken
                )
                .frame(maxWidth: .infinity, minHeight: composerHeight, maxHeight: composerHeight)
                // ⚠ Animated on the way DOWN only. The height comes from the
                // text view's delegate, i.e. after UIKit has already laid the
                // text out taller, so easing the capsule up behind it clipped
                // the first line for the length of the curve (filmed 05.09).
                // Growth is instant, the way it is in every messenger people
                // compare this one to; the collapse after a send still glides.
                .animation(composerHeight < lastComposerHeight ? .easeOut(duration: 0.18) : nil, value: composerHeight)
                Button {
                    if showEmojiPanel {
                        // The glyph says "keyboard": close the panel AND raise
                        // the keyboard. It used to drop the panel and leave the
                        // field cold, so the person tapped the field again.
                        withAnimation(.easeInOut(duration: 0.18)) { showEmojiPanel = false }
                        composerFocusToken &+= 1
                    } else if isKeyboardVisible {
                        // ⚠ Swap, not stack. Opening the panel over the open
                        // keyboard pushed the bar up by another 250pt and the
                        // list collapsed to a strip (audit, 05.09). Resign
                        // first; keyboardWillHide opens the panel in the same
                        // motion the keyboard leaves with.
                        emojiPanelAfterKeyboard = true
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { showEmojiPanel = true }
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
                // ⚠ Thick, not regular. The bar floats over the conversation
                // and with the regular material the glyphs of the bubble
                // underneath read straight through the field: a decorated
                // nickname showed up as stray marks beside the paperclip
                // (filmed 05.09). The frost stays; the words behind it go.
                .fill(.thickMaterial)
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
                EmoticonText(
                    text: snippet,
                    font: .caption2,
                    color: Theme.Color.textSecondary,
                    emoticonSize: 15,
                    members: currentGroupMembers
                )
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
    /// `unitID` is the row's identity in the scroll view and it is NOT the
    /// first message's id.
    ///
    /// ⚠ A collapsed album is one row for N messages, and `RenderUnit.album`
    /// identifies it by its albumID while this row used to carry the id of the
    /// first photo. Two identity spaces for one row, which made every
    /// `scrollTo` that targeted an album a silent no-op: the settle then did
    /// nothing at all (its branches are if / else if, so a miss does not fall
    /// through to the bottom) and the chat was revealed wherever the list
    /// happened to be, which is the top of the loaded window.
    private func albumRow(items: [Message], unitID: UUID) -> some View {
        AlbumRowView(
            items: items,
            isInGroupChat: vm.target.thread.isGroup,
            senderNickname: vm.senderNickname(items.first!.senderUIN),
            senderAvatarID: groupMember(items.first!.senderUIN)?.avatarMediaID,
            senderAvatarKey: groupMember(items.first!.senderUIN)?.avatarMediaKey,
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
                beginReply(to: items.first!)
            },
            onTapReaction: { asset in vm.toggleReaction(asset, on: items.first!) },
            onShowReactors: { reactorsSheetMessage = items.first! }
        )
        .id(unitID)
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
                    // Same rule as the empty-state glyph (18): `divider` is a
                    // hairline colour, not a disabled-glyph colour. A dimmed
                    // label token reads as "off" without disappearing.
                    .foregroundColor(canDelete ? .red : Theme.Color.textSecondary.opacity(0.5))
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
            // Tap-to-blur (Android parity): tapping a pending photo/video
            // tile marks it a spoiler — it ships blurred and the receiver
            // taps to reveal. GIFs have no spoiler lane on the wire.
            .blur(radius: vm.spoilerMedia.contains(item.id) ? 6 : 0, opaque: true)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if !isGIF(item) {
                    Image(systemName: vm.spoilerMedia.contains(item.id) ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { vm.toggleSpoilerMedia(item.id) }
            .accessibilityLabel(Text("chat.spoiler.mark".localized))
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

    private func isGIF(_ item: ChatViewModel.PendingMediaItem) -> Bool {
        if case .gif = item { return true }
        return false
    }

    private var sendButton: some View {
        Button {
            // The room's rules, on the SEND path rather than on the button:
            // a draft typed before the owner flipped the switch, and the
            // hardware-return key, both get here without passing a control.
            // A caption rides with the media, so it is the same text test;
            // the strip itself is an attachment, for a queue that predates
            // the switch.
            if roomRulesBlockSend(text: vm.input, isAttachment: !vm.pendingMedia.isEmpty) { return }
            // ⚠ The arrow stays where it is for a third of a second after a
            // tap. It used to morph into the microphone under the finger,
            // and a habitual second tap started a voice recording.
            if sendHold { return }
            sendHold = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sendHold = false }
            Task {
                if !vm.pendingMedia.isEmpty {
                    armSlowmode()
                    if let err = await vm.sendPendingMediaWithCaption() {
                        videoError = err
                    }
                } else if await vm.send() {
                    // Armed only for a message that went out: a tap on a
                    // draft of newlines used to start the clock for nothing.
                    armSlowmode()
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

    /// Composer "Share group" handler. Hidden only in random-chat
    /// (privacy — a stranger shouldn't see a member's group list).
    /// Available in both 1:1 AND group chats — sharing a group into
    /// another group is a legit "invite the whole crew to this other
    /// chat" pattern.
    private var shareGroupPickerHandler: (() -> Void)? {
        // An invite is a link, so a links-off room drops the chip with the
        // rest of them (web hides the same entry behind `linksAllowed`).
        guard linksAllowed else { return nil }
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

    // In-chat relay sharing used to have a composer here: a picker over the
    // off-config relay pool, then an `rcq-relay://` token sealed inside an
    // ordinary message. The COMPOSE half is cut (14b) - the founder does not
    // want it and cannot use it, and it costs the island nothing either way,
    // because the relay rides as an inner envelope kind inside a normal sealed
    // message and the backend has never known the feature exists.
    //
    // ⚠ The RECEIVE half stays, deliberately: see `RelayShareBubble` in
    // `MessageRow`. Rendering an incoming relay as "no longer supported" would
    // take a working way through a block away from the one user who is behind
    // one, which is the opposite of what this app is for. A cut product surface
    // must not cost somebody their connection.

    /// Drains the pending attach action AFTER the menu sheet has
    /// fully torn down. The media picker is presented via UIKit
    /// (`UnifiedMediaPickerPresenter`) instead of a SwiftUI `.sheet`
    /// because iOS 26 silently drops a sheet-after-sheet chain. The
    /// other actions are imperative anyway (UIImagePicker), so they
    /// avoid the bug naturally.
    private func handleAttachDismiss() {
        let action = pendingAttachAction
        pendingAttachAction = nil
        if keyboardUpBeforeAttach {
            keyboardUpBeforeAttach = false
            // After the sheet's dismissal animation, so becomeFirstResponder
            // is not fighting a presentation that is still on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { composerFocusToken &+= 1 }
        }
        DispatchQueue.main.async {
            switch action {
            case .media:
                UnifiedMediaPickerPresenter.present(
                    limit: vm.pendingMediaSlotsLeft,
                    onDone: { items in
                        Task { @MainActor in
                            if !items.isEmpty, attachmentRefused() { return }
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
                        if attachmentRefused() { return }
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
            case .document:
                DocumentPickerPresenter.present(
                    onPick: { picked in
                        Task { @MainActor in
                            // The chip is gone when files are off, so this only
                            // fires for a menu that was already open when the
                            // owner flipped the switch. Guarded anyway: the
                            // island refuses the deposit either way, and a
                            // sentence beats a red error off the wire.
                            if roomRulesBlockSend(isAttachment: true) { return }
                            armSlowmode()
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
        // Tap-to-start model. The previous drag-based gesture (hold to
        // record, slide-up to lock, slide-left to cancel) was failing
        // testers — drag thresholds tripped on incidental release
        // motion so recordings auto-locked the moment the user lifted
        // their finger, and the locked pill's stop button was hidden
        // behind a tap-target that was too small to hit. Simpler: tap
        // mic to start, big STOP / TRASH buttons in the recording pill
        // do the work explicitly. No swipes. Everyone understands.
        Button {
            Task {
                // ⚠ Playback first, recording second. `VoicePlayer` is the
                // process-wide owner and `VoiceRecorder` does not know about
                // it: starting a recording over a playing clip reconfigures
                // the session to `.playAndRecord` + `.defaultToSpeaker` under
                // running playback, so the clip goes on out of the loudspeaker
                // straight into the open mic and is baked into the voice note.
                // Its `teardown()` then deactivates the session out from under
                // a player that still believes it owns it.
                VoicePlayer.shared.stop()
                let ok = await VoiceRecorder.shared.start()
                if !ok { voicePermissionDenied = true }
            }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.Color.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Shown while recording is in progress. The pill owns the
    /// VoiceRecorder observation (see VoiceRecordingPill).
    private var recordingPill: some View {
        VoiceRecordingPill { url, duration in
            pendingVoicePreview = PendingVoicePreview(url: url, duration: duration)
        }
    }

    /// Shown when the user has a finished but-not-yet-sent voice clip.
    /// The pill owns the VoicePlayer observation (see VoicePreviewPill).
    /// The clip stays in a tmp file until either action; we clean up
    /// the file on discard.
    private func previewPill(_ preview: PendingVoicePreview) -> some View {
        VoicePreviewPill(
            preview: preview,
            onDiscard: {
                try? FileManager.default.removeItem(at: preview.url)
                pendingVoicePreview = nil
            },
            onSend: {
                // Not an attachment on purpose: a voice note is a spoken
                // message and stays allowed in a files-off room.
                if roomRulesBlockSend() { return }
                pendingVoicePreview = nil
                armSlowmode()
                Task {
                    if let err = await vm.sendVoice(
                        fileURL: preview.url, durationSec: preview.duration
                    ) {
                        videoError = err
                    }
                }
            }
        )
    }

    private var emojiPanel: some View {
        VStack(spacing: 0) {
            if emojiPrefs.panel.isEmpty {
                // Empty by default: a centered CTA inviting the user to choose
                // their own panel set (and, in the same sheet, their reactions).
                VStack(spacing: 12) {
                    Text("Choose the emoticons for your panel")
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                    Button { showEmojiPicker = true } label: {
                        Text("Choose")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 22).padding(.vertical, 10)
                            .background(Theme.Color.accent, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                HStack {
                    Spacer()
                    Button { showEmojiPicker = true } label: {
                        Text("Edit").font(.footnote).foregroundColor(Theme.Color.accent)
                    }
                    .padding(.trailing, 12).padding(.top, 6)
                }
                grid(entries: panelEntries())
            }
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

    /// The user's chosen panel emoticons (pick order) as grid entries. Empty →
    /// the CTA branch above runs instead, so this is only built when non-empty.
    private func panelEntries() -> [(asset: String, name: String, primaryCode: String)] {
        emojiPrefs.panel.map { (asset: $0, name: $0, primaryCode: ":\($0):") }
    }

    /// The single entry point for "reply to this message": sets the target
    /// (animating the chip in) and hands the keyboard to the composer. Every
    /// reply affordance — swipe, and Reply in the message menu — goes through
    /// here so none of them can drift back to setting `replyTarget` alone.
    private func beginReply(to message: Message) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            vm.replyTarget = message
        }
        composerFocusToken &+= 1
    }

    /// Splice an emoticon shortcode at the current caret position in
    /// the composer, advancing the caret past the inserted text. Falls
    /// back to append-at-end when the caret index is out of range (a
    /// fresh composer that's never been touched, etc.).
    private func insertEmoticonAtCaret(_ code: String) {
        let current = vm.input
        let clamped = max(0, min(composerCaret.value, current.count))
        let head = current.prefix(clamped)
        let tail = current.suffix(current.count - clamped)
        composerCaret.value = clamped + code.count
        vm.setInput(String(head) + code + String(tail))
    }

    private func grid(entries: [(asset: String, name: String, primaryCode: String)]) -> some View {
        let cols = [GridItem](repeating: GridItem(.flexible(), spacing: 8), count: 8)
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(entries, id: \.asset) { entry in
                    Button {
                        insertEmoticonAtCaret(entry.primaryCode)
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

    private func emoticonEntries() -> [(asset: String, name: String, primaryCode: String)] {
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

/// The pin slot of a group that lives on ANOTHER island.
///
/// `GroupService` reaches the server through `APIClient`, which is pinned to our
/// own island, and a guest group is addressed locally by a NEGATIVE alias id
/// (`VisitedIslandsStore.aliasFor`). So `PATCH /groups/<alias>` asked our own
/// island to change a group it has never heard of, and pinning a message inside
/// a cross-island or guest group could not work on iOS at all: the call failed,
/// the optimistic banner rolled back, and the user saw a pin that did nothing.
///
/// The shape here is the one `CrossIslandGroups` uses for every other guest
/// call - raw request, guest jwt, the closed-island token stamp, routed through
/// `IslandHTTP` so it survives a censored network. It is written as `APIError`
/// on the way out so `GroupService.pinFailureMessage` can still tell a 403
/// ("you do not have the info right") from a dead connection.
///
/// ⚠ This belongs in `CrossIslandGroups` next to `groupSealedDeposit`, as a
/// generic foreign PATCH that `GroupService` could route every group edit
/// through - rename, description and the room-rule toggles are all broken in a
/// guest group for exactly the same reason. It sits here because that file is
/// owned by another change in flight; move it when that lands.
enum ChatPinRouting {
    /// `ownUIN` is handed in rather than read here: `AuthService` is main-actor
    /// isolated and this call is not, and the caller is already on the main
    /// actor when it decides the group is foreign.
    static func setForeignPinnedText(
        host: String, remoteId: Int, ownUIN: Int?, pinnedText: String
    ) async throws {
        struct Body: Encodable { let pinned_text: String }
        guard let creds = CrossIslandGroups.foreignCreds(host: host, ownUIN: ownUIN),
              let url = URL(string: "https://\(host)/groups/\(remoteId)") else {
            throw APIError.http(0, nil)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(creds.jwt)", forHTTPHeaderField: "Authorization")
        AccessTokenStore.stamp(&req)
        req.httpBody = try JSONEncoder().encode(Body(pinned_text: pinnedText))
        let (data, resp) = try await IslandHTTP.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8))
        }
    }
}

/// Carries the expanded-pin content's natural height up so the pin ScrollView
/// can shrink to fit short pins (#13).
private struct PinHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

/// "Unread messages" line, drawn immediately above the first message the
/// reader has not seen. It is also the chat's opening anchor, so the reader
/// lands with the line at the top of the screen and the new messages under it.
private struct UnreadDivider: View {
    var surface: WallpaperSurface = .none

    var body: some View {
        Group {
            if surface == .none {
                HStack(spacing: 8) {
                    Rectangle().fill(Theme.Color.accent.opacity(0.5)).frame(height: 1)
                    // The label is measured BEFORE the two rules and keeps
                    // every point it asks for; the rules divide the remainder.
                    // Without the priority HStack serves its least flexible
                    // child first with only available/3 (about 111pt on a 390pt
                    // phone), and the Russian label needs 145pt, so it broke
                    // onto two lines while each rule sat on a third it did not
                    // need. The rules are the elastic part of this row, never
                    // the text.
                    Text("chat.unread_divider".localized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    Rectangle().fill(Theme.Color.accent.opacity(0.5)).frame(height: 1)
                }
            } else {
                // Same answer the day divider gives, for the same reason: two
                // half-transparent accent hairlines and a 10pt label on a
                // picture is a line nobody can follow. Over a wallpaper the
                // label gets the contrast pill and the rules go.
                Text("chat.unread_divider".localized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Theme.Color.bgSecondary.opacity(surface.pillTint))
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

private struct DateDivider: View {
    let label: String
    /// Passed in rather than read off the store per row: this view is built
    /// once per day-group on every pass of the message list.
    var surface: WallpaperSurface = .none

    var body: some View {
        Group {
            if surface == .none {
                HStack {
                    Rectangle().fill(Theme.Color.divider).frame(height: 1)
                    // Same priority as the unread divider above, for the same
                    // reason: the label takes what it needs, the rules take the
                    // rest. "EEE, d MMM" is short enough to survive the
                    // available/3 proposal today, but only by accident, and a
                    // locale with longer weekday or month names would wrap.
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 6)
                        .layoutPriority(1)
                    Rectangle().fill(Theme.Color.divider).frame(height: 1)
                }
            } else {
                // The flanking lines + gray label wash out on a wallpaper, so
                // show a centered contrast pill instead (Android parity).
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Color.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Theme.Color.bgSecondary.opacity(surface.pillTint))
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity)
            }
        }
        // Extra top breathing room so the FIRST divider doesn't butt
        // against the navbar / safe-area when a chat opens with
        // content at the top. Bottom stays minimal so following
        // bubbles sit close to their day's label.
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - Chat wallpaper (global, Android parity)

struct ChatBgPreset: Identifiable {
    let id: String
    let label: String
    let colors: [Color]
}

enum ChatBackgrounds {
    /// The same eight presets the home screen paints, in the same order and
    /// under the same ids, because they ARE the same list: `Theme.Wallpaper`
    /// is the single authority and this is the view-side shape of it.
    ///
    /// ⚠ This used to hold its own hard-coded gradients, authored once for the
    /// dark theme. When the home screen moved to the per-theme table the two
    /// lists disagreed: the settings tile showed a navy "Midnight" while the
    /// screen behind it painted a pale one, and the chat kept the dark stops
    /// under light-theme text. One list, one answer, both themes.
    ///
    /// The stops are trait-resolved colours, so a light/dark flip repaints
    /// without anybody re-reading this.
    static let presets: [ChatBgPreset] = Theme.Wallpaper.presets.map {
        ChatBgPreset(id: $0.id, label: $0.label, colors: $0.colors)
    }
    static func preset(_ id: String) -> ChatBgPreset? { presets.first { $0.id == id } }
}

/// Renders the selected wallpaper behind the message list (or the home list
/// when home==true). Nothing on default. The two slots are independent.
struct ChatBackgroundView: View {
    var home = false
    @StateObject private var bg = ChatBackgroundStore.shared
    @State private var custom: UIImage?
    var body: some View {
        let sel = bg.selection(home: home)
        Group {
            if sel.hasPrefix("preset:"),
               let p = ChatBackgrounds.preset(String(sel.dropFirst(7))) {
                LinearGradient(colors: p.colors, startPoint: .top, endPoint: .bottom)
            } else if sel == "custom", let img = custom {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
        .task(id: "\(sel)#\(bg.customStamp(home: home))") {
            custom = sel == "custom"
                ? UIImage(contentsOfFile: ChatBackgroundStore.imageURL(home: home).path)
                : nil
        }
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

// `RelaySharePickerSheet` lived here: pick a relay out of your off-config pool
// and hand it to the open chat. Cut with the rest of the compose path (14b).
// Receiving one still works and still offers Add - see `RelayShareBubble`.

/// Shared m:ss.t formatter for the voice pills.
private func formatRecordingDuration(_ secs: TimeInterval) -> String {
    let total = Int(secs)
    let m = total / 60
    let s = total % 60
    let tenths = Int((secs - Double(total)) * 10)
    return String(format: "%d:%02d.%d", m, s, tenths)
}

/// Recording-in-progress pill. Big trash + big stop buttons — both 44pt
/// tap targets per HIG, both labelled — so the user always sees how to
/// abort or finish. No swipe gestures anywhere. Stop → onFinished with
/// the take; trash → discard.
///
/// Owns the VoiceRecorder observation: its elapsed/level ticks while
/// recording invalidate this pill only, not every visible row of the
/// chat behind it.
private struct VoiceRecordingPill: View {
    let onFinished: (URL, TimeInterval) -> Void
    @StateObject private var voiceRecorder = VoiceRecorder.shared

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await voiceRecorder.cancel() }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("chat.voice.cancel_hint".localized)
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(.red)
                .frame(width: 56, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                Task {
                    if let result = await voiceRecorder.finish() {
                        await MainActor.run {
                            onFinished(result.url, result.duration)
                        }
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 24))
                    Text("chat.voice.stop_hint".localized)
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Theme.Color.accent)
                .frame(width: 64, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Capsule().fill(Theme.Color.bgSecondary.opacity(0.6)))
        .overlay(Capsule().strokeBorder(Theme.Color.divider.opacity(0.3), lineWidth: 0.5))
    }
}

/// Finished-clip pill: play/pause via the shared VoicePlayer, trash to
/// discard, arrow to send.
///
/// Owns the VoicePlayer observation: its elapsed ticks during playback
/// invalidate this pill only, not every visible row of the chat.
private struct VoicePreviewPill: View {
    let preview: ChatView.PendingVoicePreview
    let onDiscard: () -> Void
    let onSend: () -> Void
    @StateObject private var voicePlayer = VoicePlayer.shared

    var body: some View {
        let isThisPlaying = voicePlayer.playingMessageID == preview.id && voicePlayer.isPlaying
        return HStack(spacing: 10) {
            Button {
                stopAudition()
                onDiscard()
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
                stopAudition()
                onSend()
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

    /// Stop the DRAFT, and only the draft.
    ///
    /// ⚠ `VoicePlayer.stop()` is the process-wide owner's stop: it tears the
    /// player down whatever is loaded into it. Calling it unconditionally here
    /// means sending or discarding a recording also kills the audio document
    /// the user had playing in this chat and dismisses the app-wide strip. The
    /// pill's intent is "stop auditioning my draft", so it only fires when the
    /// draft is what is loaded.
    private func stopAudition() {
        guard voicePlayer.playingMessageID == preview.id else { return }
        voicePlayer.stop()
    }
}

/// Slow-mode deadlines, per group, for THIS process.
///
/// Outside the view on purpose: leaving the chat and coming back must not hand
/// out a free send, and the deadline is not worth a round trip to ask for. Web
/// keeps the same map at module scope (`_slowUntil` in `Chat.tsx`). Memory
/// only, like the web one: a cold start is the island's problem, and the island
/// still holds its own limiter.
@MainActor
private enum SlowmodeClock {
    static var until: [Int: Date] = [:]
}

/// Two things this screen hangs off `body`, in ONE node of its modifier chain:
/// the persistent-strip inset where ChatView is its own presentation root, and
/// the alert that says which room rule refused a send.
///
/// ⚠ One node, and it matters. `body` here is a single expression carrying
/// forty-odd modifiers, and the type checker gives ONE expression a fixed
/// budget: hanging an `.alert` and a conditional inset off the end of that
/// chain separately tipped the whole file into "unable to type-check this
/// expression in reasonable time" - which lands not on the line that added
/// them but on whatever the solver gave up on, three hundred lines away. A
/// `ViewModifier`'s own `body` is a fresh expression with its own budget, so
/// the work moves out of the chain instead of onto it.
private struct ChatRoomChrome: ViewModifier {
    let target: ChatTarget
    @Binding var notice: String?
    // Plain reference on purpose: nothing here renders from the VM, the
    // scenePhase hook below only needs someone to call.
    let vm: ChatViewModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        stripInset(content)
            // Title-only (the notice IS the sentence), so a five-second slow
            // mode wait does not arrive under a heading.
            .alert(notice ?? "", isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )) {
                Button("common.ok".localized, role: .cancel) {}
            }
            // Backgrounding from INSIDE an open chat never fires onDisappear,
            // so the leave-path watermark write was skipped and a suspend or
            // a kill forgot "read to the end": the next open drew the unread
            // line above messages already read. The phase leaving .active is
            // the only leave signal that path gets. This modifier only exists
            // while ChatView is mounted, so firing here IS "chat open".
            .onChange(of: scenePhase) { phase in
                if phase != .active { vm.noteLeavingChat() }
            }
    }

    /// The persistent surfaces - minimized call and room strips, floating
    /// now-playing capsule - are hosted ONCE by the navigation stack in
    /// ContactListView, and every screen pushed into that stack inherits
    /// them. Random chat is the exception: there ChatView is presented in
    /// its own `fullScreenCover`, which starts a fresh safe area the stack's
    /// host never reaches, so that path hosts them itself. It passes
    /// `wrapsNavigationStack: false` because this content sits INSIDE
    /// RandomChatView's stack: its top safe area already contains the
    /// navigation bar, so the capsule overlay needs no manual bar-height
    /// clearance.
    @ViewBuilder
    private func stripInset(_ content: Content) -> some View {
        if case .randomPeer = target {
            content.callMinimizedBarInset(wrapsNavigationStack: false)
        } else {
            content
        }
    }
}
