import AVKit
import SwiftUI

/// Single chat message bubble — extracted from `ChatView` to keep
/// the parent file under SwiftUI's type-checker complexity ceiling.
/// Self-contained: every dependency travels as an init parameter
/// (target, callbacks, group-member list for @mention rendering),
/// so the row knows nothing about the surrounding chat lifecycle.
struct MessageRow: View {
    let message: Message
    let showSender: Bool
    let senderNickname: String
    let displayBody: String
    let isTranslated: Bool
    let isHighlighted: Bool
    var isSelected: Bool = false
    var showSelectionAffordance: Bool = false
    let onTapReaction: (String) -> Void
    var jetonTotal: Int = 0
    var onTapJeton: (() -> Void)? = nil
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

    @State private var swipeOffset: CGFloat = 0
    @State private var swipeArmed: Bool = false
    @State private var bubblePressed: Bool = false
    @State private var showUnlockConfirm: Bool = false
    @State private var unlockError: String?
    @State private var unlockInFlight: Bool = false

    private static let swipeTriggerDistance: CGFloat = 60
    private static let swipeMaxDistance: CGFloat = 80

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
                Text(message.text)
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
                if !message.reactions.isEmpty || jetonTotal > 0 {
                    HStack(spacing: 4) {
                        if message.isFromMe { Spacer(minLength: 40) }
                        if !message.reactions.isEmpty {
                            ReactionsBar(message: message, onTap: onTapReaction)
                        }
                        if jetonTotal > 0 {
                            jetonPill
                        }
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
                Button {
                    AppState.shared.pendingOpenUserProfile = message.senderUIN
                } label: {
                    Text(senderNickname)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                }
                .buttonStyle(.plain)
            }
            if let fwdName = message.forwardedFromName, !fwdName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 9))
                    Text(String(format: "chat.forwarded_from".localized, fwdName))
                        .font(.caption2.italic())
                }
                .foregroundColor(Theme.Color.textSecondary)
            }
            if let snippet = message.replyToSnippet, !snippet.isEmpty {
                Button {
                    if let target = message.replyToID {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onTapReplyQuote(target)
                    }
                } label: {
                    HStack(spacing: 6) {
                        // Same 3pt stroke as the composer reply strip
                        // at line 1232 so the bubble-side quote rule
                        // visually matches the in-progress reply
                        // preview a sender just sent from.
                        Rectangle()
                            .fill(Theme.Color.accent)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            if let author = message.replyToAuthorName, !author.isEmpty {
                                Text(author)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(Theme.Color.accent)
                                    .lineLimit(1)
                            }
                            // If the quoted snippet is a market / UIN
                            // share URL, render the actual item card
                            // instead of the raw `rcq.app/m/<id>` text.
                            // Composer already shows the card when
                            // composing the reply — the bubble side
                            // had been left as plain text.
                            if let market = MarketLinkParser.parse(snippet) {
                                MarketReplyMiniCard(listingID: market.listingID)
                            } else if let uinShare = UinLinkParser.parse(snippet) {
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
                    EmoticonText(text: displayBody, members: currentGroupMembers)
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
                    EmoticonText(text: displayBody, members: currentGroupMembers)
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
                    EmoticonText(text: displayBody, members: currentGroupMembers)
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
                    EmoticonText(text: displayBody, members: currentGroupMembers)
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
        } else if message.kind == .premiumPhoto || message.kind == .premiumVideo {
            // Same component handles locked + unlocked so the unlock transition is an in-place blur dissolve.
            let size = Self.premiumBubbleSize(thumbnailB64: message.thumbnailB64)
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                PremiumLockedBubble(message: message, onUnlock: { askUnlock(message) }, size: size)
                if !displayBody.isEmpty {
                    EmoticonText(text: displayBody, members: currentGroupMembers)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                        .cornerRadius(Theme.Metrics.bubbleRadius)
                    if isTranslated { translatedFooter }
                }
            }
        } else if let share = MarketLinkParser.parse(message.text) {
            // Share-to-chat market link — full card preview takes the
            // place of plain text so the recipient sees the item
            // before tapping. The card itself routes the tap into
            // `AppState.handle(deepLink:)` so it opens the listing
            // detail sheet.
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                MarketLinkBubble(listingID: share.listingID, rawURL: share.url)
                if isTranslated { translatedFooter }
            }
        } else if let share = UinLinkParser.parse(message.text) {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                UinLinkBubble(listingID: share.listingID, rawURL: share.url)
                if isTranslated { translatedFooter }
            }
        } else if let share = GroupLinkParser.parse(message.text) {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                GroupLinkBubble(groupID: share.groupID, rawURL: share.url)
                if isTranslated { translatedFooter }
            }
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                EmoticonText(text: displayBody, members: currentGroupMembers)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                    .cornerRadius(Theme.Metrics.bubbleRadius)
                if isTranslated { translatedFooter }
                // Read off the original body so a translation that mangles the URL still gets a preview.
                if let url = LinkDetector.firstURL(in: message.text) {
                    LinkPreviewCard(url: url)
                }
            }
        }
    }

    private var jetonPill: some View {
        Button {
            onTapJeton?()
        } label: {
            HStack(spacing: 3) {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 14, height: 14)
                Text("\(jetonTotal)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.Color.accent.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(onTapJeton == nil)
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

    fileprivate static func premiumBubbleSize(thumbnailB64: String?) -> CGSize {
        let width: CGFloat = 240
        let maxHeight: CGFloat = width * 1.4
        let defaultHeight: CGFloat = width * 0.75
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

    fileprivate func askUnlock(_ message: Message) {
        showUnlockConfirm = true
    }

    fileprivate func performUnlock(_ message: Message) async {
        if unlockInFlight { return }
        unlockInFlight = true
        defer { unlockInFlight = false }
        do {
            _ = try await MessageService.shared.unlockPremium(message: message)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch let APIError.http(402, body) {
            _ = body
            unlockError = "chat.premium.error.insufficient".localized
        } catch APIError.http(404, _) {
            unlockError = "chat.premium.error.gone".localized
        } catch {
            unlockError = "chat.premium.error.generic".localized
        }
    }
}
