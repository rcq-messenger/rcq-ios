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
            case .voice:
                // Voice message in long-press preview. `VoiceBubble`
                // brings its own bubble background (waveform inset on
                // a tinted rounded rect), so we render it raw — the
                // earlier extra `.padding + .background + .cornerRadius`
                // wrapper produced a bubble-inside-bubble nested look
                // not present on the real chat row.
                VoiceBubble(message: message)
            case .poll:
                // Polls are gone (14a). The branch stays so the long-press
                // preview of an old poll row shows the same placeholder the
                // chat row does, instead of falling through to the default
                // branch and rendering the leftover payload JSON.
                pollSummary
            default:
                EmoticonText(text: message.text)
                    .lineLimit(6)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
                    .cornerRadius(Theme.Metrics.bubbleRadius)
            }
        }
    }

    private var pollSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 14))
                .foregroundColor(Theme.Color.textSecondary)
            Text("chat.poll.removed".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius))
    }
}
