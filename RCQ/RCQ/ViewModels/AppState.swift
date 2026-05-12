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
    @Published var typingByUIN: [Int: Bool] = [:]
    @Published var pendingAddUIN: Int? = nil
    @Published var pendingOpenChatUIN: Int? = nil
    @Published var pendingOpenGroupID: Int? = nil
    @Published var pendingOpenPending: Bool = false
    @Published var pendingOpenTrades: Bool = false
    /// Set when the user taps an outbid in-app banner — the
    /// `GameMinisOverlayHost` consumes it and flips the auction full-
    /// screen cover on.
    @Published var pendingOpenUinAuction: Bool = false
    /// Set by the deep-link parser when a share-to-chat market URL
    /// (`rcq://market/{id}` or `https://rcq.app/m/{id}`) lands. The
    /// MarketView consumes it on appear and opens the detail sheet
    /// for that listing.
    @Published var pendingOpenMarketListingID: String? = nil
    /// Mirror of `pendingOpenMarketListingID` for the UIN marketplace.
    @Published var pendingOpenUinListingID: String? = nil
    /// Tap target for @mentions in group chat. ContactListView shows
    /// `UserInfoView` for the UIN as a sheet.
    @Published var pendingOpenUserProfile: Int? = nil

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "rcq.path-monitor")
    private var pendingOnlineSync: Task<Void, Never>?

    func handle(deepLink url: URL) {
        if url.scheme == "rcq", url.host == "add" {
            let uinStr = url.pathComponents.last ?? ""
            if let uin = Int(uinStr), uin > 0 {
                pendingAddUIN = uin
            }
            return
        }
        if url.scheme == "rcq", url.host == "uin-listing" {
            let id = url.pathComponents.last ?? ""
            if !id.isEmpty {
                pendingOpenUinListingID = id
            }
            return
        }
        if url.scheme == "rcq", url.host == "market" {
            // `rcq://market/{listing_id}` — opens the marketplace
            // and presents the listing detail sheet for the id.
            let id = url.pathComponents.last ?? ""
            if !id.isEmpty {
                pendingOpenMarketListingID = id
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
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "m" {
            // `https://rcq.app/m/{listing_id}` — same target as the
            // `rcq://` variant, used by the OS share-sheet / web
            // pasteboard paths where a custom scheme would be
            // unhelpful (browser refuses to redirect to it).
            let id = url.pathComponents[2]
            if !id.isEmpty {
                pendingOpenMarketListingID = id
            }
            return
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "ul" {
            let id = url.pathComponents[2]
            if !id.isEmpty {
                pendingOpenUinListingID = id
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
        guard let uin = AuthService.shared.ownUIN,
              let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
        let baseURL = APIClient.shared.baseURL
        WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL)
        await syncOwnPresenceFromServer(uin: uin)
        await ItemsService.shared.refreshCatalog()
        await ItemsService.shared.refreshInventory()
        await ContactService.shared.refresh()
        await GroupService.shared.refresh()
        await MessageService.shared.fetchOfflineQueue()
    }

    func boot(suggestedNickname: String? = nil) async {
        // Offline-first path. If we already have a local identity AND no
        // network is available, skip every server-touching call and let
        // the app launch into the local-only surfaces (Radio Chat over
        // Bluetooth, settings, history). The online sync runs as soon
        // as connectivity returns via the NWPathMonitor handler.
        let cachedUIN = AuthService.shared.ownUIN
        let cachedToken = KeychainStore.string(KeychainStore.Keys.token)
        let pathSatisfied = pathMonitor.currentPath.status == .satisfied

        if !pathSatisfied, let uin = cachedUIN, cachedToken != nil {
            isOffline = true
            MessageService.shared.configure(ownUIN: uin)
            booted = true
            return
        }

        do {
            try await AuthService.shared.bootstrapIfNeeded(suggestedNickname: suggestedNickname)
            guard let uin = AuthService.shared.ownUIN,
                  let token = KeychainStore.string(KeychainStore.Keys.token) else {
                throw NSError(domain: "boot", code: 1)
            }
            MessageService.shared.configure(ownUIN: uin)

            let baseURL = APIClient.shared.baseURL
            WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL)

            await syncOwnPresenceFromServer(uin: uin)
            // Eager catalog + inventory: contact-list / chat header pet
            // glyphs read from these synchronously and silently no-op
            // when missing.
            await ItemsService.shared.refreshCatalog()
            await ItemsService.shared.refreshInventory()
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
        case insufficientTokens(required: Int, have: Int)
        case cooldown
        case other(String)
    }

    // Suppresses the `.accountBurned` handler on THIS session during
    // an in-flight migrate; the server fans `account_burned` to every
    // WS under the old uin, including this one.
    private var migratingAccount: Bool = false

    /// Migrate the account to a freshly-allocated UIN. Server keeps
    /// profile + contacts + items + wallet (minus the 99-token fee).
    /// Identity + signing keys are reused server-side so peers' stage-2
    /// sessions survive; stage-3 material is dropped and re-handshakes
    /// on next message.
    func migrateAccount(targetUIN: Int? = nil) async -> MigrationResult {
        struct Body: Encodable { let target_uin: Int? }
        struct MigrateOut: Decodable {
            let new_uin: Int
            let token: String
        }
        let resp: MigrateOut
        // Must be set before the POST: server fires `account_burned`
        // before the HTTP response unwinds.
        migratingAccount = true
        do {
            resp = try await APIClient.shared.request(
                "POST", "/account/migrate",
                body: Body(target_uin: targetUIN)
            )
        } catch APIError.http(402, let body) {
            migratingAccount = false
            return Self.parseInsufficient(body) ?? .other("Not enough tokens")
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
        SignalProtocolDB.shared.wipe()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenTrades = false
        pendingOpenUinAuction = false
        pendingOpenMarketListingID = nil
        pendingOpenUinListingID = nil
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

        // forceWallet bypasses ItemsService's defensive max() so the
        // post-deduction balance from the server wins.
        await ItemsService.shared.refreshInventory(forceWallet: true)

        migratingAccount = false
        return .success(newUIN: resp.new_uin)
    }

    private static func parseInsufficient(_ body: String?) -> MigrationResult? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any],
              detail["code"] as? String == "insufficient_tokens",
              let required = detail["required"] as? Int,
              let have = detail["have"] as? Int else {
            return nil
        }
        return .insufficientTokens(required: required, have: have)
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
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenGroupID = nil
        pendingOpenPending = false
        pendingOpenTrades = false
        pendingOpenUinAuction = false
        pendingOpenMarketListingID = nil
        pendingOpenUinListingID = nil
        pendingOpenUserProfile = nil
        pendingAddUIN = nil

        await AuthService.shared.wipeLocalIdentity()

        booted = false
        bootError = nil
        await boot()
    }

    private func syncOwnPresenceFromServer(uin: Int) async {
        do {
            let me: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            PresenceService.shared.status = me.status == .offline ? .online : me.status
            PresenceService.shared.statusMessage = me.statusMessage
            AuthService.shared.updateNicknameLocal(me.nickname)
        } catch {
            // Soft-fail.
        }
    }

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .opened:
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
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let uin = AuthService.shared.ownUIN,
                      let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
                let baseURL = APIClient.shared.baseURL
                WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL)
            }

        case .accountBurned:
            // Suppressed during migration — see `migratingAccount`.
            if migratingAccount { return }
            Task { await self.burnAccount() }

        case .presence(let uin, let status, let message):
            let wasOnline = ContactService.shared.contacts.first(where: { $0.uin == uin })?.status != .offline
            ContactService.shared.updatePresence(uin: uin, status: status, statusMessage: message)
            GroupService.shared.updateMemberPresence(uin: uin, status: status)
            if status == .offline && wasOnline {
                SoundService.shared.play(.contactOffline, thread: .peer(uin: uin))
            } else if status != .offline && !wasOnline {
                SoundService.shared.play(.contactOnline, thread: .peer(uin: uin))
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
            switch thread {
            case .peer(let uin):
                ContactService.shared.incrementUnread(for: uin)
                title = ContactService.shared.contacts.first(where: { $0.uin == uin })?.nickname ?? String(uin)
            case .group(let id):
                GroupService.shared.incrementUnread(id)
                title = GroupService.shared.find(id)?.name ?? "Group"
            }
            let bannerShown = MessageBannerService.shared.tryPresent(
                thread: thread, title: title, body: preview,
            )
            // Sound is tied to banner visibility — silent when the
            // user is already in the chat (the message just appears
            // in the open thread, no need for a chime) and silent
            // when the app is backgrounded (APNs alert sound fires
            // instead). `playIncoming` still respects per-thread
            // mute on top of this gate.
            if bannerShown {
                SoundService.shared.playIncoming(fromUIN: sender, thread: thread)
            }
            NotificationService.shared.presentIfBackgrounded(
                title: title, body: preview, threadKey: "\(thread.kindString)-\(thread.rawKey)"
            )

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

        case .groupChanged(let group):
            GroupService.shared.upsert(group)

        case .groupDeleted(let id):
            GroupService.shared.purge(id)
            MessageStore.shared.clearThread(.group(id: id))

		case .hoodMessage, .hoodCount, .hoodDelete, .hoodReaction,
             .randomMatch, .randomEnd,
             .callOffer, .callAnswer, .callIce, .callEnd,
             .callRenegotiate, .callRenegotiateAnswer, .callRenegotiateDecline,
             .roomEnterRejected, .roomRoster, .roomMemberEntered, .roomMemberLeft,
             .roomOffer, .roomAnswer, .roomIce, .roomSpeaking,
             .roomKicked, .roomDeleted, .roomMembershipRevoked, .roomKeyRotated,
             .roomMemberMuted, .roomOwnerOnlyChanged, .roomRenamed,
             .uinAuctionStarted, .uinAuctionBid, .uinAuctionEnded, .uinAuctionOutbid,
             .tradeReceived, .tradeAccepted, .tradeDeclined, .tradeCancelled,
             .crashRoundBetting, .crashRoundRunning, .crashRoundEnd,
             .crashCashout, .crashBetPlaced,
             .storyPosted, .storyDeleted,
             .marketplaceListingSold,
             .uinMarketplaceListingSold:
            // Owned by their respective services that subscribe directly.
            break
        }
    }

}
