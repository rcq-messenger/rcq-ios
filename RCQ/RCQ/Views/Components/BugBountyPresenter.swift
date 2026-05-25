import SwiftUI
import UIKit

/// Imperative presenter for `BugBountySheet` — same pattern as
/// `UnifiedMediaPickerPresenter`. A SwiftUI `.sheet` attached to
/// RootView gets shadowed when the user is inside another modal
/// (RadioDiscoveryView fullScreenCover, audio room, inventory sheets,
/// etc.) — the binding flips, the haptic fires, but no sheet appears
/// because SwiftUI's sheet machinery only stacks one modal per chain.
/// Walking to the top VC and `present(_:animated:)`-ing imperatively
/// works regardless of how deep the user is in modals.
@MainActor
enum BugBountyPresenter {
    /// True while the sheet is on screen — guards against a second
    /// shake during the dismiss animation queuing up a duplicate.
    private static var isPresenting: Bool = false

    static func present() {
        guard !isPresenting else { return }
        guard let top = topViewController() else { return }
        isPresenting = true
        var hostRef: UIViewController?
        let view = BugBountySheet()
            .onDisappear {
                isPresenting = false
            }
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        hostRef = host
        top.present(host, animated: true)
        _ = hostRef  // silence unused warning; closure above retains by reference
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        // Prefer the key window first; fall back to any window in the
        // active scene. We exclude the banner-overlay window since it's
        // transparent + non-interactive and walking up from there would
        // present onto thin air.
        let isMainWindow: (UIWindow) -> Bool = { w in
            !String(describing: type(of: w)).contains("BannerOverlay")
        }
        let candidates = scenes.flatMap { $0.windows }.filter(isMainWindow)
        let window = candidates.first(where: { $0.isKeyWindow }) ?? candidates.first
        guard var vc = window?.rootViewController else { return nil }
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }
}
