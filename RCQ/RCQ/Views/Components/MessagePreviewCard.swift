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
        } else if message.kind == .text,
                  let share = MarketLinkParser.parse(message.text) {
            MarketLinkBubble(listingID: share.listingID, rawURL: share.url)
        } else if message.kind == .text,
                  let share = UinLinkParser.parse(message.text) {
            UinLinkBubble(listingID: share.listingID, rawURL: share.url)
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
                // Voice message in long-press preview. `VoiceBubble`
                // brings its own bubble background (waveform inset on
                // a tinted rounded rect), so we render it raw — the
                // earlier extra `.padding + .background + .cornerRadius`
                // wrapper produced a bubble-inside-bubble nested look
                // not present on the real chat row.
                VoiceBubble(message: message)
            case .poll:
                // The full `PollBubble` would trigger a /polls/{id}
                // fetch + tap-to-vote scaffolding inside a read-only
                // preview — too heavy. Render a compact card with
                // just the question, the type chip, and the option
                // labels so the user recognises what they
                // long-pressed without the raw JSON the default
                // `text` branch would otherwise show.
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

    @ViewBuilder
    private var pollSummary: some View {
        let payload = PollPayload.decode(from: message.text)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundColor(Theme.Color.accent)
                Text(payload?.singleChoice ?? true
                     ? "poll.header.single".localized
                     : "poll.header.multi".localized)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            Text(payload?.question ?? "chat.preview.poll".localized)
                .font(.body.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let options = payload?.options {
                ForEach(Array(options.enumerated()), id: \.offset) { _, label in
                    HStack(spacing: 6) {
                        Image(systemName: "circle")
                            .foregroundColor(Theme.Color.textSecondary)
                        Text(label)
                            .font(.callout)
                            .foregroundColor(Theme.Color.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius))
    }
}
