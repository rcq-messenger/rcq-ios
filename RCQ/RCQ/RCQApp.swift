import CoreMotion
import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted by `ShakeMotionDetector` whenever the accelerometer
    /// magnitude crosses the shake threshold. Wiring lives in
    /// `RCQApp.RootView.onReceive` for Bug Bounty.
    static let rcqDeviceShook = Notification.Name("rcq.device.shook")
}

/// Accelerometer-based shake detector. Used instead of `motionEnded`
/// + UIWindow swizzling, which crashed in TF release builds (recursive
/// swizzled-method dispatch under the App-lifecycle hosting). CoreMotion
/// is deterministic and doesn't care who owns first responder — the
/// raw accelerometer is always available while the app is foregrounded.
///
/// Threshold of 2.5 g picks up a deliberate shake while filtering
/// out walking / handing the phone over. 1-second cooldown stops a
/// continued shake gesture from spamming notifications.
@MainActor
final class ShakeMotionDetector {
    static let shared = ShakeMotionDetector()
    private let manager = CMMotionManager()
    private var lastFired: Date = .distantPast
    private static let threshold: Double = 2.5
    private static let cooldown: TimeInterval = 1.0

    func start() {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1.0 / 20.0  // 20 Hz — plenty for shake detection
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            let m = sqrt(d.acceleration.x * d.acceleration.x
                       + d.acceleration.y * d.acceleration.y
                       + d.acceleration.z * d.acceleration.z)
            guard m > Self.threshold else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastFired) > Self.cooldown else { return }
            self.lastFired = now
            NotificationCenter.default.post(name: .rcqDeviceShook, object: nil)
        }
    }

    func stop() {
        if manager.isAccelerometerActive {
            manager.stopAccelerometerUpdates()
        }
    }
}

/// UIKit adapter for APNs callbacks + notification taps that SwiftUI
/// doesn't expose. Wired via UIApplicationDelegateAdaptor.
final class RCQAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            NotificationService.shared.handle(apnsToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            NotificationService.shared.handle(apnsRegistrationError: error)
        }
    }

    /// Silent push: ~30s budget to fetch and decrypt before iOS suspends.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            NotificationService.shared.handleSilentPush(completion: completionHandler)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            let panic = PanicPINService.shared
            if panic.isLocked || panic.isDecoy {
                completionHandler([])
                return
            }
            await MessageService.shared.fetchOfflineQueue()
            completionHandler([.banner, .sound, .badge, .list])
        }
    }

    /// Tap handler. Drains the offline queue and routes to the surface
    /// whose threadIdentifier is `peer-<UIN>` / `pending` / `trades`.
    ///
    /// Multi-identity: when the push carries `to_uin` and that recipient
    /// belongs to a non-active local account, auto-switch to the owning
    /// account BEFORE routing the tap. Without this, the user taps a
    /// banner for account B, the app opens to account A's contact list,
    /// and the new message lives invisibly behind the switcher pill —
    /// they have to figure out the switch is needed and do it manually.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let threadID = response.notification.request.content.threadIdentifier
        let target = Self.parsePushTarget(fromThreadID: threadID)
        let userInfo = response.notification.request.content.userInfo
        // `to_uin` can arrive as Int (encoded by the backend's APNs
        // serializer) or String (depending on JSON roundtripping at the
        // edge). Accept both, fall through to nil if neither parses.
        let toUIN: Int? = (userInfo["to_uin"] as? Int)
            ?? (userInfo["to_uin"] as? String).flatMap { Int($0) }
        Task { @MainActor in
            if let toUIN,
               let owner = Self.findAccountOwningUIN(toUIN),
               owner != AccountManager.shared.activeAccountID {
                // switchToAccount runs the full reboot path
                // (rebootForActiveAccount → boot), which itself drains
                // the new account's offline queue. We skip the redundant
                // pre-switch fetchOfflineQueue() that would otherwise
                // pull against the OUTGOING account's storage.
                await AppState.shared.switchToAccount(owner)
            } else {
                await MessageService.shared.fetchOfflineQueue()
            }
            switch target {
            case .peer(let uin):
                AppState.shared.pendingOpenChatUIN = uin
            case .pending:
                AppState.shared.pendingOpenPending = true
            case .none:
                break
            }
            completionHandler()
        }
    }

    /// Look up which local account on this device owns a given recipient
    /// UIN. Walks the account-ids file written by AccountManager.save(),
    /// probes each candidate's per-account Keychain slot directly via
    /// `KeychainStore.string(_:forAccount:)` so the lookup has no
    /// side-effect on the active-account pointer. Returns nil if no
    /// local account claims the UIN (push for a UIN we don't have keys
    /// for — should never happen given the NSE only delivers the banner
    /// when it found the right account, but defensive nil keeps the
    /// tap handler from forcing a wrong-account switch in that case).
    private static func findAccountOwningUIN(_ uin: Int) -> UUID? {
        let target = String(uin)
        for accountID in AppGroup.readAccountIDs() {
            if KeychainStore.string(KeychainStore.Keys.uin, forAccount: accountID) == target {
                return accountID
            }
        }
        return nil
    }

    enum PushTarget {
        case peer(Int)
        case pending
    }

    private static func parsePushTarget(fromThreadID threadID: String) -> PushTarget? {
        if threadID == "pending" { return .pending }
        let prefix = "peer-"
        if threadID.hasPrefix(prefix), let uin = Int(threadID.dropFirst(prefix.count)) {
            return .peer(uin)
        }
        return nil
    }
}

