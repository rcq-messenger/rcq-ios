import Combine
import Foundation
import SwiftUI

/// Top-level state holder. Wires the WS event stream into services and surfaces
/// pending deep-link targets that views consume.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var booted: Bool = false
    @Published var bootError: String? = nil
    @Published var typingByUIN: [Int: Bool] = [:]
    @Published var pendingAddUIN: Int? = nil
    @Published var pendingOpenChatUIN: Int? = nil
    @Published var pendingOpenPending: Bool = false
    @Published var pendingOpenTrades: Bool = false

    func handle(deepLink url: URL) {
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
    }

    private var cancellables = Set<AnyCancellable>()
    private var typingTimers: [Int: Timer] = [:]

    private init() {
        WebSocketService.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    func boot(suggestedNickname: String? = nil) async {
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
            bootError = error.localizedDescription
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
        pendingOpenPending = false
        pendingOpenTrades = false
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
        pendingOpenPending = false
        pendingOpenTrades = false
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
            SoundService.shared.playIncoming(fromUIN: sender, thread: thread)
            let title: String
            let body: String
            switch thread {
            case .peer(let uin):
                ContactService.shared.incrementUnread(for: uin)
                let nickname = ContactService.shared.contacts.first(where: { $0.uin == uin })?.nickname ?? String(uin)
                title = nickname
                body = "New message"
            case .group(let id):
                GroupService.shared.incrementUnread(id)
                let groupName = GroupService.shared.find(id)?.name ?? "Group"
                title = groupName
                body = "New message"
            }
            NotificationService.shared.presentIfBackgrounded(
                title: title, body: body, threadKey: "\(thread.kindString)-\(thread.rawKey)"
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
