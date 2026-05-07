import Combine
import Foundation
import SwiftUI

/// Top-level state holder. Wires the WS event stream to the contact list, message store,
/// presence service and sounds. ViewModels read from this and the underlying services.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var booted: Bool = false
    @Published var bootError: String? = nil
    @Published var typingByUIN: [Int: Bool] = [:]
    /// Set when an `rcq://add/{uin}` deep link is opened. ContactListView observes
    /// and presents AddContactView pre-filled with this UIN.
    @Published var pendingAddUIN: Int? = nil
    /// Cross-screen request to open the chat with `uin`. Used by
    /// the trades list to surface a "go to chat" affordance from
    /// inside a sheet — sheets host their own NavigationStack and
    /// can't push onto the contact list's. ContactListView reads
    /// this and dismisses any open sheet, then appends the
    /// contact to its `path`.
    @Published var pendingOpenChatUIN: Int? = nil
    /// Tap on a "you have a contact request" push set this. The
    /// contact list flips its `showPending` flag and presents the
    /// PendingRequestsView sheet. Reset by ContactListView after
    /// it acts on the value (single-shot like `pendingOpenChatUIN`).
    @Published var pendingOpenPending: Bool = false
    /// Tap on a "you got a trade offer" push set this. ContactListView
    /// presents TradesListView (same sheet that `trades.freshIncoming`
    /// drives, but with no specific trade pre-selected — user lands
    /// on the list and picks the new offer themselves).
    @Published var pendingOpenTrades: Bool = false

    func handle(deepLink url: URL) {
        // Custom-scheme form: rcq://add/<uin>
        if url.scheme == "rcq", url.host == "add" {
            let uinStr = url.pathComponents.last ?? ""
            if let uin = Int(uinStr), uin > 0 {
                pendingAddUIN = uin
            }
            return
        }
        // Universal Link form: https://rcq.app/u/<uin> — what we share
        // from Settings now. Tap in Messages/Telegram/etc opens the app
        // directly when the AASA association resolves; falls back to
        // the web landing page otherwise.
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

            // Pull our own server-side state so PresenceService reflects the saved
            // status + status message instead of resetting them. The server's
            // `_on_connect` handler already promotes offline → online, so we don't
            // need to push setStatus(.online) ourselves — that previously wiped the
            // status_message because we sent it as nil.
            await syncOwnPresenceFromServer(uin: uin)
            // Eager catalog load — `StatusWithPet` resolves a kind_id
            // → asset_ref via `ItemsService.shared.catalog`. If the
            // catalog isn't loaded by the time the contact list /
            // chat header / group info first paints (a peer with an
            // equipped pet appearing before the user ever opens
            // their own Inventory), the pet glyph silently no-ops
            // and only the bare status icon renders.
            await ItemsService.shared.refreshCatalog()
            // Eager inventory load too — own equipped pet on the
            // contact-list header reads `items.items[]` to find the
            // currently-equipped pet_companion. If `items[]` is
            // empty (lazy via InventoryView's `.task`), the header
            // shows a bare status until the user happens to open
            // Inventory once. Cheap GET — single response with the
            // user's items + wallet.
            await ItemsService.shared.refreshInventory()
            await ContactService.shared.refresh()
            await GroupService.shared.refresh()
            await MessageService.shared.fetchOfflineQueue()
            await NotificationService.shared.requestAuthorization()
            // If we already had an APNs token from a previous launch (the
            // adapter handed it to NotificationService before auth
            // completed), now's the time to ship it to the backend under
            // the freshly authenticated session.
            await NotificationService.shared.refreshTokenSubmission()
            // Pull per-category push toggles + muted-uin list. Soft-fail
            // to defaults on network blip — UI binds against the in-
            // memory copy and the next refresh re-syncs.
            await NotificationPrefsService.shared.refresh()
            // Same for the VoIP-push token — PushKit hands it to us
            // asynchronously and possibly before login finishes.
            await VoIPPushService.shared.refreshTokenSubmission()

            booted = true
        } catch {
            bootError = error.localizedDescription
        }
    }

    // MARK: - migration

    /// Result of an account migration attempt. Either the server
    /// granted the new UIN + token, or returned a typed failure the
    /// settings sheet surfaces inline. We deliberately don't surface
    /// the `cooldown.remaining_seconds` payload to the UI for v1 —
    /// the user-facing copy just says "try again later".
    enum MigrationResult: Equatable {
        case success(newUIN: Int)
        case insufficientTokens(required: Int, have: Int)
        case cooldown
        case other(String)
    }

    /// Set during the brief window between firing `POST /account/migrate`
    /// and finishing the local keychain swap + reboot. The server-side
    /// migration broadcasts `account_burned` to every WS connected
    /// under the OLD uin (multi-device users need to know their old
    /// account is gone and re-bootstrap). The catch: the migrating
    /// device IS one of those WS connections, so it would receive the
    /// event and run the full burn-and-fresh-register flow, clobbering
    /// the migration mid-flight (lost nickname, no contacts, no items
    /// — the exact bug a tester hit in v1). This flag tells the
    /// `.accountBurned` event handler to skip the burn for THIS
    /// session; multi-device users on other phones still react.
    private var migratingAccount: Bool = false

    /// Migrate the current account to a freshly-allocated UIN. Server
    /// keeps profile + contacts + items + wallet (minus the 99-token
    /// fee) and re-keys every FK. Locally we wipe per-uin caches and
    /// re-boot from the new identity — the client behaves as if it
    /// just relaunched, except it lands authenticated as `new_uin`.
    ///
    /// The user's identity_key + signing_key are reused server-side so
    /// peers' libsignal-stage-2 sessions to us survive intact. Stage-3
    /// material is dropped on both ends — peers will re-handshake on
    /// their next message, falling back to v=1 ECIES until the new
    /// stage-3 bundle uploads.
    func migrateAccount(targetUIN: Int? = nil) async -> MigrationResult {
        struct Body: Encodable { let target_uin: Int? }
        struct MigrateOut: Decodable {
            let new_uin: Int
            let token: String
        }
        let resp: MigrateOut
        // Set the suppression flag BEFORE the network call so an
        // early-arriving `account_burned` (server fires it the moment
        // the row is deleted, before the HTTP response unwinds) can't
        // trigger the burn handler ahead of us.
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

        // Local reset — same shape as `burnAccount` minus the
        // identity-keys wipe (server reused them under the new
        // UIN) and minus the deleteServerAccount call (the migrate
        // endpoint already deleted the old User row).
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
        // Stage-3 sessions go away — peers re-handshake on next msg.
        SignalProtocolDB.shared.wipe()
        PresenceService.shared.status = .online
        PresenceService.shared.statusMessage = nil
        typingByUIN = [:]
        pendingOpenChatUIN = nil
        pendingOpenPending = false
        pendingOpenTrades = false
        pendingAddUIN = nil

        // Swap the keychain over to the new identity. Identity priv
        // keys + nickname stay put (server reused both).
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

        // Force-refresh wallet/items snapshot under the NEW uin's
        // token. boot() already calls refreshInventory() but the
        // defensive max() reconciliation in ItemsService preserves
        // the stale-high cached pre-deduction balance — so the user
        // saw the OLD pre-migration tokens until the next foreground.
        // forceWallet: true bypasses max() and trusts the server.
        await ItemsService.shared.refreshInventory(forceWallet: true)

        // Reboot done — fresh `account_burned` events from this point
        // forward should be honoured normally (e.g. user burns the
        // newly-migrated account from another device).
        migratingAccount = false
        return .success(newUIN: resp.new_uin)
    }

    /// Decode the typed `{ "code": "insufficient_tokens", "required": N,
    /// "have": M }` payload our migrate endpoint returns on 402. Returns
    /// nil if the body doesn't match — caller falls back to a generic
    /// error string.
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

    /// "Burn account" — user-initiated nuclear reset. Tells the server to delete
    /// our account, wipes every shred of local state, then re-runs `boot()`,
    /// which mints a fresh identity (new UIN, new keys). The user lands on the
    /// boot splash for a moment and comes back as a brand-new person.
    func burnAccount() async {
        await AuthService.shared.deleteServerAccount()
        WebSocketService.shared.disconnect()

        // Local state — caches, store, message DB, presence.
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

        // Identity material — Keychain + API token.
        await AuthService.shared.wipeLocalIdentity()

        // Flip back to the splash and re-run boot. AuthService.bootstrapIfNeeded
        // sees no Keychain entries and registers afresh.
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
            // Soft-fail: keep whatever local defaults the PresenceService had.
        }
    }

    private func handle(_ event: WebSocketService.Event) {
        switch event {
        case .opened:
            // Drain the server-side offline queue every time the
            // socket comes up — initial connect AND every auto-
            // reconnect after a drop. Without this, messages that
            // landed while the iOS WS was briefly down (cellular
            // hiccup, app backgrounded, contact-add timing) sat in
            // the queue until the user manually relaunched the
            // app. Symptom the user saw: "added a peer, neither
            // side sees messages until restart" — that was a WS
            // drop during the contact-add round-trip leaving a
            // queue that nothing drained on reconnect.
            Task { await MessageService.shared.fetchOfflineQueue() }

        case .closed:
            // Schedule a reconnect attempt — naive fixed delay is enough for now.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let uin = AuthService.shared.ownUIN,
                      let token = KeychainStore.string(KeychainStore.Keys.token) else { return }
                let baseURL = APIClient.shared.baseURL
                WebSocketService.shared.connect(uin: uin, token: token, baseURL: baseURL)
            }

        case .accountBurned:
            // Server burned this account from another session (e.g.
            // user pressed "Burn" on chat.rcq.app while iOS was open
            // here). Run the same local cleanup the user-initiated
            // burn does — `deleteServerAccount` 404s, which is fine
            // because the server already removed the row before
            // sending us this event. UI swaps to onboarding via the
            // booted/ownUIN bindings.
            //
            // Suppression: the migrate-account flow ALSO triggers
            // `account_burned` server-side (multi-device clients
            // need to drop their stale session). For the migrating
            // device itself, running burnAccount here would clobber
            // the migration flow mid-flight and the user would land
            // on a fresh re-registered account. The flag is set
            // around the migrate POST + reboot window.
            if migratingAccount { return }
            Task { await self.burnAccount() }

        case .presence(let uin, let status, let message):
            let wasOnline = ContactService.shared.contacts.first(where: { $0.uin == uin })?.status != .offline
            ContactService.shared.updatePresence(uin: uin, status: status, statusMessage: message)
            // Group member rows mirror the same presence — update them so the
            // status icons in GroupInfoView track live, like the contact list.
            GroupService.shared.updateMemberPresence(uin: uin, status: status)
            if status == .offline && wasOnline {
                SoundService.shared.play(.contactOffline, thread: .peer(uin: uin))
            } else if status != .offline && !wasOnline {
                SoundService.shared.play(.contactOnline, thread: .peer(uin: uin))
            }

        case .envelope(let env):
            guard let outcome = MessageService.shared.ingest(envelope: env) else { return }
            // Side effects only for actually-new content. The same
            // envelope can arrive twice — once via the live WS or
            // server-side `_on_connect` flush, once via the client's
            // HTTP `/messages/queue` drain — and `MessageStore.append`
            // dedupes by UUID. Without this guard each duplicate
            // would still bump the badge and play a sound, which
            // produced "badges higher than real unread" reports.
            guard outcome.isNewContent else { return }
            let thread = outcome.thread
            // Per-contact sound override only applies to 1:1
            // threads — group senders are heterogeneous and a
            // per-peer assignment doesn't carry useful semantics
            // there. For groups we keep the default cue.
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

		case .hoodMessage, .hoodCount, .hoodDelete, .hoodReaction:
            // HoodChatService subscribes to the WS event stream
            // directly, same pattern as RandomChatService — keeps
            // AppState's switch focused on the surfaces it owns.
            break

        case .randomMatch, .randomEnd:
            // Handled directly by RandomChatService (it subscribes to the
            // same event stream). AppState stays out of random-chat state.
            break

        case .callOffer, .callAnswer, .callIce, .callEnd,
             .callRenegotiate, .callRenegotiateAnswer, .callRenegotiateDecline:
            // Same arrangement as random-chat — CallService subscribes to
            // the WS event stream itself, so AppState doesn't need to know.
            break

        case .roomEnterRejected, .roomRoster, .roomMemberEntered, .roomMemberLeft,
             .roomOffer, .roomAnswer, .roomIce, .roomSpeaking,
             .roomKicked, .roomDeleted, .roomMembershipRevoked, .roomKeyRotated,
             .roomMemberMuted, .roomOwnerOnlyChanged, .roomRenamed:
            // AudioRoomService subscribes to the same stream — same
            // arrangement as the rest. AppState stays out.
            break

        case .uinAuctionStarted, .uinAuctionBid, .uinAuctionEnded, .uinAuctionOutbid:
            // UinAuctionService subscribes directly to these.
            break

        case .tradeReceived, .tradeAccepted, .tradeDeclined, .tradeCancelled:
            // TradesService subscribes to the same stream and owns
            // all trade lifecycle state. AppState stays out.
            break

        case .crashRoundBetting, .crashRoundRunning, .crashRoundEnd,
             .crashCashout, .crashBetPlaced:
            // CrashService owns these — same arrangement as
            // RandomChatService / TradesService / CallService.
            break

        case .storyPosted, .storyDeleted:
            // StoryService subscribes directly and re-fetches the
            // feed on either nudge. AppState stays out.
            break

        case .marketplaceListingSold,
             .uinMarketplaceListingSold:
            // MarketService subscribes directly — same pattern.
            break
        }
    }

}