@main
struct RCQApp: App {
    @UIApplicationDelegateAdaptor(RCQAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        UserDefaults.standard.removeObject(forKey: "rcq.singbox.activePort")
        // Eager-touch AccountManager FIRST so its first-launch legacy
        // migration runs before any other singleton reads identity
        // material. Pre-v0.3 installs get Account[0] minted around the
        // existing UIN + baseURL; fresh installs start with an empty
        // roster that the onboarding flow populates.
        _ = AccountManager.shared
        // Eager-touch so PushKit + LanguageManager (App Group mirror) are
        // initialised before any push reaches the NSE.
        _ = VoIPPushService.shared
        _ = CallProvider.shared
        _ = LanguageManager.shared
        // Boot the accelerometer-based shake detector. Posts
        // `.rcqDeviceShook` notifications when the device crosses the
        // shake threshold; consumed by RootView for Bug Bounty.
        ShakeMotionDetector.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(themeManager)
                .preferredColorScheme(themeManager.theme.colorScheme)
                .tint(Theme.Color.accent)
                .onOpenURL { url in appState.handle(deepLink: url) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var calls = CallService.shared
    @StateObject private var audioRooms = AudioRoomService.shared
    @StateObject private var ws = WebSocketService.shared
    @StateObject private var panicPIN = PanicPINService.shared
    @StateObject private var screenSecurity = ScreenSecurity.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("rcq.onboarded") private var didOnboard: Bool = false
    @State private var backgroundedAt: Date?

    private static let relockGrace: TimeInterval = 30

    /// How long the app must have been backgrounded before we treat the
    /// WebSocket as suspect on resume. iOS suspends the process during
    /// backgrounding and silently tears down (or half-opens) the socket;
    /// the receive loop never gets to process the failure while frozen,
    /// so `isConnected` lies (stays true) on resume. Anything past this
    /// grace forces a clean reconnect + presence refresh rather than
    /// trusting the stale boolean. Kept short so "pocket for 5s" already
    /// triggers it, but above the momentary .active↔.inactive flicker of
    /// a sheet/cover transition (which never sets .background, so
    /// backgroundedAt stays nil for those anyway).
    private static let connectionStaleGrace: TimeInterval = 4

    var body: some View {
        // Root ZStack hosts game mini-bubbles so they persist across nav.
        // The MessageBannerHost is NOT mounted here — it lives in its
        // own UIWindow via BannerWindowController so it floats above
        // .fullScreenCover and .sheet modals (inventory, roulette, audio
        // room, etc.). The previous in-ZStack mount was invisible the
        // moment a fullScreenCover came up.
        ZStack {
            mainContent
            // Cover the UI for: a configured panic-PIN going to background, OR
            // screen-security being on while backgrounded (app-switcher snapshot)
            // or while the screen is recorded/mirrored (belt-and-suspenders over
            // the secure-field layer trick).
            if (panicPIN.isConfigured && scenePhase != .active)
                || (screenSecurity.enabled && (scenePhase != .active || screenSecurity.isCaptured)) {
                privacyCover
            }
        }
        .task(id: panicPIN.lockState) {
            guard panicPIN.lockState == .unlocked else { return }
            if appState.booted {
                await appState.resumeAfterUnlock()
            } else {
                await appState.boot()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhase(newPhase)
        }
        .onChange(of: didOnboard) { onboarded in
            // Onboarding just completed. The launch boot was gated to NOT
            // register a throwaway identity on a fresh install (see boot()),
            // so mint the first account's identity now. "Get Started" already
            // added Account[0] → boot registers under it. The phrase-restore
            // path boots the recovered account itself, so it's already booted
            // by the time it flips this flag — the guard skips the re-boot.
            guard onboarded, !appState.booted else { return }
            Task { await appState.boot() }
        }
        // Shake-to-report. Wired at the root so any surface (chat,
        // inventory, game minis, settings, etc.) can summon Bug
        // Bounty by physically shaking the device. Routed through
        // BugBountyPresenter (imperative UIKit) instead of a SwiftUI
        // `.sheet` because a `.sheet` attached here is shadowed when
        // the user is inside any other modal (fullScreenCover for
        // Radio / Audio Room / Random chat, inventory sheets, etc.)
        // — the binding flipped but the sheet never appeared. Walking
        // to the top VC and presenting imperatively works regardless
        // of modal depth.
        .onReceive(NotificationCenter.default.publisher(for: .rcqDeviceShook)) { _ in
            // User opt-out lives in the Bug Bounty sheet itself as a
            // toggle, persisted to UserDefaults. Default = enabled
            // (key absent), so checking the boolean directly is fine
            // — the disable flag is opt-in.
            guard !UserDefaults.standard.bool(forKey: "rcq.shake_to_bug_disabled") else { return }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            BugBountyPresenter.present()
        }
    }

    /// Foreground transition: only forces a fresh WS if the watchdog
    /// thinks the socket is silently dead. Calling connect() blindly
    /// every time scenePhase fires .active was producing a reconnect
    /// storm — connect() cancels any in-flight task, and scenePhase
    /// can flip multiple times during a single sheet/cover transition.
    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background {
            // Track for ALL users now, not just panic-PIN configured
            // ones — the connection-staleness check below needs to know
            // how long we were suspended regardless of PIN state.
            backgroundedAt = Date()
            return
        }
        guard phase == .active else { return }

        let backgroundedFor = backgroundedAt.map { Date().timeIntervalSince($0) }

        if panicPIN.isConfigured, !panicPIN.isLocked, let since = backgroundedAt,
           Date().timeIntervalSince(since) > Self.relockGrace {
            panicPIN.lock()
        }
        backgroundedAt = nil

        // Banner-overlay window install needs the scene to be live,
        // so we defer it to the first .active phase rather than
        // didFinishLaunching. Idempotent — subsequent calls no-op.
        // Also fires before boot completes (during OnboardingView),
        // which is fine — no banners can fire pre-boot anyway.
        BannerWindowController.shared.install()

        // Wire the screen-security secure-field to the (now-live) window and
        // sync it to the current setting. Idempotent.
        ScreenSecurity.shared.refresh()

        // NSE may have bumped the unread counter while we were
        // backgrounded; mirror its current state to the app-icon
        // badge so the red dot disappears the moment the user
        // re-enters the app (and reappears if they back out again
        // with unopened chats). The reconcile-against-chat-list
        // sweep (which drops orphan slots from removed contacts /
        // left groups) runs AFTER the offline-queue drain so a
        // stranger whose contact row hasn't been upserted yet
        // doesn't get their fresh badge wiped.
        BadgeCounter.syncIcon()
        guard appState.booted, !panicPIN.isLocked, !panicPIN.isDecoy else { return }
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }

        // After a real background-suspend the socket is suspect even
        // when `isConnected` claims otherwise — the OS freezes the
        // process so the receive loop never processes the death, and the
        // 90s watchdog hasn't ticked yet. Symptom the user hits: reopen,
        // see contacts as "online" who actually went offline while we
        // were away (we never received their presence-offline over the
        // dead socket), then a send sits on the spinner because it's
        // POSTing through a wedged transport. Force a clean reconnect and
        // pull fresh presence so the stale rows correct immediately
        // instead of after the watchdog fires.
        let socketSuspect = (backgroundedFor ?? 0) > Self.connectionStaleGrace

        Task { @MainActor in
            if socketSuspect || !WebSocketService.shared.isConnected {
                let baseURL = APIClient.shared.baseURL
                // connect() tears down any existing (stale) task before
                // opening a fresh one, so no explicit disconnect needed.
                WebSocketService.shared.connect(
                    uin: uin, token: token, baseURL: baseURL,
                    serverToken: AccountManager.shared.active?.serverToken
                )
                // Re-pull contacts so presence reflects current
                // server-side state, not the snapshot frozen at suspend.
                // Bounded by the 30s resource timeout, so a wedged
                // transport surfaces rather than hanging.
                await ContactService.shared.refresh()
            } else {
                WebSocketService.shared.pingNow()
            }
            AudioRoomService.shared.restoreOnForeground()
        }
    }

    private var privacyCover: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            LogoMark(size: 96).opacity(0.5)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        Group {
            if panicPIN.isLocked {
                PINLockView()
            } else if !didOnboard {
                OnboardingView { didOnboard = true }
            } else if appState.booted {
                ContactListView()
            } else if let err = appState.bootError {
                ErrorScreen(message: err)
            } else {
                BootSplash()
            }
        }
        // Each top-level screen applies `.callMinimizedBarInset()` itself
        // because safeAreaInset doesn't pass through NavigationStack pushes.
        .fullScreenCover(isPresented: callPresented) { CallScreen() }
        .fullScreenCover(isPresented: roomPresented) {
            AudioRoomScreen(initialRoomName: audioRooms.activeRoomName ?? "audio_room.screen.fallback_name".localized)
        }
    }

