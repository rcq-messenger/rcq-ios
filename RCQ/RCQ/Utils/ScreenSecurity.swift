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

// MARK: - Screenshot / recording blanking (contained secure-field canvas)

/// A UITextField whose `isSecureTextEntry` canvas iOS renders BLANK during a
/// screenshot or screen recording. We host SwiftUI content inside that canvas
/// so the wrapped content is blanked on capture — WITHOUT ever touching
/// `window.layer` (the prior approach that crashed, see `ScreenSecurity` doc).
///
/// Never becomes first responder, so it can't pop a keyboard or grab the
/// caret; it stays interactive only so touches pass through to the hosted
/// content (scrolling must keep working while protected).
private final class SecureCanvasField: UITextField {
    override var canBecomeFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    // No edit affordances — this field never holds text or a cursor.
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}

/// Wraps SwiftUI content so it renders blank in screenshots / recordings while
/// `isProtected` is true. Fail-open: if the private secure canvas can't be
/// resolved (future iOS), the content is hosted normally (visible, unprotected)
/// — the chat never goes blank or crashes.
///
/// ⚠️ Uses private-API-adjacent secure-field internals and is UNVERIFIED on a
/// real device from the build host (the simulator can't build vendored
/// libsignal, and capture-blanking is a capture-time behavior). TestFlight must
/// confirm: (1) no crash entering a secure chat, (2) the message area is blank
/// in a screenshot / recording, (3) scrolling still works while protected.
struct SecureCanvasView<Content: View>: UIViewControllerRepresentable {
    let isProtected: Bool
    let content: Content

    init(isProtected: Bool, @ViewBuilder content: () -> Content) {
        self.isProtected = isProtected
        self.content = content()
    }

    func makeUIViewController(context: Context) -> SecureCanvasController<Content> {
        SecureCanvasController(rootView: content, isProtected: isProtected)
    }

    func updateUIViewController(_ controller: SecureCanvasController<Content>, context: Context) {
        controller.update(rootView: content, isProtected: isProtected)
    }
}

final class SecureCanvasController<Content: View>: UIViewController {
    private let secureField = SecureCanvasField()
    private let hosting: UIHostingController<Content>
    private var isProtected: Bool

    init(rootView: Content, isProtected: Bool) {
        self.hosting = UIHostingController(rootView: rootView)
        self.isProtected = isProtected
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // Interactive (so the canvas subtree forwards touches → scrolling
        // keeps working) but never first responder (SecureCanvasField).
        secureField.isSecureTextEntry = true
        secureField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.topAnchor.constraint(equalTo: view.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            secureField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.didMove(toParent: self)
        // Placement deferred to layout — the secure canvas subview doesn't
        // exist until the field has laid out.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        placeContent()
    }

    func update(rootView: Content, isProtected: Bool) {
        hosting.rootView = rootView
        if self.isProtected != isProtected {
            self.isProtected = isProtected
            placeContent()
        }
    }

    /// The secure canvas view iOS blanks on capture — the secure field's own
    /// content layer host. nil on an iOS where the internal shape changed.
    private var secureCanvas: UIView? { secureField.subviews.first }

    private func placeContent() {
        let target: UIView = (isProtected ? secureCanvas : nil) ?? view
        guard hosting.view.superview !== target else { return }
        hosting.view.removeFromSuperview()
        target.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: target.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: target.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: target.trailingAnchor),
        ])
    }
}
