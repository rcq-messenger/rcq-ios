import Combine
import Foundation
import os.log

@MainActor
final class ContactService: ObservableObject {
    static let shared = ContactService()

    private static let log = OSLog(subsystem: "app.rcq.client", category: "ContactService")

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var pendingRequests: [PendingRequest] = []
    /// Requests WE sent that are still pending or were declined by the
    /// recipient (declined surface here because no push tells the sender).
    @Published private(set) var outgoingRequests: [OutgoingRequest] = []

    struct PendingRequest: Identifiable, Codable, Hashable {
        let id: Int
        let from_uin: Int
        let nickname: String
        let state: String
    }

    struct OutgoingRequest: Identifiable, Codable, Hashable {
        let id: Int
        let to_uin: Int
        let nickname: String
        let state: String  // pending | declined
    }

    private init() {}

    func refresh() async {
        if PanicPINService.shared.isDecoy { return }
        do {
            var list: [Contact] = try await APIClient.shared.request("GET", "/contacts")
            // Server doesn't track per-client unread counts (privacy
            // posture: unread is a local UI concern). Fold persisted
            // counters back into the freshly-decoded contact rows so
            // a cold launch lands with badges intact.
            let persisted = UnreadStore.shared.allPeerCounts
            for i in list.indices {
                if let n = persisted[list[i].uin], n > 0 {
                    list[i].unread = n
                }
            }
            self.contacts = list
            let pending: [PendingRequest] = try await APIClient.shared.request("GET", "/contacts/pending")
            self.pendingRequests = pending
            let outgoing: [OutgoingRequest] = try await APIClient.shared.request("GET", "/contacts/outgoing")
            self.outgoingRequests = outgoing
            // Push the latest uin → nickname map into the App Group
            // cache so the NSE can resolve sender names on push.
            var nickMap: [Int: String] = [:]
            for c in list { nickMap[c.uin] = c.nickname }
            NicknameCache.setAll(nickMap)
            // Any UIN we'd previously dropped via `remove()` but that's
            // now back in our contact list means a re-add happened.
            // Clearing the filter so their future messages render
            // again — otherwise the recipient gets locally-filtered
            // sealed envelopes forever after a single remove + re-add
            // round-trip and "iPhone → sim doesn't arrive" becomes
            // permanent until reinstall.
            for c in list { RemovedContactsStore.shared.remove(c.uin) }
        } catch {
            // Keep current cached state on failure.
        }
    }

    func updatePresence(uin: Int, status: UserStatus, statusMessage: String?) {
        guard let idx = contacts.firstIndex(where: { $0.uin == uin }) else { return }
        contacts[idx].status = status
        contacts[idx].statusMessage = statusMessage
    }

    func appendPendingRequest(_ req: PendingRequest) {
        if !pendingRequests.contains(where: { $0.id == req.id }) {
            pendingRequests.append(req)
        }
    }

    func sendAddRequest(to uin: Int) async throws {
        struct Body: Encodable { let to_uin: Int }
        let _: EmptyResponse = try await APIClient.shared.request(
            "POST", "/contacts/request", body: Body(to_uin: uin)
        )
        // Re-add intent. Clear the local "I removed them" filter so
        // their messages stop being dropped on ingest even before the
        // server's auto-accept WS event lands.
        RemovedContactsStore.shared.remove(uin)
        await refresh()
    }

    /// Cancel/revoke a request we sent (state pending), or dismiss a
    /// declined one out of our outgoing list.
    func cancelOutgoing(toUIN: Int) async throws {
        let _: EmptyResponse = try await APIClient.shared.request(
            "DELETE", "/contacts/outgoing/\(toUIN)"
        )
        outgoingRequests.removeAll { $0.to_uin == toUIN }
    }

    func respond(requestID: Int, accept: Bool) async throws {
        struct Body: Encodable { let request_id: Int; let accept: Bool }
        let _: EmptyResponse = try await APIClient.shared.request(
            "POST", "/contacts/respond", body: Body(request_id: requestID, accept: accept)
        )
        pendingRequests.removeAll { $0.id == requestID }
        if accept { await refresh() }
    }

