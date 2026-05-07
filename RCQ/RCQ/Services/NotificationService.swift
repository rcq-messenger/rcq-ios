import Foundation
import UIKit
import UserNotifications

/// Light wrapper around `UNUserNotificationCenter`. Owns three things:
///   1. Local notification authorisation prompt (`.alert .badge .sound`).
///   2. APNs registration — request a device token from Apple, hand it to
///      the backend so it can wake us via silent push when offline mail
///      lands. The backend's push body deliberately carries NO sender info
///      (sealed-sender) — we wake, fetch `/messages/queue`, decrypt
///      locally, and post a regular local notification with the real
///      sender attached.
///   3. Surfacing of those local notifications when the app is in the
///      background but not yet suspended.
///
/// This matches the v1 sealed-sender push pattern used by Signal,
/// short of a Notification Service Extension. NSE remains a future
/// upgrade — bigger reliability win when iOS tightens silent-push
/// throttles, smaller win for casual closed-beta usage.
@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    private(set) var authorized: Bool = false
    /// The hex-encoded APNs token Apple last handed us. Stored locally so
    /// we can re-submit on reconnect without re-prompting the OS.
    private(set) var deviceToken: String?
    /// Persisted across launches. Last token we successfully shipped to
    /// the backend — used as one half of an idempotency check.
    private static let lastSentTokenKey = "rcq.apns.lastSentToken"
    /// Unix timestamp of the last successful upload. We force a re-upload
    /// after `lastSentMaxAgeSec` even when the token + UIN haven't
    /// changed — guards against the backend losing the row (DB wipe,
    /// migration, sandbox→prod env flip that pruned a stale token) where
    /// a pure hex+UIN cache would silently keep us out of sync forever.
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
            // Kick off APNs registration. The actual token arrives async via
            // `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
            // routed back here through `RCQAppDelegate`.
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Called by RCQAppDelegate when iOS finishes APNs registration. Sends
    /// the token to the backend (idempotently — server upserts on
    /// (uin, token)). No-op when there's nothing to compare against (first
    /// launch before we know our UIN, registration before login, etc.).
    func handle(apnsToken raw: Data) {
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await self.submitTokenIfNeeded(force: false) }
    }

    /// Called by RCQAppDelegate when iOS reports an APNs registration
    /// failure — entitlement missing, no network, throttled, etc. We just
    /// log; subsequent retries happen on the next launch via
    /// `requestAuthorization`.
    func handle(apnsRegistrationError: Error) {
        print("[NotificationService] APNs registration failed: \(apnsRegistrationError)")
    }

    /// Called by RCQAppDelegate on `didReceiveRemoteNotification`. Drains
    /// the offline queue (which decrypts envelopes and routes them through
    /// `MessageService.ingest` → AppState → local notifications via
    /// `presentIfBackgrounded`). Apple gives us ~30s to finish.
    func handleSilentPush(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            await MessageService.shared.fetchOfflineQueue()
            completion(.newData)
        }
    }

    private func submitTokenIfNeeded(force: Bool = false) async {
        guard let token = deviceToken else { return }
        guard let uin = AuthService.shared.ownUIN else {
            // Not logged in yet — token will be re-submitted from
            // AppState.boot once auth completes.
            return
        }
        // Cache key bundles UIN with token — same reasoning as
        // VoIPPushService: after a re-register the UIN changes but the
        // APNs token from Apple is unchanged, and a token-only cache
        // would skip the re-upload, stranding the token under the old
        // UIN on the server.
        let cacheKey = "\(uin):\(token)"
        let now = Date().timeIntervalSince1970
        let lastSentAt = UserDefaults.standard.double(forKey: Self.lastSentAtKey)
        let aged = now - lastSentAt > Self.lastSentMaxAgeSec
        if !force && !aged && UserDefaults.standard.string(forKey: Self.lastSentTokenKey) == cacheKey {
            return  // recently uploaded, nothing to refresh
        }
        struct Body: Encodable { let token: String; let platform: String }
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST", "/users/me/push-token",
                body: Body(token: token, platform: "ios")
            )
            UserDefaults.standard.set(cacheKey, forKey: Self.lastSentTokenKey)
            UserDefaults.standard.set(now, forKey: Self.lastSentAtKey)
        } catch {
            // Transient — try again on next boot.
        }
    }

    /// Re-trigger token submission after login completes. Boot calls this
    /// so a fresh registration picks up an APNs token that arrived BEFORE
    /// auth. `force=true` bypasses the cache so the backend re-receives the
    /// token even when it superficially looks unchanged — covers the case
    /// where the server lost its row (DB wipe, sandbox→prod env flip
    /// pruned a stale token, manual cleanup) but the client wouldn't have
    /// noticed otherwise.
    func refreshTokenSubmission() async {
        await submitTokenIfNeeded(force: true)
    }

    /// Surface an inbound message as a local notification — only when the app is
    /// not in the foreground (otherwise the user already sees it on screen).
    func presentIfBackgrounded(title: String, body: String, threadKey: String) {
        guard authorized else { return }
        let appState = UIApplication.shared.applicationState
        guard appState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = threadKey
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // fire immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Burn-account hook: clear the cached "last sent token" sentinel so
    /// the next registration re-uploads to the new account.
    func wipe() {
        UserDefaults.standard.removeObject(forKey: Self.lastSentTokenKey)
        deviceToken = nil
    }
}
