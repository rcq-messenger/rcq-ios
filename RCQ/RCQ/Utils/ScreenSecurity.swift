import SwiftUI
import UIKit

/// Screen-privacy guard — the iOS analogue of Android's FLAG_SECURE, as far as
/// public + commonly-used APIs allow. When the user turns it on:
///   • Screenshots and screen recording / mirroring render blank, via the
///     well-worn secure-`UITextField` layer trick (iOS has no public API for
///     this; this is the same approach Telegram and banking apps use).
///   • The app-switcher snapshot is blanked (RootView shows the privacy cover
///     while backgrounded).
///   • Screen recording is also caught by `isCaptured` as a belt-and-suspenders
///     cover, in case the layer trick degrades on a future iOS.
///
/// Default OFF, backed by UserDefaults. The secure-field layer is wired once per
/// window and protection is toggled via `isSecureTextEntry`, so turning it off
/// is a clean no-op (no layer surgery to undo).
///
/// NB the layer trick reaches into the private text-field layer tree, so the
/// iOS-version branch in `attach(to:)` is the part to verify on a device. It is
/// fail-open: if the secure canvas isn't found, content renders normally (just
/// unprotected) and nothing breaks.
@MainActor
final class ScreenSecurity: ObservableObject {
    static let shared = ScreenSecurity()

    static let defaultsKey = "rcq.privacy.screenSecurity"

    /// True while the screen is being recorded or mirrored (AirPlay / cable).
    @Published private(set) var isCaptured = UIScreen.main.isCaptured

    private let secureField = UITextField()
    private weak var attachedWindow: UIWindow?
    /// Original parent of `window.layer` before we reparent it under the secure
    /// canvas, so disabling can put it back exactly where it was.
    private weak var originalSuperlayer: CALayer?
    /// True only while the window's layer is actually hosted in the secure
    /// canvas. Gates the (reversible) layer surgery so the default-OFF path
    /// never touches the layer tree.
    private var protectionActive = false

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    private init() {
        secureField.isUserInteractionEnabled = false
        secureField.translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isCaptured = UIScreen.main.isCaptured }
        }
    }

    /// Persist the toggle and (re)apply protection to the live window.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        objectWillChange.send()
        refresh()
    }

    /// Re-apply current state to the key window. Safe to call repeatedly (idle
    /// when nothing changed); call it on launch and whenever a scene goes active
    /// so a freshly-created window inherits the setting.
    func refresh() {
        guard let window = Self.keyWindow else { return }
        if window !== attachedWindow {
            // Undo any protection on the old window before re-homing.
            if protectionActive { deactivateProtection() }
            attach(to: window)
        }
        applyProtection()
    }

    // MARK: - Secure-field layer trick

    /// Add the (invisible, non-interactive) secure field to the window. This is
    /// harmless on its own — NO layer surgery happens here, so an attached-but-
    /// disabled window renders completely normally.
    private func attach(to window: UIWindow) {
        secureField.removeFromSuperview()
        window.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            secureField.centerYAnchor.constraint(equalTo: window.centerYAnchor),
        ])
        attachedWindow = window
        protectionActive = false
    }

    /// Reconcile the live layer tree with [enabled]. The layer surgery (hosting
    /// the window's own layer inside the secure canvas so the whole rendered tree
    /// inherits the no-capture flag) ONLY runs while enabled, and is fully undone
    /// when disabled — so the default-OFF state never reparents anything.
    private func applyProtection() {
        let on = enabled
        secureField.isSecureTextEntry = on
        if on {
            activateProtection()
        } else {
            deactivateProtection()
        }
    }

    private func activateProtection() {
        guard !protectionActive, let window = attachedWindow else { return }
        // If the window's layer is top-level (no host), reparenting it under our
        // own sublayer would form a cycle — skip and leave the screen unprotected
        // rather than risk a broken window. Fail-open.
        guard let superlayer = window.layer.superlayer else { return }
        guard let canvas = secureField.layer.sublayers?.last else { return }
        originalSuperlayer = superlayer
        superlayer.addSublayer(secureField.layer)
        canvas.addSublayer(window.layer)
        protectionActive = true
    }

    private func deactivateProtection() {
        guard protectionActive else { return }
        // Put the window's layer back under its original host, then drop our
        // lifted secure-field layer.
        if let window = attachedWindow, let orig = originalSuperlayer {
            orig.addSublayer(window.layer)
        }
        secureField.layer.removeFromSuperlayer()
        protectionActive = false
    }

    // MARK: - Helpers

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
    }
}
