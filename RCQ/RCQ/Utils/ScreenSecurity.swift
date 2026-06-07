import SwiftUI
import UIKit

/// Screen-privacy guard for secure (per-conversation) chats.
///
/// iOS has NO public API to blank a screenshot. The only known way is the
/// private secure-`UITextField` layer trick, which reparents the window's ROOT
/// layer into a private text-field canvas while protecting and moves it back
/// when disabling. That proved **unstable**: toggling secure mode on/off inside
/// a live chat reparented `window.layer` mid-render, which crashed
/// (`EXC_BAD_ACCESS` on the dangling private canvas) or left the window without
/// its content layer for a frame (black screen). Moving the window's own layer
/// while UIKit/SwiftUI is managing it is simply not safe, so that mechanism is
/// **removed**.
///
/// What remains is rock-stable and 100% public API:
///   • **App-switcher snapshot** blanked — RootView shows the privacy cover
///     while a secure chat is on screen and the scene is not active.
///   • **Screen recording / mirroring** covered — driven by `isCaptured`.
///   • **Screenshot detection** — a screenshot is detected
///     (`userDidTakeScreenshotNotification`, handled in ChatView) and both
///     sides get an "X took a screenshot" system message. That notification is
///     the core secret-chat signal.
///
/// Honest limitation (unchanged by all of the above): a screenshot's *image* is
/// not blanked, and a phone can never blank a screenshot taken on the OTHER
/// person's device anyway. The value is the recording cover + the mutual
/// "took a screenshot" notice.
@MainActor
final class ScreenSecurity: ObservableObject {
    static let shared = ScreenSecurity()

    /// True while the screen is being recorded or mirrored (AirPlay / cable).
    @Published private(set) var isCaptured = UIScreen.main.isCaptured

    /// Number of SECURE chat surfaces currently on screen. A chat view calls
    /// `enterChat()` ONLY when that thread has screen-secure mode on, so the
    /// rest of the app — and non-secure chats — are never affected. A depth
    /// counter (not a bool) so navigating from one secure chat straight into
    /// another never momentarily drops protection.
    private var chatDepth = 0

    /// Whether a secure chat is currently on screen. Drives the app-level
    /// recording / app-switcher cover (RootView).
    var protectsLiveContent: Bool { chatDepth > 0 }

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isCaptured = UIScreen.main.isCaptured }
        }
    }

    /// A SECURE chat view calls these on appear / disappear (only when the
    /// thread's secure mode is on) so the cover is scoped to that chat.
    func enterChat() {
        chatDepth += 1
        if chatDepth == 1 { objectWillChange.send() }
    }

    func leaveChat() {
        chatDepth = max(0, chatDepth - 1)
        if chatDepth == 0 { objectWillChange.send() }
    }

    /// Retained for the launch / scene-active call sites. No layer surgery any
    /// more — just keeps the capture flag current for a freshly-active scene.
    func refresh() {
        isCaptured = UIScreen.main.isCaptured
    }
}
