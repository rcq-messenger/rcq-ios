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
        // ⚠ A guest copy registers NO push token (spec 2026-09-15, 12.1; D6):
        // its mailbox never wakes a phone, and a token on it would hand the
        // island a device for an account that does not live there. Local
        // notifications still work, which is why the authorisation above is
        // asked for either way: a room this copy is in still has to ring.
        if authorized && !GuestSession.shared.isPrimaryGuestCopy {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Server upserts on (uin, token). No-op when UIN unknown.
    ///
    /// ⚠ force, not cache-gated. Apple fires this once per launch, so this is
    /// one idempotent POST per launch — and it is the only submit that is
    /// GUARANTEED to hold a token. The boot-order refresh in AppState races
    /// this callback: when it runs first, `deviceToken` is still nil and its
    /// force is silently wasted; the callback then hit the sent-cache with
    /// force=false and skipped. Meanwhile the server prunes a token row the
    /// moment APNs calls it dead on both hosts, and a row can also be lost to
    /// a wipe — after which THIS device had no row and no plan to ever send
    /// one again inside the 12h cache window. That is precisely "пуши вообще
    /// перестали работать" (megalist P0-2): the founder's account had zero
    /// device_tokens rows while the app believed it was registered.
    func handle(apnsToken raw: Data) {
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await self.submitTokenIfNeeded(force: true) }
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
        // D6, and re-checked here rather than only at registration: the flag can
        // flip mid-session (a refresh that says guest, a settle that says not),
        // and this is the one call that would put the token on the island.
        guard !GuestSession.shared.isPrimaryGuestCopy else { return }
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
        struct Body: Encodable {
            let token: String; let platform: String; let device_id: String
            let accounts_here: [Int]?
        }
        do {
            let _: EmptyResponse = try await APIClient.shared.request(
                "POST", "/users/me/push-token",
                body: Body(
                    token: token, platform: "ios", device_id: KeychainStore.deviceID(),
                    accounts_here: Self.accountsHere(ownUIN: uin)
                )
            )
            UserDefaults.standard.set(cacheKey, forKey: Self.lastSentTokenKey)
            UserDefaults.standard.set(now, forKey: Self.lastSentAtKey)
        } catch {
            // Transient — try again on next boot.
        }
    }

    /// Tell the island to stop waking this device for the account whose
    /// credentials are loaded right now.
    ///
    /// ⚠⚠ THE CALL NOBODY WAS MAKING. A push row is (account, token), and the
    /// token belongs to the INSTALLATION: a phone that has carried several
    /// accounts has a row per account pointing at it. When an account LEAVES
    /// the phone nothing ever removed its row, so the island went on waking the
    /// device for that account's groups — and the person could not stop it from
    /// their own account, because it was not their account doing it.
    /// Reinstalling did not help either: the row is on the server, filed under
    /// a number they no longer hold. Report #1037, open for months, from an
    /// iPhone whose token was registered under five numbers, four of them
    /// abandoned and all four in the group whose messages kept arriving.
    ///
    /// ⚠ Must run BEFORE the account's credentials are wiped: the island only
    /// takes this on that account's own authority.
    func dropTokenForCurrentAccount() async {
        guard let token = deviceToken else { return }
        struct Body: Encodable { let token: String }
        _ = try? await APIClient.shared.rawRequest(
            "DELETE", "/users/me/push-token", body: Body(token: token)
        )
        UserDefaults.standard.removeObject(forKey: Self.lastSentTokenKey)
    }

    /// This install's APNs token: the one APNs handed over this launch, else
    /// the one last registered. The token belongs to the install and not to an
    /// account, so the sent-cache ("uin:token") still names it on a launch
    /// where APNs has not called back yet, or where alerts were switched off
    /// after rows were already registered.
    var installToken: String? {
        deviceToken ?? Self.token(fromSentKey: UserDefaults.standard.string(forKey: Self.lastSentTokenKey))
    }

    /// The token half of a sent-cache key "uin:token".
    nonisolated static func token(fromSentKey key: String?) -> String? {
        guard let key, let colon = key.firstIndex(of: ":") else { return nil }
        let token = String(key[key.index(after: colon)...])
        return token.isEmpty ? nil : token
    }

    /// `accounts_here` for a token registration (report 1066): every number
    /// this install holds on the island the registration goes to, `ownUIN`
    /// (the caller) included. The island drops this install's rows for any
    /// other number, which is how the row of an account deleted from the
    /// phone goes away without that account's credentials.
    ///
    /// nil means "do not send the field", and it is nil whenever the list
    /// could be short, because a number missing from it loses its pushes:
    /// an account on this island whose number does not read back, or more
    /// numbers than the island takes (64). An account counts as on this
    /// island when its address is one of ours by any name (`isOwnHost`) or
    /// canonicalises to the active account's; one too many costs nothing,
    /// the island only spares its row. Every account of the roster counts,
    /// with a token or without one, guest copies too.
    static func accountsHere(ownUIN: Int) -> [Int]? {
        let am = AccountManager.shared
        guard let active = am.active,
              let home = Multihome.normalizeHost(active.serverURL).map(GuestProof.canonicalHost)
        else { return nil }
        var numbers: Set<Int> = [ownUIN]
        for account in am.accounts where account.id != active.id {
            let host = Multihome.normalizeHost(account.serverURL).map(GuestProof.canonicalHost)
            // Unparseable counts as here: the cost of guessing wrong that way
            // is a row kept, the other way a row lost.
            if let host, host != home, !Multihome.isOwnHost(host) { continue }
            guard let raw = KeychainStore.string(KeychainStore.Keys.uin, forAccount: account.id),
                  let number = Int(raw) else { return nil }
            numbers.insert(number)
        }
        return numbers.count <= 64 ? numbers.sorted() : nil
    }

    /// Ask `account`'s island to stop waking this install for it: one
    /// `DELETE /users/me/push-token` per token this install registers (APNs
    /// and VoIP), with that account's own bearer (report 1066).
    ///
    /// For an account being deleted from the phone, which may not be the
    /// active one: `dropTokenForCurrentAccount` speaks for the active account
    /// only, so deleting any other account left its rows on the island for
    /// good, waking this phone for a number it no longer held. Everything is
    /// read HERE, synchronously, so the caller can wipe the Keychain the
    /// moment this returns; the requests then go out on their own.
    ///
    /// Best effort, like the twin above. A row that survives (no network, an
    /// island that refuses the old bearer) is shed by the next registration
    /// on that island through `accountsHere`, and the extension shows nothing
    /// for it meanwhile. Nothing is kept for a retry: it would be a bearer of
    /// an account the person removed, left on the phone.
    static func releasePushRows(of account: Account) {
        if DuressGate.isActive { return }
        let am = AccountManager.shared
        guard let bearer = KeychainStore.string(KeychainStore.Keys.token, forAccount: account.id),
              let uin = KeychainStore.string(KeychainStore.Keys.uin, forAccount: account.id),
              let host = Multihome.normalizeHost(account.serverURL),
              let url = URL(string: "https://\(host)/users/me/push-token")
        else { return }
        // The same number on the same island under another account here is
        // the same account on the island, and the row is that account's too.
        let island = GuestProof.canonicalHost(host)
        let shared = am.accounts.contains { other in
            other.id != account.id
                && KeychainStore.string(KeychainStore.Keys.uin, forAccount: other.id) == uin
                && Multihome.normalizeHost(other.serverURL).map(GuestProof.canonicalHost) == island
        }
        if shared { return }
        let tokens = [NotificationService.shared.installToken, VoIPPushService.shared.installToken]
            .compactMap { $0 }
        guard !tokens.isEmpty else { return }
        let masquerade = account.serverToken
        let viaHome = Multihome.isOwnHost(host)
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for token in tokens {
                    group.addTask {
                        if viaHome {
                            // Our own island: the route the app reaches it by
                            // right now, which may be a front or a relay.
                            var gate = masquerade
                            if gate == nil { gate = await APIClient.shared.currentServerToken() }
                            _ = await APIClient.shared.deletePushToken(token, bearer: bearer, serverToken: gate)
                        } else {
                            var req = URLRequest(url: url)
                            req.httpMethod = "DELETE"
                            req.timeoutInterval = 15
                            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
                            if let masquerade, !masquerade.isEmpty {
                                req.setValue(masquerade, forHTTPHeaderField: "X-RCQ-Auth")
                            }
                            AccessTokenStore.stamp(&req)   // closed-island gate (foreign host)
                            _ = try? await IslandHTTP.data(for: req)
                        }
                    }
                }
            }
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
