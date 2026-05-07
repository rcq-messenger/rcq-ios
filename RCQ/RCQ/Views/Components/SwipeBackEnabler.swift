import SwiftUI
import UIKit

/// Re-enables UIKit's edge-pop gesture on push'd SwiftUI views
/// that have hidden the system navigation bar. SwiftUI on iOS
/// 16+ usually keeps `interactivePopGestureRecognizer` alive
/// when `toolbar(.hidden, for: .navigationBar)` is applied, but
/// in practice the gesture's delegate gets nil'd out on a few
/// of our screens (the chat, info pages, etc.) and the back
/// swipe stops working entirely. This view installs a UIKit-side
/// hook that re-points the recognizer's delegate at a permissive
/// stand-in, so the swipe fires even when the bar is hidden.
///
/// Drop into any push destination's view tree:
///
/// ```swift
/// var body: some View {
///     myContent
///         .background(SwipeBackEnabler())
/// }
/// ```
///
/// Or apply via the `View.enableSwipeBack()` modifier below.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Holder()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? Holder)?.refreshGesture()
    }

    final class Holder: UIViewController {
        // Strong reference so the delegate isn't deallocated mid-flight.
        private let proxyDelegate = PermissiveDelegate()
        private var refreshTimer: Timer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            refreshGesture()
            startRefreshTimer()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopRefreshTimer()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            refreshGesture()
        }

        /// SwiftUI on iOS 26 clears `interactivePopGestureRecognizer.delegate`
        /// at unpredictable moments — sheet present/dismiss, toolbar
        /// re-render, navigation transition mid-flight. A one-shot
        /// refresh on `viewDidAppear` isn't enough; the delegate
        /// gets nil'd back out 200-500ms later and the back-swipe
        /// silently dies. A periodic refresh while visible keeps
        /// the gesture wired up. 2.5s is the sweet spot — frequent
        /// enough that the gesture is always live by the time the
        /// user reaches for the edge, infrequent enough not to add
        /// runloop noise.
        private func startRefreshTimer() {
            stopRefreshTimer()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                self?.refreshGesture()
            }
        }

        private func stopRefreshTimer() {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }

        func refreshGesture() {
            guard let nav = nearestNavigationController() else { return }
            guard let gesture = nav.interactivePopGestureRecognizer else { return }
            // Always set delegate (cheap; no-op if already set).
            // Pointing it at a permissive delegate that returns true
            // when the stack has something to pop restores the edge
            // swipe even when SwiftUI nulled the original delegate.
            gesture.delegate = proxyDelegate
            gesture.isEnabled = nav.viewControllers.count > 1
        }

        private func nearestNavigationController() -> UINavigationController? {
            var current: UIViewController? = self
            while let vc = current {
                if let nav = vc.navigationController { return nav }
                current = vc.parent ?? vc.presentingViewController
            }
            return nil
        }

        deinit { refreshTimer?.invalidate() }
    }

    private final class PermissiveDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Only allow when there's actually something to pop.
            // SwiftUI sometimes fires a stray edge-pan on the
            // root, which would otherwise no-op visibly.
            guard let nav = (gestureRecognizer.view?.next as? UINavigationController)
                    ?? (gestureRecognizer.view as? UIScrollView)?.findNav() else {
                return true
            }
            return nav.viewControllers.count > 1
        }
    }
}

private extension UIView {
    func findNav() -> UINavigationController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let nav = r as? UINavigationController { return nav }
            responder = r.next
        }
        return nil
    }
}

extension View {
    /// Sugar for `.background(SwipeBackEnabler())`. Drop on any
    /// push destination whose default back-swipe was eaten by a
    /// hidden navigation bar.
    func enableSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}
