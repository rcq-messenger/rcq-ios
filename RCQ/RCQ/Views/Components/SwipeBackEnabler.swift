import SwiftUI
import UIKit

/// Re-points `interactivePopGestureRecognizer.delegate` at a permissive stand-in so the back-swipe
/// keeps firing on screens that hide the navigation bar (SwiftUI nils the delegate at unpredictable moments).
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Holder()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? Holder)?.refreshGesture()
    }

    final class Holder: UIViewController {
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

        // Periodic refresh — iOS 26 nils the delegate 200-500ms after viewDidAppear; a one-shot isn't enough.
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
    func enableSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}