    private var callPresented: Binding<Bool> {
        Binding(
            get: {
                switch calls.state {
                case .idle: return false
                case .connected: return !calls.isMinimized
                default: return true
                }
            },
            set: { _ in }
        )
    }

    private var roomPresented: Binding<Bool> {
        Binding(
            get: { audioRooms.activeRoomID != nil && !audioRooms.isMinimized },
            set: { _ in },
        )
    }
}

private struct BootSplash: View {
    @State private var pulse: Bool = false
    @ObservedObject private var appState = AppState.shared

    private var statusKey: String {
        switch appState.bootStatus {
        case .connecting:      return "boot.connecting"
        case .engagingStealth: return "boot.engaging_stealth"
        case .stealthActive:   return "boot.stealth_active"
        }
    }

    private var statusGlyph: String? {
        switch appState.bootStatus {
        case .connecting:      return nil
        case .engagingStealth: return "shield.lefthalf.filled"
        case .stealthActive:   return "eye.slash.circle.fill"
        }
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                LogoMark(size: 100, spinning: true)
                Text("RCQ")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.Color.textPrimary)
                    .tracking(4)
                HStack(spacing: 6) {
                    if let glyph = statusGlyph {
                        Image(systemName: glyph)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    Text(statusKey.localized)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                .opacity(pulse ? 1.0 : 0.4)
                .padding(.top, 4)
                .animation(.easeInOut(duration: 0.25), value: appState.bootStatus)
                Spacer()
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct ErrorScreen: View {
    let message: String
    @State private var nextAttemptIn: Int = 5

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 12) {
                LogoMark(size: 72).opacity(0.6)
                Text("Couldn't connect").font(.title3.bold()).foregroundColor(Theme.Color.textPrimary)
                Text(message).font(.caption).foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Text("Retrying in \(nextAttemptIn)s…").font(.caption2).foregroundColor(Theme.Color.textSecondary)
                Button("Retry now") {
                    Task { await AppState.shared.boot() }
                }
                .buttonStyle(.borderedProminent).tint(Theme.Color.accent)
            }
        }
        .task {
            while !AppState.shared.booted {
                for s in stride(from: 5, through: 1, by: -1) {
                    nextAttemptIn = s
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if AppState.shared.booted { return }
                }
                await AppState.shared.boot()
            }
        }
    }
}

private struct LogoMark: View {
    var size: CGFloat = 96
    var spinning: Bool = false

    @State private var angle: Double = 0

    var body: some View {
        Group {
            if UIImage(named: "Logo") != nil {
                Image("Logo").resizable().scaledToFit()
            } else {
                Image(systemName: "message.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundColor(Theme.Color.accent)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .onAppear {
            guard spinning else { return }
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}
