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
    /// Reserve top safe-area for `CallMinimizedBar`. Must be applied on every
    /// screen — `safeAreaInset` doesn't pass through `navigationDestination`.
    func callMinimizedBarInset() -> some View {
        modifier(CallMinimizedBarInset())
    }
}

private struct CallMinimizedBarInset: ViewModifier {
    @StateObject private var calls = CallService.shared
    @StateObject private var rooms = AudioRoomService.shared

    private var roomBarVisible: Bool {
        rooms.activeRoomID != nil && rooms.isMinimized
    }

    func body(content: Content) -> some View {
        content
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
