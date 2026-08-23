import Combine
import SwiftUI

/// Republishes one bit - "is the strip on screen" - for hosts that need to
/// animate around it.
///
/// It exists because `VoicePlayer` republishes `elapsed` and `progress`
/// twenty times a second. A host that observed the player directly just to
/// animate its inset would re-evaluate its whole safe-area content, and
/// re-measure the inset, on every one of those ticks, on every screen, for
/// the entire length of a song.
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

/// App-wide now-playing strip (founder item 9a). Listening to a voice
/// message or an audio file must not hand the screen over to a built-in
/// player: the sound gets a thin strip pinned above the content instead,
/// so the chat stays readable and playback survives leaving it.
///
/// It is hosted by `callMinimizedBarInset()` rather than by a screen, for
/// the same reason the minimized-call bar is: `safeAreaInset` does not
/// pass through a `navigationDestination`, so each top-level screen
/// reserves the space itself and the strip is simply drawn there by
/// whichever one is on screen. The audio does not belong to any of them -
/// `VoicePlayer` owns it for the whole process.
///
/// Shown exactly while `VoicePlayer.nowPlaying` is non-nil, which means it
/// stays up through a pause and goes away on its own when the clip ends
/// (`audioPlayerDidFinishPlaying` → `stop()`).
struct AudioPlayerBar: View {
    @StateObject private var player = VoicePlayer.shared

    var body: some View {
        if let entry = player.nowPlaying {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: entry.kind == .voiceMessage ? "waveform" : "music.note")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 18)

                    // `maxWidth: .infinity` rather than a trailing `Spacer`:
                    // an HStack splits slack between a Spacer and a
                    // truncatable Text, so the filename lost ~80pt to empty
                    // space and showed an ellipsis it did not need.
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)

                    Text(timeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                        .monospacedDigit()

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
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 4)

                // Progress reads as a hairline under the row rather than a
                // second widget: the strip is a status line, not a player.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.Color.divider)
                        Rectangle()
                            .fill(Theme.Color.accent)
                            .frame(width: geo.size.width * CGFloat(player.progress))
                            .animation(.linear(duration: 0.05), value: player.progress)
                    }
                }
                .frame(height: 2)
            }
            .background(Theme.Color.bgSecondary)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var timeLabel: String {
        let total = player.duration
        guard total > 0 else { return Self.clock(player.elapsed) }
        return "\(Self.clock(player.elapsed)) / \(Self.clock(total))"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
