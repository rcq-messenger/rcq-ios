import SwiftUI
import UIKit
import UserNotifications

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
            await MessageService.shared.fetchOfflineQueue()
        }
        completionHandler([.banner, .sound, .badge, .list])
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
            case .trades:
                AppState.shared.pendingOpenTrades = true
            case .none:
                break
            }
            completionHandler()
        }
    }

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
        // Eager-touch so PushKit + LanguageManager (App Group mirror) are
        // initialised before any push reaches the NSE.
        _ = VoIPPushService.shared
        _ = CallProvider.shared
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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("rcq.onboarded") private var didOnboard: Bool = false

    var body: some View {
        // Root ZStack hosts game mini-bubbles so they persist across nav.
        ZStack {
            mainContent
            GameMinisOverlayHost()
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhase(newPhase)
        }
    }

    /// Force-reconnect WS on foreground; iOS suspended URLSession may leave
    /// `isConnected == true` long after the socket goes silent.
    private func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active, appState.booted else { return }
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
        Task { @MainActor in
            let baseURL = APIClient.shared.baseURL
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
