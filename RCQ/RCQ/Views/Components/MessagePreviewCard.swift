import SwiftUI

/// Compact non-interactive copy of a chat bubble used by the
/// long-press action overlay. We render a pared-down snapshot
/// of the focused message — body content + the bubble's own
/// background — without timestamps, delivery icons, the
/// reactions row, or the long-press handler. Sits visually
/// "above" the dimming scrim so the message the user pressed
/// stays readable while the action panels float around it.
struct MessagePreviewCard: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 0) }
            content
            if !message.isFromMe { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.deletedForEveryone {
            Text("Message deleted")
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius)
                        .stroke(Theme.Color.divider, lineWidth: 1)
                )
        } else {
            // Bubble dimensions here MUST match the chat row's defaults
            // (PhotoBubble.maxWidth = 240, premium size 240×aspect)
            // — earlier preview used 220, which made the bubble visibly
            // narrower than the actual message and read as "squeezed by
            // padding" when the user long-pressed.
            switch message.kind {
            case .photo:
                PhotoBubble(message: message, maxWidth: 240)
            case .video:
                VideoBubble(message: message, maxWidth: 240)
            case .premiumPhoto, .premiumVideo:
                // Paywalled media — render the same bubble the chat
                // row uses (locked-blur or unlocked photo/video,
                // depending on the recipient's unlock state). Without
                // this branch the preview fell through to the text
                // fallback and rendered as an empty bubble.
                //
                // `onUnlock` is a no-op here: the long-press preview
                // is read-only — the unlock CTA fires from the chat
                // row itself, not from the action overlay.
                PremiumLockedBubble(
                    message: message,
                    onUnlock: {},
                    size: CGSize(width: 240, height: 240),
                )
            case .voice:
                // Voice message in long-press preview. Reuse the chat
                // row's voice bubble so the user sees the same waveform
                // + duration they're acting on.
                VoiceBubble(message: message)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                    .cornerRadius(Theme.Metrics.bubbleRadius)
            default:
                EmoticonText(text: message.text)
                    .lineLimit(6)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                    .cornerRadius(Theme.Metrics.bubbleRadius)
            }
        }
    }
}
