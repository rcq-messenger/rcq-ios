import Combine
import Foundation
import Network
import SwiftUI

/// Top-level state holder. Wires the WS event stream into services and surfaces
/// pending deep-link targets that views consume.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var booted: Bool = false
    @Published var bootError: String? = nil
    @Published var isOffline: Bool = false
    @Published var bootStatus: BootStatus = .connecting

    enum BootStatus {
        case connecting
        case engagingStealth
        case stealthActive
    }
    /// Capabilities advertised by the active server via `/server/info`.
    /// Defaults to the permissive "legacy backend" set so pre-flag
    /// servers (and the brief window between boot start and the fetch
    /// landing) keep the same surfaces as before. Reset to
    /// `.defaultLegacy` on every account switch and re-populated by
    /// the next boot.
    @Published var serverCapabilities: ServerCapabilities = .defaultLegacy
    @Published var typingByUIN: [Int: Bool] = [:]
    @Published var pendingAddUIN: Int? = nil
    @Published var pendingOpenChatUIN: Int? = nil
    @Published var pendingOpenGroupID: Int? = nil
    /// Drives the `GroupJoinSheet` when a user taps a shared-group
    /// card from chat. Same deep-link mechanism as the marketplace +
    /// UIN-share flows; cleared by the sheet when it dismisses.
    @Published var pendingJoinGroupID: Int? = nil
    @Published var pendingOpenPending: Bool = false
    /// Tap target for @mentions in group chat. ContactListView shows
    /// `UserInfoView` for the UIN as a sheet.
    @Published var pendingOpenUserProfile: Int? = nil

    /// Server-join request captured from an `rcq://server/<host>?invite=<code>`
    /// deep link (the QR an operator of an invite-only island shares). The root
    /// view presents a confirmation sheet that adds the account with the invite.
    @Published var pendingServerJoin: ServerJoinRequest? = nil

    /// A pending invite-only server join. `host` is a bare domain
    /// (e.g. "island.example.com"); `invite` is nil for an open server link.
    struct ServerJoinRequest: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let invite: String?
    }

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "rcq.path-monitor")
    private var pendingOnlineSync: Task<Void, Never>?

    /// UserDefaults key for a referral inviter UIN captured before
    /// register. Consumed by the fresh-register path; ignored for
    /// existing accounts.
    static let pendingInviterKey = "rcq.pendingInviterUIN"

    /// UserDefaults key for a server-join invite token, stashed by
    /// `addAccount` and consumed once by the next `/auth/register` (required
    /// only by servers running REGISTRATION_POLICY=invite; ignored otherwise).
    static let pendingServerInviteKey = "rcq.pendingServerInvite"

    func handle(deepLink url: URL) {
        // Invite-only server join — rcq://server/<host>?invite=<code> (the
        // QR/link an island operator shares) or https://rcq.app/s/<host>?invite=.
        // `invite` is omitted for an open-server link.
        func inviteParam(_ u: URL) -> String? {
            URLComponents(url: u, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "invite" })?.value
        }
        if url.scheme == "rcq", url.host == "server",
           let host = url.pathComponents.dropFirst().first(where: { !$0.isEmpty }) {
            pendingServerJoin = ServerJoinRequest(host: host, invite: inviteParam(url))
            return
        }
        if (url.scheme == "https" || url.scheme == "http"), url.host == "rcq.app",
           url.pathComponents.count >= 3, url.pathComponents[1] == "s",
           !url.pathComponents[2].isEmpty {
            pendingServerJoin = ServerJoinRequest(host: url.pathComponents[2], invite: inviteParam(url))
            return
        }
        // Referral link — rcq://r/<uin> or https://rcq.app/r/<uin>.
        if (url.scheme == "rcq" && url.host == "r"),
           let last = url.pathComponents.last, let uin = Int(last), uin > 0 {
            UserDefaults.standard.set(uin, forKey: Self.pendingInviterKey)
            return
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "r",
           let uin = Int(url.pathComponents[2]), uin > 0 {
            UserDefaults.standard.set(uin, forKey: Self.pendingInviterKey)
            return
        }
        if url.scheme == "rcq", url.host == "add" {
            let uinStr = url.pathComponents.last ?? ""
            if let uin = Int(uinStr), uin > 0 {
                pendingAddUIN = uin
            }
            return
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "u" {
            let uinStr = url.pathComponents[2]
            if let uin = Int(uinStr), uin > 0 {
                pendingAddUIN = uin
            }
            return
        }
        // Group share — `rcq://group/<id>` (custom scheme from in-app
        // taps on the share-card) or `https://rcq.app/g/<id>` (the
        // text-paste / browser path). Both route to the same
        // `pendingJoinGroupID`; the JoinSheet handles already-member
        // by jumping the user straight into the group chat instead.
        if url.scheme == "rcq", url.host == "group" {
            if let last = url.pathComponents.last, let gid = Int(last), gid > 0 {
                pendingJoinGroupID = gid
            }
            return
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "g" {
            if let gid = Int(url.pathComponents[2]), gid > 0 {
                pendingJoinGroupID = gid
            }
            return
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var typingTimers: [Int: Timer] = [:]

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                self?.handlePathChange(offline: offline)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func handlePathChange(offline: Bool) {
        let wasOffline = isOffline
        isOffline = offline
        // Coming back online after an offline boot — replay the network
        // half of the boot sequence so caches/contacts/wallet sync up.
        if wasOffline && !offline && booted {
            pendingOnlineSync?.cancel()
            pendingOnlineSync = Task { [weak self] in
                await self?.runOnlineSync()
            }
        }
    }

    private func runOnlineSync() async {
        guard !PanicPINService.shared.isDecoy else { return }
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
        let baseURL = APIClient.shared.baseURL
        let serverToken = AccountManager.shared.active?.serverToken
        WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL, serverToken: serverToken)
        await syncOwnPresenceFromServer(uin: uin)
        await ContactService.shared.refresh()
        await GroupService.shared.refresh()
        await MessageService.shared.fetchOfflineQueue()
    }

    private func scheduleTransportRetry() {
        guard SingBoxTransport.shared.isActive else { return }
        pendingOnlineSync?.cancel()
        pendingOnlineSync = Task { [weak self] in
            for _ in 0..<18 {  // ~3 minutes of 10s retries
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.isOffline else { return }
                let reach = await APIClient.shared.refreshActiveBase()
                if reach != .unreachable {
                    self.isOffline = false
                    await self.runOnlineSync()
                    return
                }
            }
        }
    }

    func boot(suggestedNickname: String? = nil) async {
        RelayConfigStore.shared.refreshInBackground()
        // Push the active account's masquerade token to APIClient
        // BEFORE any HTTP fires. Defaults to nil for public backends
        // (api.rcq.app), set per-account by the operator at add-time
        // for self-host instances behind a Caddy `X-RCQ-Auth` gate.
        // Without this header, those backends serve a decoy static
        // site instead of FastAPI — `/health` and `/auth/register`
        // would both 404 to the scanner, and to us too if we forget
        // the token.
        await APIClient.shared.setServerToken(AccountManager.shared.active?.serverToken)

        // Offline-first path. If we already have a local identity AND no
        // network is available, skip every server-touching call and let
        // the app launch into the local-only surfaces (Radio Chat over
        // Bluetooth, settings, history). The online sync runs as soon
        // as connectivity returns via the NWPathMonitor handler.
        let cachedUIN = AuthService.shared.ownUIN
        let cachedToken = KeychainStore.string(KeychainStore.Keys.token)
        let pathSatisfied = pathMonitor.currentPath.status == .satisfied

        // Fresh install still on the onboarding deck: no account in the roster
        // and no legacy identity to validate. Do NOT auto-register a throwaway
        // identity here — the user hasn't yet chosen "new account" vs "restore
        // from phrase". Registration is minted explicitly when they finish
        // onboarding (RCQApp re-runs boot on `didOnboard`) or recovered by
        // `recoverAccount`. Without this gate a fresh launch registered a UIN
        // into the legacy unprefixed Keychain slot before that choice, leaving
        // an orphan account and poisoning the legacy→account migration for a
        // restored identity. Returning users (roster populated, or a legacy
        // identity AccountManager already wrapped as Account[0]) skip the gate.
        if AccountManager.shared.active == nil, cachedUIN == nil {
            return
        }

        if !pathSatisfied || PanicPINService.shared.isDecoy,
           let uin = cachedUIN, cachedToken != nil {
            isOffline = !PanicPINService.shared.isDecoy
            MessageService.shared.configure(ownUIN: uin)
            booted = true
            return
        }

        // Watchdog: the network branch below can hang on a wedged
        // sing-box start, a dead upstream proxy or a slow TLS
        // handshake against a degraded relay. If 15s pass without
        // booted=true, surrender to offline mode (when we have a
        // cached identity) or surface the unreachable error. Keeps
        // the loading spinner from spinning forever.
        // First-launch registration over a censored network legitimately
        // takes longer (probe direct → engage transport → register through
        // the tunnel), so give a registration boot a longer leash before the
        // watchdog surrenders. Returning users keep the snappy 15s.
        let watchdogSeconds: UInt64 = cachedUIN == nil ? 25 : 15
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: watchdogSeconds * 1_000_000_000)
            guard let self else { return }
            await MainActor.run {
                guard !self.booted else { return }
                if cachedUIN != nil && cachedToken != nil {
                    self.isOffline = true
                    if let uin = cachedUIN {
                        MessageService.shared.configure(ownUIN: uin)
                    }
                    self.booted = true
                    self.scheduleTransportRetry()
                } else {
                    self.bootError = "boot.error.unreachable".localized
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            // First-launch registration over a censored network: bring the
            // embedded transport up BEFORE the first /auth/register if the
            // direct path is blocked, so a brand-new user doesn't have to
            // switch on a VPN just to sign up (mirrors Android's
            // ensureTransportForHost). Only for a fresh install (no cached
            // identity); returning users fall through to the probe chain
            // below, which already auto-engages on an unreachable direct path.
            if cachedUIN == nil,
               !SingBoxTransport.shared.isActive,
               !SingBoxTransport.isEnabled,
               !UserDefaults.standard.bool(forKey: "rcq.singbox.autoDisabled") {
                let directOK = await APIClient.shared.probeDirectReachable()
                if !directOK {
                    bootStatus = .engagingStealth
                    do {
                        try await SingBoxTransport.shared.start()
                        await APIClient.shared.applyTransportProxy()
                    } catch {
                        print("[boot] pre-register transport engage failed: \(error)")
                    }
                }
            }
            bootStatus = .connecting
            if SingBoxTransport.isEnabled {
                bootStatus = .engagingStealth
                do {
                    try await SingBoxTransport.shared.start()
                    await APIClient.shared.applyTransportProxy()
                } catch {
                    print("[boot] sing-box transport failed to start: \(error)")
                }
            }
            var reach = await APIClient.shared.refreshActiveBase()
            // Auto-engage when direct is unreachable — unless the user
            // explicitly opted out (they route through their own proxy
            // / VPN and don't want our embedded sing-box on top of
            // theirs). The explicit toggle still wins above; this
            // gates only the "fall back when nothing works" branch.
            let autoDisabled = UserDefaults.standard.bool(forKey: "rcq.singbox.autoDisabled")
            if reach == .unreachable, !SingBoxTransport.shared.isActive, !autoDisabled {
                bootStatus = .engagingStealth
                do {
                    try await SingBoxTransport.shared.start()
                    await APIClient.shared.applyTransportProxy()
                    reach = await APIClient.shared.refreshActiveBase()
                } catch {
                    print("[boot] auto sing-box transport failed: \(error)")
                }
            }
            if reach == .unreachable, SingBoxTransport.shared.isActive {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                reach = await APIClient.shared.refreshActiveBase()
            }
            if reach != .unreachable, SingBoxTransport.shared.isActive {
                bootStatus = .stealthActive
            }
            if reach == .unreachable {
                if let uin = cachedUIN, cachedToken != nil {
                    isOffline = true
                    MessageService.shared.configure(ownUIN: uin)
                    booted = true
                    scheduleTransportRetry()
                } else {
                    bootError = "boot.error.unreachable".localized
                }
                return
            }
            try await AuthService.shared.bootstrapIfNeeded(suggestedNickname: suggestedNickname)
            guard let uin = AuthService.shared.ownUIN,
                  let token = KeychainStore.string(KeychainStore.Keys.token) else {
                throw NSError(domain: "boot", code: 1)
            }
            MessageService.shared.configure(ownUIN: uin)

            // Capability fetch. Failure is non-fatal — we keep the
            // permissive defaultLegacy set, which matches every
            // backend's behaviour before v0.4 added /server/info.
            // Self-host backends running rcq-server-ref return
            // {uin_shop: false} here and SettingsView drops the row
            // entirely; api.rcq.app returns {uin_shop: true} and the
            // surface stays.
            if let caps = await ServerInfoService.fetch() {
                serverCapabilities = caps
            }

            let baseURL = APIClient.shared.baseURL
            WebSocketService.shared.connect(
                uin: uin, token: token, baseURL: baseURL,
                serverToken: AccountManager.shared.active?.serverToken
            )

            await syncOwnPresenceFromServer(uin: uin)
            await ContactService.shared.refresh()
            await GroupService.shared.refresh()
            await MessageService.shared.fetchOfflineQueue()
            await NotificationService.shared.requestAuthorization()
            await NotificationService.shared.refreshTokenSubmission()
            await NotificationPrefsService.shared.refresh()
            await VoIPPushService.shared.refreshTokenSubmission()

            booted = true
        } catch {
            // If we have a cached identity, fall back to offline-mode
            // boot rather than blocking the UI on a transport error.
            if let uin = cachedUIN, cachedToken != nil {
                isOffline = true
                MessageService.shared.configure(ownUIN: uin)
                booted = true
            } else {
                bootError = error.localizedDescription
            }
        }
    }

    // MARK: - migration

    enum MigrationResult: Equatable {
        case success(newUIN: Int)
        case cooldown
        case taken
        case other(String)
    }

    // Suppresses the `.accountBurned` handler on THIS session during
    // an in-flight migrate; the server fans `account_burned` to every
    // WS under the old uin, including this one.
    private var migratingAccount: Bool = false

    /// Migrate the account to a freshly-allocated UIN. Server keeps
    /// profile + contacts + groups; identity + signing keys are
    /// reused server-side so peers' stage-2 sessions survive;
    /// stage-3 material is dropped and re-handshakes on next message.
    func migrateAccount() async -> MigrationResult {
        return await performMigration {
            try await APIClient.shared.request("POST", "/account/migrate")
        }
    }

    /// Purchase a specific UIN via mock IAP and migrate onto it.
    /// Reuses the same wipe + re-boot pipeline as the regular
    /// `migrateAccount` flow.
    func purchaseUIN(_ uin: Int, receipt: String) async -> MigrationResult {
        struct Body: Encodable {
            let uin: Int
            let receipt: String
        }
        return await performMigration {
            try await APIClient.shared.request(
                "POST", "/uin/purchase",
                body: Body(uin: uin, receipt: receipt)
            )
        }
    }

    private struct MigrateOut: Decodable {
        let new_uin: Int
        let token: String
    }

    private func performMigration(
        _ call: () async throws -> MigrateOut
    ) async -> MigrationResult {
        let resp: MigrateOut
        // Must be set before the POST: server fires `account_burned`
        // before the HTTP response unwinds.
        migratingAccount = true
        do {
            resp = try await call()
        } catch APIError.http(409, _) {
            migratingAccount = false
            return .taken
        } catch APIError.http(429, _) {
            migratingAccount = false
            return .cooldown
        } catch APIError.http(_, let body) {
            migratingAccount = false
            return .other(body ?? "Server refused the migration")
        } catch {
            migratingAccount = false
            return .other(error.localizedDescription)
        }

        WebSocketService.shared.disconnect()
        ContactService.shared.wipe()
        GroupService.shared.wipe()
        AudioRoomService.shared.wipe()
        PushDecryptCache.wipe()
        NotificationPrefsService.shared.wipe()
        // A UIN move REUSES the same identity (only the server-side handle
        // changes), so chat history (peer-keyed), favourites, archive and
        // per-chat settings/sounds all stay valid. Don't nuke them like a burn
        // does — that was the move-to-new-UIN data loss. Reset only the
        // in-memory thread cache; the rows stay on disk and reload on boot.
        MessageStore.shared.resetInMemory()
        VisitStore.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        NotificationService.shared.wipe()
        VoIPPushService.shared.wipe()
        NearbyService.shared.wipe()
        NicknameCache.wipe()
        GroupNameCache.wipe()
        RemovedContactsStore.shared.wipe()
        ReactionInboxStore.shared.wipe()
        SignalProtocolDB.shared.wipe()
        EncryptedBlobDiskCache.shared.clear()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenUserProfile = nil
        pendingAddUIN = nil

        let nickname = AuthService.shared.nickname
        KeychainStore.delete(KeychainStore.Keys.uin)
        KeychainStore.delete(KeychainStore.Keys.token)
        KeychainStore.setString(KeychainStore.Keys.uin, String(resp.new_uin))
        KeychainStore.setString(KeychainStore.Keys.token, resp.token)
        if !nickname.isEmpty {
            KeychainStore.setString(KeychainStore.Keys.nickname, nickname)
        }
        await APIClient.shared.setToken(resp.token)

        booted = false
        bootError = nil
        await boot()

        migratingAccount = false
        return .success(newUIN: resp.new_uin)
    }

    /// User-initiated nuclear reset. Wipes server account + every local
    /// store, then re-runs `boot()` which mints a fresh identity.
    func burnAccount() async {
        await AuthService.shared.deleteServerAccount()
        WebSocketService.shared.disconnect()

        ContactService.shared.wipe()
        GroupService.shared.wipe()
        PushDecryptCache.wipe()
        NotificationPrefsService.shared.wipe()
        MessageStore.shared.clearAll()
        VisitStore.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        NotificationService.shared.wipe()
        VoIPPushService.shared.wipe()
        FavoritesStore.shared.wipe()
        ArchiveStore.shared.wipe()
        ContactSoundStore.shared.wipe()
        ChatSettingsStore.shared.wipe()
        NearbyService.shared.wipe()
        NicknameCache.wipe()
        GroupNameCache.wipe()
        RemovedContactsStore.shared.wipe()
        ReactionInboxStore.shared.wipe()
        EncryptedBlobDiskCache.shared.clear()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenUserProfile = nil
        pendingAddUIN = nil

        await AuthService.shared.wipeLocalIdentity()

        booted = false
        bootError = nil
        await boot()
    }

    /// Soft switch to a different existing account. Wipes only the
    /// in-memory view of the current account (contacts, groups,
    /// message store, WebSocket) — persistent storage (per-account
    /// Keychain entries, per-account MessageDB file) stays intact
    /// so switching back later resumes where we left off.
    ///
    /// No-op if the target account isn't in the roster or is
    /// already active.
    func switchToAccount(_ id: UUID) async {
        guard AccountManager.shared.accounts.contains(where: { $0.id == id }) else { return }
        guard id != AccountManager.shared.activeAccountID else { return }
        AccountManager.shared.setActive(id)
        await rebootForActiveAccount()
    }

    /// Add a brand-new account on `serverURL`, switch active to it,
    /// and let boot mint a fresh identity on the new server. Returns
    /// false when AccountManager refuses the add (roster at limit) —
    /// no switch happens, no boot fires, the caller surfaces the
    /// reason to the user. Returns true on a successful add even if
    /// the subsequent register fails (the user can retry via the
    /// switcher; the dangling account stays in the roster).
    @discardableResult
    func addAccount(serverURL: String, serverToken: String? = nil, invite: String? = nil) async -> Bool {
        // Stash the server-join invite for the fresh register that boot() runs
        // on the new account. Consumed once in AuthService.register; harmless on
        // open servers (the backend ignores it unless policy=invite).
        if let invite, !invite.isEmpty {
            UserDefaults.standard.set(invite, forKey: Self.pendingServerInviteKey)
        }
        // AccountManager.add also setActive(new.id) and triggers
        // mirrorActiveToLegacy → App Group file + rcq.baseURL
        // already point at the new account by the time
        // rebootForActiveAccount runs. serverToken optional; non-nil
        // for self-host backends behind a Caddy X-RCQ-Auth gate, nil
        // for public deployments (api.rcq.app, default self-host).
        guard AccountManager.shared.add(serverURL: serverURL, serverToken: serverToken) != nil else {
            UserDefaults.standard.removeObject(forKey: Self.pendingServerInviteKey)
            return false
        }
        await rebootForActiveAccount()
        return true
    }

    /// Restore an existing identity from its 24-word BIP39 phrase onto
    /// `serverURL` as a NEW local account. Derives the keypair from the seed,
    /// proves possession of the signing key to the server (`/auth/recover`
    /// challenge → Ed25519 signature), and on success adds + activates the
    /// account with the recovered UIN/token/keys/seed already in the Keychain,
    /// then boots it (bootstrap validates the cached identity — no re-register).
    ///
    /// Returns nil on success, or a localized error string. On failure the
    /// dangling account is rolled back and the previous active (if any) is
    /// rebooted, so the caller stays where it was. Used from both the
    /// onboarding "Restore from phrase" entry (fresh install: no previous
    /// account, the gate in `boot()` having suppressed the launch throwaway)
    /// and Settings "Add account → Restore".
    func recoverAccount(phrase words: [String], serverURL: String) async -> String? {
        if AccountManager.shared.isAtAccountLimit {
            return String(format: "add_account.limit".localized, AccountManager.maxAccounts)
        }
        guard let decoded = RecoveryPhrase.decode(words) else {
            return "recovery.restore.error.invalid".localized
        }
        // 32 bytes = a seed (new accounts) → derive; 64 bytes = a legacy
        // account's raw idPriv||signPriv export → use directly, no seed carried.
        let keys: RecoveryPhrase.DerivedKeys
        let seedToStore: Data?
        do {
            if decoded.count == 32 {
                keys = try RecoveryPhrase.deriveKeys(seed: decoded)
                seedToStore = decoded
            } else if decoded.count == 64 {
                keys = try RecoveryPhrase.keysFromRaw(
                    identityPriv: Data(decoded.prefix(32)),
                    signingPriv: Data(decoded.suffix(32)))
                seedToStore = nil
            } else {
                return "recovery.restore.error.invalid".localized
            }
        } catch { return "recovery.restore.error.generic".localized }

        let previousActiveID = AccountManager.shared.activeAccountID
        guard let acct = AccountManager.shared.add(serverURL: serverURL) else {
            return String(format: "add_account.limit".localized, AccountManager.maxAccounts)
        }
        // The new account is now active: AccountManager.add already mirrored
        // rcq.baseURL + the App Group active-id, so APIClient targets
        // `serverURL` and KeychainStore.set lands under `acct.id`. Tear down the
        // outgoing session's socket + in-memory identity and clear any stale
        // token so the unauthenticated recover probes go out clean. Engage the
        // proxy / pick a reachable base exactly like boot() does pre-register so
        // recovery works on a censored network too.
        WebSocketService.shared.disconnect()
        AuthService.shared.resetForAccountSwitch()
        await APIClient.shared.setServerToken(nil)
        await APIClient.shared.setToken(nil)
        _ = await APIClient.shared.refreshActiveBase()

        struct ChalBody: Encodable { let signing_key: String }
        struct ChalOut: Decodable { let challenge: String }
        struct RecBody: Encodable { let signing_key: String; let challenge: String; let signature: String }
        struct RecOut: Decodable { let uin: Int; let token: String }

        do {
            let chal: ChalOut = try await APIClient.shared.request(
                "POST", "/auth/recover/challenge",
                body: ChalBody(signing_key: keys.signingPubB64),
                authenticated: false
            )
            let signature = try RecoveryPhrase.signChallenge(
                signingPrivate: keys.signingPriv, challenge: chal.challenge)
            let rec: RecOut = try await APIClient.shared.request(
                "POST", "/auth/recover",
                body: RecBody(signing_key: keys.signingPubB64, challenge: chal.challenge, signature: signature),
                authenticated: false
            )

            // Server kept the profile — pull the real nickname back.
            await APIClient.shared.setToken(rec.token)
            var nick = "user-\(rec.uin)"
            if let p: UserProfile = try? await APIClient.shared.request("GET", "/users/\(rec.uin)/info"),
               !p.nickname.isEmpty {
                nick = p.nickname
            }

            // Persist the recovered identity under the new account's prefix.
            KeychainStore.set(KeychainStore.Keys.identityPriv, keys.identityPriv.rawRepresentation)
            KeychainStore.set(KeychainStore.Keys.signingPriv,  keys.signingPriv.rawRepresentation)
            if let seedToStore { KeychainStore.set(KeychainStore.Keys.recoverySeed, seedToStore) }
            KeychainStore.setString(KeychainStore.Keys.uin, String(rec.uin))
            KeychainStore.setString(KeychainStore.Keys.token, rec.token)
            KeychainStore.setString(KeychainStore.Keys.nickname, nick)
        } catch {
            // Roll back the dangling account; restore the previous active.
            KeychainStore.wipeAccount(acct.id)
            AccountManager.shared.remove(acct.id)
            if let prev = previousActiveID {
                AccountManager.shared.setActive(prev)
                await rebootForActiveAccount()
            }
            if case let APIError.http(status, _) = error, status == 404 {
                return "recovery.restore.error.notfound".localized
            }
            return "recovery.restore.error.generic".localized
        }

        // Boot the recovered account: the cached uin+token now validate in
        // bootstrapIfNeeded → ready, with no fresh registration.
        await rebootForActiveAccount()
        return nil
    }

    /// Common sequence used after `setActive` or `add`: disconnect
    /// the old WebSocket, drop every in-memory cache that was
    /// scoped to the previous account, swap MessageDB to the new
    /// account's SQLite file, and re-run boot() so the new
    /// account's Keychain identity + server URL get picked up.
    ///
    /// Critically does NOT touch Keychain entries or SQLite rows —
    /// those live under per-account prefixes / filenames and
    /// survive untouched for the next switch-back. The wipe set
    /// mirrors burnAccount()'s pile minus the destructive bits
    /// (wipeLocalIdentity, deleteServerAccount, SignalProtocolDB.wipe).
    private func rebootForActiveAccount() async {
        WebSocketService.shared.disconnect()
        // Drop AuthService's in-memory snapshot of the OLD active
        // account FIRST so any view that re-renders during the
        // booted=false → booted=true window (BootSplash etc.) reads
        // a clean "no identity" state instead of the stale UIN that
        // belonged to the account we're switching away from.
        AuthService.shared.resetForAccountSwitch()

        // Re-point the masquerade header to the new account's token
        // BEFORE anything fires HTTP against the destination server.
        // boot() also does this defensively, but flipping here covers
        // the brief window where AuthService is being torn down.
        await APIClient.shared.setServerToken(AccountManager.shared.active?.serverToken)

        // Reset to defaultLegacy so the new account's boot fetch
        // populates the actual capabilities of the destination server,
        // not the stale outgoing one. Without this, switching from
        // api.rcq.app (uinShop=true) to a self-host account would
        // briefly show the UIN-shop row in Settings until the new
        // /server/info reply lands.
        serverCapabilities = .defaultLegacy

        ContactService.shared.wipe()
        GroupService.shared.wipe()
        PushDecryptCache.wipe()
        NotificationPrefsService.shared.wipe()
        // Soft switch: clear only the IN-MEMORY thread cache. Do NOT delete rows
        // — history lives in a per-account SQLite file and must survive so a
        // switch-back resumes the conversation. (clearAll() deletes rows; that's
        // the burn/migrate path, not this one. This was the chat-history loss.)
        MessageStore.shared.resetInMemory()
        VisitStore.shared.wipe()
        RandomChatService.shared.wipe()
        CallService.shared.wipe()
        NotificationService.shared.wipe()
        // Favourites / archive / per-chat sounds / per-chat settings are
        // persistent per-device organizational data, NOT transient view state.
        // They live under global UserDefaults keys, so wiping them on a soft
        // switch permanently destroyed them for EVERY account — that was the
        // favourites/archive loss on server switch. Leave them intact here;
        // only burnAccount() (nuclear reset) clears them.
        NearbyService.shared.wipe()
        NicknameCache.wipe()
        GroupNameCache.wipe()
        RemovedContactsStore.shared.wipe()
        ReactionInboxStore.shared.wipe()
        EncryptedBlobDiskCache.shared.clear()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenUserProfile = nil
        pendingAddUIN = nil

        MessageDB.shared.reload()
        SignalProtocolDB.shared.reload()

        booted = false
        bootError = nil
        await boot()
    }

    func performPanicWipe() async {
        PINVault.destroy()
        MessageDB.destroyDecoyStore()
        await burnAccount()
        PanicPINService.shared.finishWipe()
    }

    func resumeAfterUnlock() async {
        guard booted, !PanicPINService.shared.isDecoy else { return }
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
        isOffline = false
        if !WebSocketService.shared.isConnected {
            WebSocketService.shared.connect(
                uin: uin, token: token, baseURL: APIClient.shared.baseURL,
                serverToken: AccountManager.shared.active?.serverToken
            )
        }
        await syncOwnPresenceFromServer(uin: uin)
        await ContactService.shared.refresh()
        await GroupService.shared.refresh()
        await MessageService.shared.fetchOfflineQueue()
    }

    private func syncOwnPresenceFromServer(uin: Int) async {
        do {
            let me: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            // Coerce a legacy .offline self-row to .online — the picker
            // can't reach .offline directly.
            let resolved: UserStatus = (me.status == .offline) ? .online : me.status
            PresenceService.shared.status = resolved
            PresenceService.shared.statusMessage = me.statusMessage
            AuthService.shared.updateNicknameLocal(me.nickname)
        } catch {
            // Soft-fail.
        }
    }

    /// Manual censorship-bypass toggle (Android parity — the home ⋮ menu item).
    /// Engages or drops the sing-box obfuscation transport live and reconnects
    /// the socket so traffic immediately routes through (or stops routing
    /// through) it, no app restart. A manual turn-off also persists the
    /// auto-disable opt-out so the failure-driven auto-engage doesn't turn it
    /// straight back on.
    func setBypass(_ on: Bool) async {
        UserDefaults.standard.set(!on, forKey: "rcq.singbox.autoDisabled")
        await SingBoxTransport.shared.setEnabled(on)
        WebSocketService.shared.reconnectNow()
    }

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .opened:
            // A live realtime socket is the definitive "we're online" signal —
            // clear any stale offline badge the boot watchdog may have set after
            // a slow first connect (the "Без сети while everything works" case).
            if isOffline { isOffline = false }
            // Drain offline queue on every (re)connect.
            Task { await MessageService.shared.fetchOfflineQueue() }
            // Re-sync audio room subscription if we were inside one.
            // Skipped the unconditional contact refresh that used to
            // live here — presence diffs come in via WS events, so
            // polling on every reconnect just added flicker when the
            // watchdog tripped over a slow round-trip and tore down
            // a healthy socket.
            AudioRoomService.shared.restoreOnForeground()

        case .closed:
            // No-op. WebSocketService has its own scheduleReconnect()
            // with exponential backoff that fires from handleDisconnect.
            // We used to ALSO schedule a 2s sleeper here that called
            // connect() — every .closed queued one, the Tasks accumulated,
            // and each one cancelled the in-flight WS task on fire. Result
            // was a 1-second reconnect storm (1300+ open/close per 20 min
            // from a single tester). Leave the reconnect entirely to
            // WebSocketService.
            break

        case .accountBurned:
            // Suppressed during migration — see `migratingAccount`.
            if migratingAccount { return }
            Task { await self.burnAccount() }

        case .presence(let uin, let status, let message):
            let contact = ContactService.shared.contacts.first(where: { $0.uin == uin })
            let wasOnline = contact?.status != .offline
            ContactService.shared.updatePresence(uin: uin, status: status, statusMessage: message)
            GroupService.shared.updateMemberPresence(uin: uin, status: status)
            // Online/offline chime ONLY for actual contacts. A
            // presence event also arrives for users we merely share
            // a group with — chiming on every group co-member's
            // come-and-go was noise the user asked to kill. (It also
            // had a bug: a non-contact resolved `wasOnline` to true
            // via the nil-compare, so their going-offline chimed.)
            if contact != nil {
                if status == .offline && wasOnline {
                    SoundService.shared.play(.contactOffline, thread: .peer(uin: uin))
                } else if status != .offline && !wasOnline {
                    SoundService.shared.play(.contactOnline, thread: .peer(uin: uin))
                }
            }

        case .envelope(let env):
            guard let outcome = MessageService.shared.ingest(envelope: env) else { return }
            // Same envelope can arrive twice (WS live + HTTP queue drain);
            // MessageStore dedupes by UUID, only fire effects on first.
            guard outcome.isNewContent else { return }
            let thread = outcome.thread
            // Per-contact sound override only meaningful for 1:1 threads.
            let sender: Int? = {
                if case .peer(let uin) = thread { return uin }
                return nil
            }()
            // Prefer the snippet of the message we just appended; fall
            // back to a generic localized "new message" if for some
            // reason the thread is empty (control envelope that
            // somehow flagged isNewContent — defensive).
            let latest = MessageStore.shared.messages(for: thread).last
            let preview = latest?.previewSnippet ?? "chat.banner.new_message".localized
            let title: String
            let viewing = MessageBannerService.shared.isViewing(thread)
            switch thread {
            case .peer(let uin):
                if !viewing { ContactService.shared.incrementUnread(for: uin) }
                title = ContactService.shared.contacts.first(where: { $0.uin == uin })?.nickname ?? String(uin)
            case .group(let id):
                if !viewing { GroupService.shared.incrementUnread(id) }
                title = GroupService.shared.find(id)?.name ?? "Group"
            }
            // Muted thread: it still counts as unread (incremented above) and
            // lands in the chat, but produces NO banner, NO sound, and NO
            // backgrounded local notification — mute means silent everywhere,
            // inside the app too.
            let muted = SoundService.shared.isMuted(thread: thread)
            let bannerShown = !muted && MessageBannerService.shared.tryPresent(
                thread: thread, title: title, body: preview,
            )
            // Sound is tied to banner visibility — silent when the
            // user is already in the chat (the message just appears
            // in the open thread, no need for a chime) and silent
            // when the app is backgrounded (APNs alert sound fires instead).
            if bannerShown {
                SoundService.shared.playIncoming(fromUIN: sender, thread: thread)
            }
            if !muted {
                NotificationService.shared.presentIfBackgrounded(
                    title: title, body: preview, threadKey: "\(thread.kindString)-\(thread.rawKey)"
                )
            }

        case .typing(let from, let active):
            typingByUIN[from] = active
            typingTimers[from]?.invalidate()
            if active {
                typingTimers[from] = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.typingByUIN[from] = false }
                }
            }

        case .contactRequest(let id, let from, let nick):
            ContactService.shared.appendPendingRequest(.init(id: id, from_uin: from, nickname: nick, state: "pending"))

        case .contactResponse(_, let accepted, _):
            if accepted { Task { await ContactService.shared.refresh() } }

        case .contactRemoved(let peer):
            // Peer removed us from their contacts (ICQ-style mutual delete).
            // Drop them from our local list so the UI updates instantly.
            // Skip RemovedContactsStore here — the deleter, not the deleted,
            // decides who to filter.
            ContactService.shared.removeLocal(peer)

        case .groupChanged(let group):
            GroupService.shared.upsert(group)

        case .groupDeleted(let id):
            GroupService.shared.purge(id)
            MessageStore.shared.clearThread(.group(id: id))

		case
             .randomMatch, .randomEnd,
             .callOffer, .callAnswer, .callIce, .callEnd,
             .callRenegotiate, .callRenegotiateAnswer, .callRenegotiateDecline,
             .roomEnterRejected, .roomRoster, .roomMemberEntered, .roomMemberLeft,
             .roomOffer, .roomAnswer, .roomIce, .roomSpeaking,
             .roomKicked, .roomDeleted, .roomMembershipRevoked, .roomKeyRotated,
             .roomMemberMuted, .roomOwnerOnlyChanged, .roomRenamed,
             .storyPosted, .storyDeleted,
             .hoodMessage, .hoodCount, .hoodDelete, .hoodReaction:
            // Owned by their respective services that subscribe directly.
            break
        }
    }

}

