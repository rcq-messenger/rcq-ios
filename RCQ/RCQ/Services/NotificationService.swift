import Foundation
import UIKit
import UserNotifications

/// `UNUserNotificationCenter` wrapper. Owns auth prompt, APNs token
/// registration + upload to backend, and surfacing local notifications
/// when the app is backgrounded.
///
/// Sealed-sender push: backend body carries NO sender info. App wakes,
/// drains `/messages/queue`, decrypts locally, posts a local notification.
@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    private(set) var authorized: Bool = false
    private(set) var deviceToken: String?
    private static let lastSentTokenKey = "rcq.apns.lastSentToken"
    /// Force a re-upload after this stale window — guards against the
    /// backend losing the row (DB wipe, sandbox→prod env flip pruning
    /// stale tokens) where a pure hex+UIN cache would never re-sync.
    private static let lastSentAtKey = "rcq.apns.lastSentAt"
    private static let lastSentMaxAgeSec: TimeInterval = 12 * 60 * 60

    private init() {}

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            authorized = false
            return
        }
        if authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Server upserts on (uin, token). No-op when UIN unknown.
    func handle(apnsToken raw: Data) {
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await self.submitTokenIfNeeded(force: false) }
    }

    func handle(apnsRegistrationError: Error) {
        print("[NotificationService] APNs registration failed: \(apnsRegistrationError)")
    }

    /// Apple gives us ~30s. Drains queue → MessageService.ingest →
    /// AppState → presentIfBackgrounded.
    func handleSilentPush(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            await MessageService.shared.fetchOfflineQueue()
            completion(.newData)
        }
    }

    private func submitTokenIfNeeded(force: Bool = false) async {
        guard let token = deviceToken else { return }
        guard let uin = AuthService.shared.ownUIN else {
            // Re-submit happens from AppState.boot once auth completes.
            return
        }
        // Cache key bundles UIN with token: after a re-register the UIN
        // changes but the APNs token doesn't, and a token-only cache
        // would strand the token under the old UIN on the server.
        let cacheKey = "\(uin):\(token)"
        let now = Date().timeIntervalSince1970
        let lastSentAt = UserDefaults.standard.double(forKey: Self.lastSentAtKey)
        let aged = now - lastSentAt > Self.lastSentMaxAgeSec
        if !force && !aged && UserDefaults.standard.string(forKey: Self.lastSentTokenKey) == cacheKey {
            return
        }
        struct Body: Encodable { let token: String; let platform: String; let device_id: String }
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST", "/users/me/push-token",
                body: Body(token: token, platform: "ios", device_id: KeychainStore.deviceID())
            )
            UserDefaults.standard.set(cacheKey, forKey: Self.lastSentTokenKey)
            UserDefaults.standard.set(now, forKey: Self.lastSentAtKey)
        } catch {
            // Transient — try again on next boot.
        }
    }

    /// `force=true` bypasses the cache so the backend re-receives the
    /// token even when it looks unchanged — covers server-side row loss.
    func refreshTokenSubmission() async {
        await submitTokenIfNeeded(force: true)
    }

    /// No-op when foreground (user already sees the message on screen).
    func presentIfBackgrounded(title: String, body: String, threadKey: String) {
        guard authorized else { return }
        let appState = UIApplication.shared.applicationState
        guard appState != .active else { return }

        // Bump the app-icon badge counter. This path fires when the app
        // got the message via WebSocket (still alive but backgrounded)
        // without a corresponding APNs push — so NSE didn't increment.
        let total = BadgeCounter.increment(threadKey: threadKey)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = threadKey
        content.sound = .default
        content.badge = NSNumber(value: total)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // fire immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Burn-account hook — clears the last-sent-token sentinel so the
    /// next registration re-uploads to the new account.
    func wipe() {
        UserDefaults.standard.removeObject(forKey: Self.lastSentTokenKey)
        deviceToken = nil
    }
}