    func remove(_ uin: Int) async throws {
        let _: EmptyResponse = try await APIClient.shared.request(
            "DELETE", "/contacts/\(uin)"
        )
        contacts.removeAll { $0.uin == uin }
        UnreadStore.shared.clearPeer(uin)
        // Drop any badge increment NSE may have pushed under this
        // UIN — otherwise the icon counter sticks at N even though
        // the thread is no longer reachable from the chat list.
        BadgeCounter.reset(threadKey: BadgeCounter.threadKey(peerUIN: uin))
        BadgeCounter.syncIcon()
        // Sealed sender means the server can't drop future messages
        // from this UIN — record it locally so MessageService and the
        // NSE silently filter them out.
        RemovedContactsStore.shared.add(uin)
    }

    /// Drop a UIN from the local cache only — used when the peer side
    /// initiated the removal (`contact_removed` WS event). We don't
    /// add to RemovedContactsStore here: the deleter, not the deleted,
    /// decides who to filter.
    func removeLocal(_ uin: Int) {
        contacts.removeAll { $0.uin == uin }
        UnreadStore.shared.clearPeer(uin)
        BadgeCounter.reset(threadKey: BadgeCounter.threadKey(peerUIN: uin))
        BadgeCounter.syncIcon()
    }

    /// Auto-surface an unknown sender so their messages appear in the
    /// chat list. Sealed sender + a removed/missing mutual contact
    /// row means messages from this UIN land in MessageStore but the
    /// chat-list cell never renders because the UI is contact-driven.
    /// This synthesizes a local Contact row from the peer's public
    /// profile so the thread surfaces without forcing a mutual handshake.
    /// Idempotent — bails fast if the contact already exists.
    func upsertStranger(uin: Int) async {
        if contacts.contains(where: { $0.uin == uin }) { return }
        if RemovedContactsStore.shared.contains(uin) { return }
        do {
            let p: UserProfile = try await APIClient.shared.request("GET", "/users/\(uin)/info")
            await MainActor.run {
                guard !self.contacts.contains(where: { $0.uin == uin }) else { return }
                let contact = Contact(
                    uin: p.uin,
                    nickname: p.nickname,
                    status: p.status,
                    statusMessage: p.statusMessage,
                    blocked: false,
                    identityKey: p.identityKey,
                    signingKey: p.signingKey,
                    signalIdentityKey: p.signalIdentityKey,
                    gender: nil,
                    unread: 0,
                    lastSeen: nil,
                )
                self.contacts.append(contact)
            }
        } catch {
            // Fall through silently — the message is still saved in
            // MessageStore. Worst case the thread just doesn't render
            // until the next refresh; tighter than crashing the path.
        }
    }

    func toggleBlock(_ uin: Int) async throws {
        struct Out: Decodable { let blocked: Bool }
        let out: Out = try await APIClient.shared.request("POST", "/contacts/\(uin)/block")
        if let idx = contacts.firstIndex(where: { $0.uin == uin }) {
            contacts[idx].blocked = out.blocked
        }
    }

    func incrementUnread(for uin: Int) {
        // Persist FIRST so the count survives even when the contact
        // isn't in our in-memory list yet (cold-launch push tap, or
        // the sender re-registered after our last contact-list
        // refresh and the new UIN hasn't been pulled). The contact
        // list refresh that lands later folds the persisted count
        // back into `contacts` via `applyPersistedUnread`.
        UnreadStore.shared.incrementPeer(uin)
        if let idx = contacts.firstIndex(where: { $0.uin == uin }) {
            contacts[idx].unread += 1
        } else {
            os_log("incrementUnread: unknown UIN %d — count persisted, awaiting contact refresh",
                   log: Self.log, type: .info, uin)
        }
    }

    func clearUnread(for uin: Int) {
        UnreadStore.shared.clearPeer(uin)
        BadgeCounter.reset(threadKey: BadgeCounter.threadKey(peerUIN: uin))
        BadgeCounter.syncIcon()
        guard let idx = contacts.firstIndex(where: { $0.uin == uin }) else { return }
        contacts[idx].unread = 0
    }

    /// Local cache reset used by the burn flow.
    func wipe() {
        contacts = []
        pendingRequests = []
        outgoingRequests = []
        UnreadStore.shared.wipeAll()
        BadgeCounter.resetAll()
        BadgeCounter.syncIcon()
    }

    func clearForDecoy() {
        contacts = []
        pendingRequests = []
        outgoingRequests = []
    }
}
