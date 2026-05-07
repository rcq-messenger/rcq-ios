import SwiftUI

/// Compact strip shown above the contact list while a call is minimized.
/// Tap to bring the full call screen back. Acts like the green "ongoing
/// call" pill iOS shows at the top — same purpose, our visual.
///
/// Only visible when `CallService.state == .connected && isMinimized`.
/// The ringing states stay full-screen because the user has to interact
/// with them (Accept / Decline / Cancel).
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
                // Slim strip: ~22pt content height instead of the
                // previous ~32pt so it doesn't bleed over the chat
                // header below. Stacked safeAreaInsets in SwiftUI
                // compose by reserving space, so a thinner pill
                // means less of the chat scroll gets pushed down.
                // Equal vertical padding (6pt top + 6pt bottom)
                // makes the pill sit symmetrically — earlier 3pt
                // version was visually flush against the bottom, so
                // the gap between the pill and the chat header below
                // looked uneven. The extra 3pt of bottom breathing
                // room costs nothing in screen real estate.
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.Color.accent)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension View {
    /// Reserve the top safe-area row for `CallMinimizedBar` whenever a
    /// connected call is minimized. Apply on every root-screen view
    /// that the user can sit on while a call is in flight (contact
    /// list, chat, settings sheets, etc.) — `safeAreaInset` from a
    /// parent of a `NavigationStack` does NOT pass through
    /// `navigationDestination` push, so each screen has to host its
    /// own copy. Without this on `ChatView`, the bar gets drawn on
    /// top of the chat header and clips the nickname.
    func callMinimizedBarInset() -> some View {
        modifier(CallMinimizedBarInset())
    }
}

private struct CallMinimizedBarInset: ViewModifier {
    @StateObject private var calls = CallService.shared
    @StateObject private var rooms = AudioRoomService.shared

    /// Single derived bool combining the two reasons the bar can
    /// vanish: user expanded back into the room (`isMinimized` →
    /// false) OR they left the room entirely (`activeRoomID` → nil).
    /// Without this, `.animation(value: rooms.isMinimized)` only
    /// animated the first case and the second flipped instantly —
    /// the bar popped out of view abruptly when the user exited.
    private var roomBarVisible: Bool {
        rooms.activeRoomID != nil && rooms.isMinimized
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    CallMinimizedBar()
                        .animation(.easeInOut(duration: 0.2), value: calls.isMinimized)
                    // Single-busy means only one of these can show at a
                    // time (server enforces — see ws.py `_is_busy`), but
                    // we render both regardless and let each gate itself
                    // on its own state. `nil`-room collapses to nothing.
                    if roomBarVisible {
                        AudioRoomMinimizedBar()
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                            .padding(.horizontal, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    // Game minis (Crash, Auction) live at root in
                    // `GameMinisOverlayHost` — draggable + edge-
                    // peek floating bubbles, NOT a top-pinned bar.
                    // See `RCQApp.RootView`.
                }
                // Watch the COMBINED visibility flag so both paths
                // (user re-expanded the room vs user fully exited)
                // play the same slide-up dismissal. Slightly longer
                // 0.28s than the call bar so the audio-room dismiss
                // reads as a deliberate gesture, not an accident.
                .animation(.easeInOut(duration: 0.28), value: roomBarVisible)
            }
    }
}

/// "0:42" pill that ticks every second. Lives in this file so the bar's
/// re-renders are bounded — only the pill redraws on each tick, not the
/// whole strip.
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
