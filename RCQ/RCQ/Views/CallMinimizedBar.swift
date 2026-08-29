import SwiftUI

/// Compact strip shown above the contact list while a call is minimized.
/// Tap to bring the full call screen back. Hidden during ringing states.
struct CallMinimizedBar: View {
    @StateObject private var calls = CallService.shared

    var body: some View {
        if case .connected(let call) = calls.state, calls.isMinimized {
            Button {
                calls.expand()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: call.media == .video ? "video.fill" : "phone.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 10, weight: .semibold))
                    Text(call.peerNickname)
                        .foregroundColor(.white)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    LiveDurationPill(startedAt: call.startedAt)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.Color.accent)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension View {
    /// Host the persistent audio surfaces. The minimized-call and
    /// minimized-audio-room strips reserve top safe-area (they NEED to
    /// displace the content: a live call must never be covered). The
    /// now-playing audio capsule is a floating overlay instead (L2.2): an
    /// inset reserves space, which both parked the old strip above the
    /// header and slid the whole stack down on mount, so the capsule
    /// reserves nothing and floats over the messages below the bar.
    ///
    /// ⚠ APPLY THIS TO THE `NavigationStack` ITSELF, not to the view inside it.
    /// The old rule written here said it had to go on every screen because
    /// `safeAreaInset` "doesn't pass through `navigationDestination`", and that
    /// is only true of an inset applied to the stack's ROOT CONTENT: the root
    /// is a sibling of the pushed destination, so of course the destination
    /// never sees it. On the stack, the inset wraps everything the stack ever
    /// draws and every push inherits it, which is what a strip that survives
    /// leaving the chat needs. Applying it per screen is what made a call
    /// disappear the moment the user opened Group Info.
    ///
    /// A `.sheet` or `.fullScreenCover` still starts a fresh safe area that no
    /// ancestor inset reaches, so a modal that wants the strips applies it to
    /// its own stack (one line covers everything pushed inside it).
    ///
    /// - Parameter wrapsNavigationStack: true (the default, the primary host
    ///   in ContactListView) when the modified view IS a `NavigationStack`.
    ///   The stack's own safe area is only the status bar - the navigation
    ///   bar is a descendant the overlay knows nothing about - so the capsule
    ///   must clear the bar's height by hand. Pass false when the modified
    ///   view already lives INSIDE a stack (random chat), where the top safe
    ///   area includes the bar and padding again would drop the capsule
    ///   mid-screen.
    func callMinimizedBarInset(wrapsNavigationStack: Bool = true) -> some View {
        modifier(CallMinimizedBarInset(wrapsNavigationStack: wrapsNavigationStack))
    }
}

private struct CallMinimizedBarInset: ViewModifier {
    let wrapsNavigationStack: Bool
    @StateObject private var calls = CallService.shared
    @StateObject private var rooms = AudioRoomService.shared
    /// ⚠ `AudioPlayerBarPresence`, NOT `VoicePlayer`. The mount animation
    /// has to fire on the same change that shows the capsule, but observing
    /// the player itself would re-evaluate this whole modifier (and
    /// re-measure the safe-area inset) twenty times a second for the length
    /// of a song, on every screen that applies it.
    @StateObject private var audio = AudioPlayerBarPresence.shared

    private var roomBarVisible: Bool {
        rooms.activeRoomID != nil && rooms.isMinimized
    }

    /// Every screen in the app keeps `.inline` titles, so the portrait
    /// navigation bar is the stable system 44pt. No API exposes a descendant
    /// bar's height to an ancestor overlay; if a non-inline screen (or a
    /// landscape-only layout, where the bar is shorter) ever matters, this
    /// constant is the first suspect.
    private var audioCapsuleTopPadding: CGFloat {
        (wrapsNavigationStack ? 44 : 0) + 6
    }

    func body(content: Content) -> some View {
        content
            // The capsule is an OVERLAY on the same content the inset wraps,
            // NOT a member of the inset below: an overlay reserves no space,
            // so showing it never shifts the layout, and the top padding
            // lands it under the header, over the scroll content. It never
            // renders alongside the call / room strips - `VoicePlayer`
            // refuses to play while either is up - so the top slot is free.
            .overlay(alignment: .top) {
                AudioPlayerBar()
                    .padding(.horizontal, 10)
                    .padding(.top, audioCapsuleTopPadding)
                    .animation(.easeInOut(duration: 0.22), value: audio.isVisible)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    CallMinimizedBar()
                        .animation(.easeInOut(duration: 0.2), value: calls.isMinimized)
                    // Server enforces single-busy (ws.py `_is_busy`); both render conditionally.
                    if roomBarVisible {
                        AudioRoomMinimizedBar()
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                            .padding(.horizontal, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.28), value: roomBarVisible)
            }
    }
}

private struct LiveDurationPill: View {
    let startedAt: Date
    @State private var now = Date()

    var body: some View {
        let secs = max(0, Int(now.timeIntervalSince(startedAt)))
        Text(String(format: "%d:%02d", secs / 60, secs % 60))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.white.opacity(0.18))
            .clipShape(Capsule())
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}
