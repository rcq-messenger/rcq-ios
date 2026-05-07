import SwiftUI
import UIKit
import UserNotifications

/// SwiftUI doesn't expose APNs callbacks directly, so we adapt a UIKit
/// `UIApplicationDelegate` and forward the relevant calls to
/// `NotificationService`. The adapter is wired via `UIApplicationDelegateAdaptor`
/// so iOS still treats RCQApp as the lifecycle root.
///
/// Also acts as the `UNUserNotificationCenterDelegate` so taps on a
/// push notification land back here. Without this delegate, tapping a
/// push opens the app to whatever screen it was last on instead of
/// jumping to the originating chat — and the offline queue may still
/// be sitting on the server because the app never explicitly drained
/// it from a background launch.
final class RCQAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Install ourselves as the UN delegate as early as possible so
        // a notification tap that launched the app finds us ready when
        // iOS re-delivers it via `didReceive`.
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

    /// Silent push entry point — Apple wakes us with `content-available: 1`
    /// when a sealed envelope is queued for us. We have ~30s to fetch and
    /// decrypt before iOS suspends again.
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

    /// Foreground delivery — iOS asks us whether to surface the
    /// notification while the app is on screen. We say yes on banners
    /// and sound (the user already opted into notifications, no reason
    /// to swallow them just because the app happens to be open) and
    /// also drain the queue so the chat is up-to-date when the user
    /// switches to it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            await MessageService.shared.fetchOfflineQueue()
        }
        completionHandler([.banner, .sound, .badge, .list])
    }

    /// Tap handler. iOS delivers the response after the user picks an
    /// action on the notification — for our app the only action is the
    /// default "tapped the body". We:
    ///   1. Drain the offline queue so the chat shows the message
    ///      that triggered the push (covers the case where the push
    ///      raced ahead of the WS / boot's own drain).
    ///   2. Pull the originating UIN out of `threadIdentifier` (the
    ///      NSE sets it to `peer-<senderUIN>`) and ask AppState to
    ///      route to that chat.
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
            case .trades:
                AppState.shared.pendingOpenTrades = true
            case .none:
                break
            }
            completionHandler()
        }
    }

    /// What surface a tapped push should route to. Mirrors the
    /// backend's `thread_id` convention in `apns.send_to_user`:
    ///   `peer-<UIN>` → 1:1 chat
    ///   `pending`    → pending contact requests
    ///   `trades`     → trades list
    /// nil = no recognised target; `didReceive` just drains the
    /// offline queue and leaves the user wherever they landed.
    enum PushTarget {
        case peer(Int)
        case pending
        case trades
    }

    private static func parsePushTarget(fromThreadID threadID: String) -> PushTarget? {
        if threadID == "pending" { return .pending }
        if threadID == "trades" { return .trades }
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
        // Touch the singletons so PushKit's PKPushRegistry installs its
        // delegate before the app finishes launching. Without this, an
        // incoming VoIP push at cold-start would arrive before our
        // delegate is set, and iOS would drop the call.
        _ = VoIPPushService.shared
        _ = CallProvider.shared
        // Force LanguageManager init at launch so the App Group language
        // mirror file is written *before* any push lands at the NSE.
        // Without this the mirror only runs lazily — first SwiftUI view
        // that pulls a localized string — and a push that arrives during
        // a cold launch (or before the user ever opened the picker) would
        // make the NSE fall back to the system locale.
        _ = LanguageManager.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(themeManager)
                .preferredColorScheme(themeManager.theme.colorScheme)
                .tint(Theme.Color.accent)
                .task { await appState.boot() }
                .onOpenURL { url in appState.handle(deepLink: url) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var calls = CallService.shared
    @StateObject private var audioRooms = AudioRoomService.shared
    @StateObject private var ws = WebSocketService.shared
    /// Foreground/background tracking. When the app comes back to
    /// `.active` from background, iOS may have suspended our
    /// `URLSessionWebSocketTask` — the receive loop only notices on
    /// the next read attempt, which can take 10+ seconds, leaving
    /// the WS in a stale-but-marked-connected state. During that
    /// window HTTP requests still work but server-pushed events
    /// (crash phase changes, auction bid updates, message arrivals)
    /// silently disappear. Force-reconnecting on `.active` restores
    /// the live event stream within ~1s.
    @Environment(\.scenePhase) private var scenePhase
    /// First-launch onboarding flag. Lives in UserDefaults so it
    /// survives a burn-and-re-register cycle on the same device —
    /// returning users on the same iPhone don't get walked through
    /// the tour twice. Deleting the app clears UserDefaults
    /// naturally, which is the right behaviour (truly fresh
    /// install ⇒ tour again).
    @AppStorage("rcq.onboarded") private var didOnboard: Bool = false

    var body: some View {
        // Outer ZStack hosts the floating game mini-bubbles
        // (Crash + Auction) at root level so they persist across
        // every NavigationStack push, tab swap, and chat open.
        // `allowsHitTesting(false)` on `GameMinisOverlayHost` is
        // implicit via the empty ZStack — only the bubble's own
        // content rect is hittable, so taps elsewhere fall through
        // to the underlying nav stack.
        ZStack {
            mainContent
            GameMinisOverlayHost()
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhase(newPhase)
        }
    }

    /// Force-reconnect the WS when the app comes back to the
    /// foreground. iOS pauses URLSession network tasks while
    /// suspended, and the WS receive loop's error handler only
    /// fires on the next failed read — meanwhile `isConnected`
    /// stays true, server-pushed events stop arriving, and the
    /// user sees their bet/bid not registering, contacts not
    /// updating, etc. Forcing a reconnect on `.active` closes
    /// the lap.
    private func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active, appState.booted else { return }
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
        Task { @MainActor in
            let baseURL = APIClient.shared.baseURL
            // `connect()` is idempotent — disconnects any in-flight
            // task before opening a fresh one. Brief blip on a
            // healthy connection is preferable to staying on a
            // silently-dead one.
            WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        Group {
            if !didOnboard {
                OnboardingView { didOnboard = true }
            } else if appState.booted {
                ContactListView()
            } else if let err = appState.bootError {
                ErrorScreen(message: err)
            } else {
                BootSplash()
            }
        }
        // The call bar is NOT hosted here — `safeAreaInset` on a
        // view that contains a `NavigationStack` does not pass
        // through to push'd destinations, so a chat opened from
        // the contact list would end up with the bar drawn over
        // its own header. Each top-level screen applies
        // `.callMinimizedBarInset()` on its own root.
        //
        // The system status bar (wifi/clock/battery) used to be
        // hidden while the call bar was up, on the theory that
        // stacking it with the green strip looked busy — turns
        // out it doesn't, the icons are unobtrusive, and hiding
        // them caused the chat header to jump up by ~20pt the
        // moment a call minimized. Leaving them visible keeps
        // the layout stable.
        // Full-screen call surface. Hosts outgoing-ringing, incoming-
        // ringing, connected, and post-end overlay states. Suppressed
        // when the user minimized a connected call — they can browse
        // chats freely while the call keeps streaming. Tapping the
        // floating strip restores this fullScreenCover.
        .fullScreenCover(isPresented: callPresented) { CallScreen() }
        // Audio Rooms full-screen surface. Lives at root for the same
        // reasons as CallScreen — minimised pill needs to coexist with
        // any chat the user pushes onto the navigation stack while
        // they're in the room.
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
                default: return true  // ringing + ended always full-screen
                }
            },
            set: { _ in /* dismissal handled by CallService.state transitions */ }
        )
    }

    private var roomPresented: Binding<Bool> {
        Binding(
            get: { audioRooms.activeRoomID != nil && !audioRooms.isMinimized },
            set: { _ in /* dismissal handled via AudioRoomService */ },
        )
    }
}

