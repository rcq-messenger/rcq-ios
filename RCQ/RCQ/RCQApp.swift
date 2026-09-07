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
    private static let threshold: Double = 2.5
    private static let cooldown: TimeInterval = 1.0

    /// Sample delivery queue. Serial (`maxConcurrentOperationCount = 1`), which
    /// is what makes the cooldown state below safe without a lock.
    ///
    /// Samples used to be delivered to `.main` twenty times a second, for the
    /// whole life of the process, so the main thread woke up to compute a
    /// square root and compare two dates while the user was reading a chat.
    /// The only thing that has to happen on the main thread is the
    /// notification, and that happens on the ~never that a shake lands.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "app.rcq.shake"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    /// Cooldown state, off the main actor: touched only from `queue`, which is
    /// serial, so the class is safe to hand to CoreMotion.
    private final class Cooldown: @unchecked Sendable {
        private var lastFired: Date = .distantPast
        func shouldFire(at now: Date, after interval: TimeInterval) -> Bool {
            guard now.timeIntervalSince(lastFired) > interval else { return false }
            lastFired = now
            return true
        }
    }
    private let cooldown = Cooldown()

    /// Called from `RootView.task`, not from `RCQApp.init`: starting the
    /// accelerometer is not needed to paint anything, and on a VoIP-push
    /// background launch there is no UI to shake at all.
    func start() {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1.0 / 20.0  // 20 Hz — plenty for shake detection
        manager.startAccelerometerUpdates(to: queue) { [cooldown] data, _ in
            guard let d = data else { return }
            let m = sqrt(d.acceleration.x * d.acceleration.x
                       + d.acceleration.y * d.acceleration.y
                       + d.acceleration.z * d.acceleration.z)
            guard m > Self.threshold else { return }
            guard cooldown.shouldFire(at: Date(), after: Self.cooldown) else { return }
            // Observers are SwiftUI views (`RootView.onReceive`), so the post
            // has to land on the main thread, and CoreMotion no longer
            // delivers us there.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .rcqDeviceShook, object: nil)
            }
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
            // Empty content = NSE-suppressed (removed/muted) — no banner/sound.
            if notification.request.content.body.isEmpty {
                completionHandler([])
                return
            }
            // In the foreground a MESSAGE push is redundant: the same
            // envelope was just drained by fetchOfflineQueue above and is
            // surfaced by the in-app MessageBannerService, so a system
            // banner doubles up. This is the "a push pops over the chat
            // I'm already looking at" complaint, worst in busy groups
            // where a recipient who briefly looks offline (WS reconnect
            // churn) still gets pushed. Keep badge + notification-center
            // entry, drop the banner + sound. Non-message pushes
            // (contact requests, trades, outbid: no `env`) have no in-app
            // equivalent, so they still present normally.
            let isMessagePush = notification.request.content.userInfo["env"] != nil
            if isMessagePush {
                completionHandler([.badge, .list])
                return
            }
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
            case .group(let gid):
                AppState.shared.pendingOpenGroupID = gid
            case .pending:
                AppState.shared.pendingOpenPending = true
            case .reports:
                AppState.shared.pendingOpenReports = true
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
        case group(Int)
        case pending
        /// An answer to a report the user filed (`thread_id: "reports"`,
        /// `notif_kind: "report_reply"`). The push deliberately carries no part
        /// of the answer — it traverses APNs in the clear — so the tap only
        /// opens the screen that fetches the text over our own session.
        case reports
    }

    /// The backend sets `thread_id` on every message push: "peer-<uin>" for a
    /// 1:1, "group-<id>" for a group, "pending" for a contact request (see
    /// services/apns.py). The group case was missing here, so tapping a
    /// notification about a group message opened the app on the chat list and
    /// left the user to find the group themselves. AppState already carries
    /// `pendingOpenGroupID` for the in-app deep links, so routing is only a
    /// matter of parsing the id out.
    private static func parsePushTarget(fromThreadID threadID: String) -> PushTarget? {
        if threadID == "pending" { return .pending }
        if threadID == "reports" { return .reports }
        let peerPrefix = "peer-"
        if threadID.hasPrefix(peerPrefix), let uin = Int(threadID.dropFirst(peerPrefix.count)) {
            return .peer(uin)
        }
        let groupPrefix = "group-"
        if threadID.hasPrefix(groupPrefix), let gid = Int(threadID.dropFirst(groupPrefix.count)) {
            return .group(gid)
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
        // The hosts the trust rule never pins (docs/island-fingerprint-design.md
        // §1): the flagship and the fronts, on top of the `rcq.app` suffix rule
        // inside IslandTrust. A closure read at each decision, so a signed
        // config that moves the front takes effect without a relaunch.
        IslandTrust.caOnlyHostsProvider = {
            [APIClient.prodBaseURL, APIClient.builtInProxyURL, APIClient.proxyURL]
        }
        // The history container starts opening NOW, on a detached thread, so
        // it is ready before anything on the main actor first-touches
        // `MessageDB.shared`. The race this closes is not theoretical: with
        // no PIN, the first touch is whatever envelope the socket delivers
        // first (~2s in), and losing the race put the synchronous SQLite
        // open - plus, once per schema change, the whole index migration
        // over the full history - on the main actor, which on a large
        // account was the founder's hard 3-5s freeze right after entry.
        // The `.task` prewarms on RootView/PINLockView stay as backstops;
        // this one simply starts seconds earlier.
        Task.detached(priority: .userInitiated) { await MessageDB.prewarm() }
        // The stall gauge: any main-thread freeze over half a second becomes
        // a log line with a duration, on every install, so the next "фризит"
        // report arrives with a number instead of a feeling.
        MainThreadWatchdog.start()
        // Eager-touch so PushKit + LanguageManager (App Group mirror) are
        // initialised before any push reaches the NSE.
        //
        // ⚠ VoIPPushService STAYS here and must not move to a `.task` on a
        // view. A VoIP push launches the process into the BACKGROUND, where no
        // scene is connected and no SwiftUI body ever runs. PushKit would
        // never get a registry, the push would never be delivered, and the call
        // would never ring. `PKPushRegistry` costs a delegate assignment.
        //
        // CallProvider is NOT touched here any more: it built a CXProvider
        // before the first frame so that two `RTCAudioSession` booleans would
        // be set, and those moved to `CallAudio.prepareForWebRTC()`. The
        // provider is now built by whoever first reports a call, including
        // synchronously inside the PushKit delivery handler.
        _ = VoIPPushService.shared
        _ = LanguageManager.shared
        #if DEBUG
        // R2: the PIN vault's slot payload is a fixed-size box. Fail loudly in
        // development the moment a newly added field pushes the worst-case JSON
        // past it, instead of shipping a build where setting a decoy PIN throws
        // payloadTooLarge on someone's phone.
        assert(PINVault.maximumPayloadJSONSize() != nil,
               "PIN vault slot payload no longer fits at maximum field lengths")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(themeManager)
                .preferredColorScheme(themeManager.theme.colorScheme)
                .modifier(AppTextSizeModifier(size: themeManager.textSize))
                .tint(Theme.Color.accent)
                .onOpenURL { url in appState.handle(deepLink: url) }
                // In-app browser: any http(s) link tapped inside the app
                // opens over the app in SFSafariViewController; rcq deep
                // links keep routing into AppState (see InAppBrowser).
                .environment(\.openURL, OpenURLAction { url in InAppBrowser.open(url) })
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
            // Cover the UI for: a configured panic-PIN going to background, OR —
            // only while a SECURE chat is on screen — backgrounding (app-switcher
            // snapshot) or screen recording/mirroring (belt-and-suspenders over
            // the secure-field layer trick). Screen-secure is per-conversation
            // now, so nothing covers outside a secure chat.
            if (panicPIN.isConfigured && scenePhase != .active)
                || (screenSecurity.protectsLiveContent && (scenePhase != .active || screenSecurity.isCaptured)) {
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
        // Launch work that nothing on screen depends on. A `.task` on the root
        // runs after the first frame is on its way, and only when there is a
        // scene at all, which is the point: a VoIP-push background launch has
        // no use for the accelerometer.
        .task {
            // Posts `.rcqDeviceShook` when the device crosses the shake
            // threshold; consumed below for Bug Bounty.
            ShakeMotionDetector.shared.start()
            // Opens the six cue files on a utility queue. Used to happen in
            // `SoundService.init`, which `ContactListView` triggers, i.e. on the
            // main thread immediately before the first painted list.
            SoundService.shared.prewarm()
            // Same idea for the history store: without a PIN nothing else
            // opens it ahead of the first message, and the open belongs on a
            // background thread either way. No-op once the singleton exists.
            await MessageDB.prewarm()
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
           Date().timeIntervalSince(since) >= TimeInterval(panicPIN.lockTimeout) {
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
        guard appState.booted, appState.networkReady, !panicPIN.isLocked, !panicPIN.isDecoy else { return }
        // Clear the Notification Center tray now the user is back in the app —
        // delivered banners used to linger until manually swiped (#10). Badge is
        // synced separately above.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
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
        // The strips are hosted once, on the NavigationStack inside
        // ContactListView, so every screen pushed into it inherits the inset.
        // Not here: the two covers below are the call and the room themselves,
        // and neither wants a strip pointing at what is already full screen.
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

    // Display state for the progress bar. `milestone` mirrors the last
    // published `bootProgress`; `base` is where the DISPLAYED value stood when
    // it changed, so the bar glides to the new milestone instead of
    // teleporting; between milestones the display creeps toward (next
    // milestone - 0.02) so a long stage (tunnel engage can sit 3-15s, the
    // identity check and the roster fetch are whole round trips) does not
    // look frozen. Display only: the honest value stays in AppState.
    @State private var milestone: Double = 0
    @State private var base: Double = 0
    @State private var milestoneAt: Date = Date()

    /// The ladder `doBoot` advances through; the creep aims just short of the
    /// next rung. Sorted ascending, matched to AppState's `advanceBoot` calls.
    private static let milestones: [Double] = [0.05, 0.15, 0.40, 0.60, 0.70, 0.75, 0.80, 0.95, 1.0]
    /// Glide-to-milestone time on a published change.
    private static let jumpSeconds: Double = 0.3
    /// Linear creep time from a milestone to just short of the next.
    private static let creepSeconds: Double = 15.0
    private static let barWidth: CGFloat = 180
    private static let barHeight: CGFloat = 6

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
        case .stealthActive:   return "shield.fill"
        }
    }

    /// What the bar shows at `date`: a short glide from `base` to `milestone`,
    /// then a slow linear creep toward the next rung minus 0.02. A pure
    /// function of time so TimelineView renders the interpolated percent too;
    /// a `withAnimation` on the fill width alone would leave the label
    /// snapping between milestones.
    private func displayedFraction(at date: Date) -> Double {
        let t = date.timeIntervalSince(milestoneAt)
        if t < Self.jumpSeconds {
            return base + (milestone - base) * max(0, t / Self.jumpSeconds)
        }
        let next = Self.milestones.first { $0 > milestone + 0.001 } ?? milestone
        let ceiling = max(milestone, next - 0.02)
        let creep = min(1, (t - Self.jumpSeconds) / Self.creepSeconds)
        return milestone + (ceiling - milestone) * creep
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
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let fraction = displayedFraction(at: ctx.date)
                    VStack(spacing: 8) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Color.bgSecondary)
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Theme.Color.accentPressed, Theme.Color.accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: max(Self.barHeight, Self.barWidth * fraction))
                        }
                        .frame(width: Self.barWidth, height: Self.barHeight)
                        // Bare number + percent sign on purpose: no
                        // Localizable key, in any of the seven locales.
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
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
            milestone = appState.bootProgress
            base = appState.bootProgress
            milestoneAt = Date()
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: appState.bootProgress) { newValue in
            // Glide from wherever the display currently is; a value BELOW it
            // is a fresh boot's reset and glides down the same way.
            base = displayedFraction(at: Date())
            milestone = newValue
            milestoneAt = Date()
        }
    }
}

