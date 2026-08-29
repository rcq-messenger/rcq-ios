import Combine
import SwiftUI

/// Republishes one bit - "is the strip on screen" - for hosts that need to
/// animate around it.
///
/// It exists because `VoicePlayer` republishes `elapsed` and `progress`
/// twenty times a second. A host that observed the player directly just to
/// animate the capsule's mount would re-evaluate its whole body - safe-area
/// bars, overlay and all - on every one of those ticks, on every screen,
/// for the entire length of a song.
@MainActor
final class AudioPlayerBarPresence: ObservableObject {
    static let shared = AudioPlayerBarPresence()

    @Published private(set) var isVisible = false

    private var watcher: AnyCancellable?

    private init() {
        // ⚠ Mapped off the PLAYER's publisher, and the closure takes the
        // INCOMING value: `@Published` fires in `willSet`, so reading
        // `VoicePlayer.shared.nowPlaying` in here would see the previous one.
        watcher = VoicePlayer.shared.$nowPlaying
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.isVisible = visible
            }
    }
}

/// App-wide now-playing capsule (founder items 9a + L2.2). Listening to a
/// voice message or an audio file must not hand the screen over to a
/// built-in player: the sound gets a compact floating capsule instead -
/// play/pause, a draggable progress slider, elapsed/total, X - so the chat
/// stays readable and playback survives leaving it.
///
/// It is hosted by `callMinimizedBarInset()` rather than by a screen, and
/// as an OVERLAY pinned under the navigation bar rather than as an inset:
/// an overlay reserves no layout space, so mounting it neither covers the
/// header nor slides the content down - it floats over the messages. The
/// audio does not belong to any screen; `VoicePlayer` owns it for the
/// whole process.
///
/// Shown exactly while `VoicePlayer.nowPlaying` is non-nil. The clip
/// running to its end does NOT close it: `audioPlayerDidFinishPlaying`
/// parks the player in a finished pose (progress pinned at the end) and
/// the capsule stays up for a replay or a scrub back. Only the X button,
/// or a call / room / session yield inside `VoicePlayer`, takes it down.
struct AudioPlayerBar: View {
    @StateObject private var player = VoicePlayer.shared
    /// AlbumViewer's scrub pattern: while the finger is down the slider and
    /// the elapsed label follow this local value, so the 20Hz ticker cannot
    /// fight the drag; the real seek commits once, on release.
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        if player.nowPlaying != nil {
            HStack(spacing: 2) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(
                    (player.isPlaying ? "audio.strip.pause" : "audio.strip.play").localized
                ))

                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : player.progress },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            // Seed with the live position so the thumb
                            // does not jump on the first touch.
                            scrubValue = player.progress
                            scrubbing = true
                        } else {
                            player.seek(toFraction: scrubValue)
                            scrubbing = false
                        }
                    }
                )
                .tint(Theme.Color.accent)
                .accessibilityLabel(Text("audio.strip.seek".localized))

                Text(timeLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .monospacedDigit()
                    .layoutPriority(1)
                    .padding(.leading, 8)

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("audio.strip.close".localized))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            // Opaque fill for the same reason the collapsed pin strip is
            // opaque: the capsule floats directly over live message rows,
            // and bubbles ghosting through a translucent one read as dirt
            // while the list scrolls.
            .background(
                Capsule()
                    .fill(Theme.Color.bgSecondary)
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 2)
            )
            .overlay(
                Capsule().strokeBorder(Theme.Color.divider.opacity(0.3), lineWidth: 0.5)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var timeLabel: String {
        let total = player.duration
        // While scrubbing the label previews the drag target, not the
        // position the player is still sitting at.
        let shown = scrubbing ? scrubValue * total : player.elapsed
        guard total > 0 else { return Self.clock(shown) }
        return "\(Self.clock(shown)) / \(Self.clock(total))"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