private struct BootSplash: View {
    /// Drives a subtle opacity pulse on the "connecting" line so
    /// the screen has a second beat of motion alongside the
    /// rotating logo, without changing layout (any text-width
    /// change at this size jitters because of `.tracking`). Pulses
    /// 0.4 → 1.0 → 0.4 every ~1.6s.
    @State private var pulse: Bool = false

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
                Text("boot.connecting".localized)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.Color.textSecondary)
                    .opacity(pulse ? 1.0 : 0.4)
                    .padding(.top, 4)
                Spacer()
            }
        }
        .onAppear {
            // Single continuous opacity oscillation. `autoreverses`
            // glides back to the start value smoothly — no abrupt
            // text-snap.
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
            // Auto-retry loop. Backend may have just been started after the app — try
            // again every few seconds until boot succeeds (AppState flips `booted`,
            // which removes this view) or the user taps Retry now.
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
    /// Drives a continuous slow 360° rotation. BootSplash turns it
    /// on so the "connecting…" screen has visible motion alongside
    /// the system spinner; ErrorScreen leaves it off because a
    /// happily-idling logo on top of a "Couldn't connect" message
    /// reads as wrong tone.
    var spinning: Bool = false

    @State private var angle: Double = 0

    var body: some View {
        Group {
            if UIImage(named: "Logo") != nil {
                Image("Logo").resizable().scaledToFit()
            } else {
                // Fallback if the asset hasn't been imported yet.
                Image(systemName: "message.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundColor(Theme.Color.accent)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .onAppear {
            guard spinning else { return }
            // 30s per revolution → slow / contemplative pace.
            // `.repeatForever(autoreverses: false)` glues each
            // revolution's tail to the next head with no visible
            // reset jolt.
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}