private struct ErrorScreen: View {
    let message: String
    @State private var nextAttemptIn: Int = 5
    @State private var invite: String = ""

    /// ⚠ A CLOSED ISLAND REFUSES WITH A CODE, NOT A SENTENCE. The island
    /// answers registration with `{"code": "invite_required"}`, and this screen
    /// showed the raw text to somebody who has been handed a code in words and
    /// had nowhere on the phone to type it. The field appears ON the refusal
    /// rather than up front, so an open island never asks for a code it does
    /// not want.
    private var needsInvite: Bool { message.contains("invite_required") }
    private var badInvite: Bool { message.contains("invite_invalid") }
    private var asking: Bool { needsInvite || badInvite }

    private var humanMessage: String {
        if needsInvite { return "reg.invite.required".localized }
        if badInvite { return "reg.invite.invalid".localized }
        return message
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 12) {
                LogoMark(size: 72).opacity(0.6)
                Text("boot.error.title".localized).font(.title3.bold()).foregroundColor(Theme.Color.textPrimary)
                Text(humanMessage).font(.caption).foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                if asking {
                    TextField("reg.invite.label".localized, text: $invite)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 32)
                    Button("boot.error.retry_now".localized) {
                        let code = invite.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !code.isEmpty else { return }
                        // The same stash the deep-link join uses, consumed once
                        // by AuthService.register on the next boot.
                        UserDefaults.standard.set(code, forKey: AppState.pendingServerInviteKey)
                        Task { await AppState.shared.boot() }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.Color.accent)
                    .disabled(invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text("boot.error.retrying".localized(nextAttemptIn)).font(.caption2).foregroundColor(Theme.Color.textSecondary)
                    Button("boot.error.retry_now".localized) {
                        Task { await AppState.shared.boot() }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.Color.accent)
                }
            }
        }
        .task {
            // ⚠ No auto-retry while we are asking for a code: retrying every
            // five seconds against a door that wants something the person has
            // not typed yet would clear the field under their fingers.
            while !AppState.shared.booted && !asking {
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
