import SwiftUI
import SafariServices

/// In-app browser (Telegram-style): an http(s) link tapped anywhere in the
/// app opens in an `SFSafariViewController` presented over the app instead of
/// bouncing the user out to Safari. Safari VC's own toolbar keeps the
/// "open in Safari" escape hatch. Installed as the root `OpenURLAction` in
/// `RCQApp`, so message-text links, link-preview cards and about-links all
/// resolve here.
///
/// RCQ's own deep links (rcq:// and the https rcq.app join/add/referral/group
/// forms) never land in a web view — they route into
/// `AppState.handle(deepLink:)` exactly like an external open would. Non-web
/// schemes (mailto:, tel:) fall through to the system.
@MainActor
enum InAppBrowser {

    /// Route a tapped URL. Usable both as the root `OpenURLAction` body and
    /// as a direct call from button handlers.
    @discardableResult
    static func open(_ url: URL) -> OpenURLAction.Result {
        if AppState.isDeepLink(url) {
            AppState.shared.handle(deepLink: url)
            return .handled
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return .handled
        }
        present(url)
        return .handled
    }

    private static func present(_ url: URL) {
        guard let top = topController() else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = UIColor(Theme.Color.accent)
        top.present(safari, animated: true)
    }

    /// Walk the presented-controller chain of the active scene's key window
    /// so the browser presents correctly even over a SwiftUI sheet.
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