// MARK: - Server capabilities

/// Server-advertised capabilities consumed by the iOS client to gate
/// optional surfaces. The flagship gate today is the in-app UIN shop:
/// `api.rcq.app` advertises `uinShop=true`, every self-host backend
/// running `rcq-server-ref` defaults to `false`, and `SettingsView`
/// hides the row entirely on backends that don't sell UINs in-app.
///
/// Default values are deliberately permissive (everything on) so that
/// legacy backends predating `/server/info` keep working — they 404
/// the lookup and we fall through to the defaults, which match the
/// pre-flag behaviour. Future capabilities should follow the same
/// rule: pick the default that preserves the old behaviour.
struct ServerCapabilities: Decodable, Equatable {
    var uinShop: Bool

    static let defaultLegacy = ServerCapabilities(uinShop: true)

    private enum CodingKeys: String, CodingKey {
        case uinShop = "uin_shop"
    }
}

private struct ServerInfoResponse: Decodable {
    let name: String
    let capabilities: ServerCapabilities
}

@MainActor
enum ServerInfoService {
    /// Fetch `/server/info` against the currently-pointed backend. Returns
    /// `nil` on any network or decode failure — we never block boot on
    /// this, and we never collapse a previously-known-good capability
    /// set on a transient miss. Callers should only adopt the returned
    /// value on success; see `AppState.boot` for the gating.
    static func fetch() async -> ServerCapabilities? {
        do {
            let info: ServerInfoResponse = try await APIClient.shared.request(
                "GET",
                "/server/info",
                authenticated: false
            )
            return info.capabilities
        } catch {
            return nil
        }
    }
}
