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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let threadID = response.notification.request.content.threadIdentifier
        let target = Self.parsePushTarget(fromThreadID: threadID)
        Task { @MainActor in
            await MessageService.shared.fetchOfflineQueue()
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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("rcq.onboarded") private var didOnboard: Bool = false
    @State private var backgroundedAt: Date?

    private static let relockGrace: TimeInterval = 30

    var body: some View {
        // Root ZStack hosts game mini-bubbles so they persist across nav.
        // The MessageBannerHost is NOT mounted here — it lives in its
        // own UIWindow via BannerWindowController so it floats above
        // .fullScreenCover and .sheet modals (inventory, roulette, audio
        // room, etc.). The previous in-ZStack mount was invisible the
        // moment a fullScreenCover came up.
        ZStack {
            mainContent
            if panicPIN.isConfigured && scenePhase != .active {
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
            if panicPIN.isConfigured { backgroundedAt = Date() }
            return
        }
        guard phase == .active else { return }

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
        Task { @MainActor in
            if !WebSocketService.shared.isConnected {
                let baseURL = APIClient.shared.baseURL
                WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL)
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
