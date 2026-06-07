import SwiftUI
import UIKit

/// Wrapper around `MediaAlbumBubble` that adds the same row-level
/// behaviours a regular `MessageRow` has — long-press for the action
/// overlay, swipe-right for reply, selection-mode tap toggling, and
/// the time/sender chrome around the bubble.
struct AlbumRowView: View {
    let items: [Message]
    let isInGroupChat: Bool
    let senderNickname: String
    let isSelecting: Bool
    let isSelected: Bool
    let onTapTile: (Int) -> Void
    let onLongPress: () -> Void
    let onSwipeReply: () -> Void
    var onTapReaction: ((String) -> Void)? = nil
    var onShowReactors: (() -> Void)? = nil

    @State private var swipeOffset: CGFloat = 0
    @State private var swipeArmed: Bool = false

    private static let swipeTriggerDistance: CGFloat = 60
    private static let swipeMaxDistance: CGFloat = 80

    private var first: Message { items.first! }

    var body: some View {
        if isSelecting {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? Theme.Color.accent : Theme.Color.textSecondary)
                    .padding(.leading, 6)
                rowContent
                    .allowsHitTesting(false)
            }
            .background(
                Rectangle()
                    .fill(isSelected ? Theme.Color.accent.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                UISelectionFeedbackGenerator().selectionChanged()
                onTapTile(0)  // toggle whole album
            }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        let isFromMe = first.isFromMe
        return ZStack(alignment: .trailing) {
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
            HStack {
                if isFromMe { Spacer(minLength: 40) }
                VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                    if isInGroupChat && !isFromMe && !senderNickname.isEmpty {
                        Text(senderNickname)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    MediaAlbumBubble(
                        items: items,
                        onTapTile: onTapTile,
                        onLongPress: onLongPress
                    )
                    // Caption rides inline on the last media so it
                    // can't race ahead of the (slow) video upload —
                    // here we re-render it as a normal-looking text
                    // bubble so visually it still reads as a separate
                    // chat message.
                    if let caption = items.last?.text, !caption.isEmpty {
                        // Caption text alignment matches the outgoing-
                        // vs-incoming side so a multi-line caption on
                        // a right-pinned bubble doesn't read flush-left
                        // inside a right-edge bubble. Mirrors the row
                        // alignment of the surrounding VStack.
                        Text(caption)
                            .font(.body)
                            .foregroundColor(Theme.Color.textPrimary)
                            .multilineTextAlignment(isFromMe ? .trailing : .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                            .cornerRadius(Theme.Metrics.bubbleRadius)
                    }
                    HStack(spacing: 4) {
                        Text(DateFormatters.timeOfDay.string(from: first.sentAt))
                            .font(Theme.Font.timestamp)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    if !first.reactions.isEmpty, let onTapReaction {
                        HStack(spacing: 4) {
                            ReactionsBar(message: first, onTap: onTapReaction, onShowWho: onShowReactors)
                        }
                    }
                }
                if !isFromMe { Spacer(minLength: 40) }
            }
            .offset(x: swipeOffset)
        }
        .frame(maxWidth: .infinity, alignment: isFromMe ? .trailing : .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // highPriority instead of simultaneous: once the drag claims
        // the touch (after 18pt of motion), the inner Button-tap is
        // cancelled — without this, a swipe-reply also opens the
        // viewer because Button registers the touch-up as a tap.
        .highPriorityGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    if value.startLocation.x < 32 { return }
                    let raw = value.translation.width
                    if raw < 0 {
                        let damped = -min(Self.swipeMaxDistance, abs(raw))
                        swipeOffset = damped
                        let nowArmed = abs(damped) >= Self.swipeTriggerDistance
                        if nowArmed && !swipeArmed {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        swipeArmed = nowArmed
                    } else {
                        swipeOffset = 0
                    }
                }
                .onEnded { value in
                    let didReply = swipeArmed
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        swipeOffset = 0
                    }
                    swipeArmed = false
                    if didReply {
                        onSwipeReply()
                    }
                }
        )
    }

}
