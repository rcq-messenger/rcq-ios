import SwiftUI
import UIKit

/// Hosts `MessageBannerHost` in a dedicated UIWindow that sits above
/// every app surface — including `.fullScreenCover` (call screen,
/// inventory, roulette, audio room, etc.) and `.sheet` modals. The
/// previous arrangement mounted the host inside `RootView`'s ZStack,
/// which works for NavigationStack pushes but is hidden the moment a
/// fullScreenCover comes up, so a tester deep inside Inventory or a
/// game never saw new-message banners.
///
/// The window is `PassthroughWindow`: touches outside the banner card
/// fall through to whatever's underneath, so the banner doesn't block
/// the rest of the UI from receiving taps.
@MainActor
final class BannerWindowController {
    static let shared = BannerWindowController()

    private var window: PassthroughWindow?

    private init() {}

    /// Lazily installs the window on the active foreground scene. Safe
    /// to call multiple times; idempotent after the first successful
    /// install. Re-binds to a fresh scene on scene reconnect (rare —
    /// only happens if iOS tears down + restores the scene).
    func install() {
        // Re-use existing window if its scene is still attached.
        if let existing = window, existing.windowScene != nil { return }
        guard let scene = activeWindowScene() else { return }

        let w = PassthroughWindow(windowScene: scene)
        // `.alert - 1` keeps us above app content, sheets, and
        // fullScreenCovers (which live at .normal) but below system
        // alerts so a permission prompt isn't drawn under the banner.
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = true

        let host = UIHostingController(
            rootView: MessageBannerHost()
                .environmentObject(AppState.shared)
        )
        host.view.backgroundColor = .clear
        // The hosting controller's root view fills the window; the
        // PassthroughWindow's hitTest decides what's interactive.
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    /// Tear down on logout / account-burn so we don't leak the window
    /// reference across UIN switches.
    func tearDown() {
        window?.isHidden = true
        window = nil
    }

    private func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
    }
}

/// UIWindow subclass that lets touches in empty regions fall through
/// to the underlying app window. Pure-SwiftUI content (Stacks, Text,
/// shape modifiers) does NOT materialise as nested UIViews — the
/// hosting controller's root view is the only real `UIView` in the
/// hierarchy, so `super.hitTest` returns it for every touch on banner
/// content. The earlier "if hit === rootViewController.view → nil"
/// guard therefore rejected ALL taps and SwiftUI never saw them. We
/// now gate by banner presence + a top-band heuristic instead.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // No banner up → pass every touch straight through.
        guard MessageBannerService.shared.current != nil else { return nil }
        // The banner card lives at the top edge. Beyond a generous
        // ceiling (safe-area inset + 6pt top padding + avatar row +
        // up-to-two-line body + 10pt bottom padding + drag slack),
        // there's nothing to interact with, so fall through. 160pt
        // covers notch + Dynamic-Island devices comfortably.
        if point.y > 160 { return nil }
        return super.hitTest(point, with: event)
    }
}
