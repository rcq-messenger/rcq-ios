import SwiftUI

/// Voice-message bubble. Play / pause icon on the left, a thin
/// progress strip in the middle (filled in playback colour up to the
/// current position), duration label on the right.
///
/// One global `VoicePlayer` instance handles the actual audio so only
/// one bubble plays at a time across the whole app — tapping a
/// different bubble interrupts the previous one. The bubble observes
/// `playingMessageID` + `progress` to render its play/pause glyph and
/// the live progress fill.
struct VoiceBubble: View {
    let message: Message
    var trackWidth: CGFloat = 140

    @StateObject private var player = VoicePlayer.shared
    @StateObject private var progress = MediaProgressStore.shared

    /// True while the encrypted blob is still uploading. Bubble shows
    /// a spinner instead of the play icon — same pattern PhotoBubble
    /// uses while the network upload is in flight.
    private var isUploading: Bool {
        message.mediaID == nil && message.deliveryState == .sending
    }

    private var didFailUpload: Bool {
        message.mediaID == nil && message.deliveryState == .failed
    }

    private var isThisOnePlaying: Bool {
        player.playingMessageID == message.id && player.isPlaying
    }
    private var liveProgress: Double {
        player.playingMessageID == message.id ? player.progress : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            playGlyph
            VStack(alignment: .leading, spacing: 4) {
                trackBar
                HStack(spacing: 6) {
                    Text(durationLabel(message.durationSec))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
        }
        .frame(width: trackWidth + 50)
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
    }

    /// Sender (`bubbleSelf` = 0xDCEEFC pale blue) and recipient
    /// (`bubbleOther` = 0xF2F2F2 light gray) bubbles both have
    /// near-white backgrounds in light mode, so the glyph + track
    /// stay accent-tinted on both sides — white-on-white was the
    /// invisible-bubble bug the user hit on their own messages.
    @ViewBuilder
    private var playGlyph: some View {
        ZStack {
            Circle()
                .fill(Theme.Color.accent.opacity(0.18))
                .frame(width: 36, height: 36)
            if isUploading {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Theme.Color.accent)
            } else if didFailUpload {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
            } else {
                Image(systemName: isThisOnePlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.Color.accent)
            }
        }
    }

    /// Two-tone capsule — un-played remainder reads as a soft
    /// divider tint, played portion fills with the accent. Real
    /// waveform peaks would mean stashing extra bytes in the
    /// envelope; out of scope for v1, the bar reads obviously
    /// enough as-is.
    private var trackBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Theme.Color.divider)
                .frame(width: trackWidth, height: 4)
            Capsule()
                .fill(Theme.Color.accent)
                .frame(width: trackWidth * CGFloat(liveProgress), height: 4)
                .animation(.linear(duration: 0.05), value: liveProgress)
        }
    }

    private func handleTap() {
        guard !isUploading, !didFailUpload else { return }
        player.toggle(messageID: message.id, mediaToken: message.mediaID)
    }

    private func durationLabel(_ secs: Double) -> String {
        let total = max(0, Int(secs.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
