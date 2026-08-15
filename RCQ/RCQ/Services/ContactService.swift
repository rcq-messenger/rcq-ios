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
            // Hide contacts I've locally deleted, even if the server roster still
            // returns them (a delete can linger one-directionally / until the
            // peer drops their edge). Without this they reappeared on every
            // launch (#8). They're un-filtered only on an EXPLICIT re-add
            // (sendAddRequest / accepting their request).
            list.removeAll { RemovedContactsStore.shared.contains($0.uin) }
            // Federation (F2): merge local cross-island contacts (peers on other
            // islands — not in the server roster) so they show + open a chat.
            let cross = CrossIslandStore.shared.all().filter { ci in !list.contains { $0.uin == ci.uin } }
            self.contacts = list + cross
            let pending: [PendingRequest] = try await APIClient.shared.request("GET", "/contacts/pending")
            self.pendingRequests = pending
            let outgoing: [OutgoingRequest] = try await APIClient.shared.request("GET", "/contacts/outgoing")
            self.outgoingRequests = outgoing
            // Push the latest uin → nickname map into the App Group
            // cache so the NSE can resolve sender names on push.
            //
            // CROSS-ISLAND rows go in too. Built from `/contacts` alone, this
            // map had no entry for a peer on another island (they are not in the
            // server roster by construction), so their message notification
            // showed a bare number while the app itself showed their name. Local
            // rows are written last so a uin that collides across islands
            // resolves to the LOCAL contact — the same precedence the merged
            // list uses. Aliases win over both, because that is what the user
            // chose to call this person everywhere else in the UI.
            var nickMap: [Int: String] = [:]
            for c in cross {
                nickMap[c.uin] = ContactAliasStore.shared.displayName(for: c.uin, fallback: c.nickname)
            }
            for c in list {
                nickMap[c.uin] = ContactAliasStore.shared.displayName(for: c.uin, fallback: c.nickname)
            }
            NicknameCache.setAll(nickMap)
            // (Removed: the blanket "un-remove every roster UIN" that used to live
            // here — it resurrected contacts the user had deliberately deleted
            // every launch, #8. Re-adds now clear the filter explicitly in
            // sendAddRequest() and respond(accept:), and deleted-but-lingering
            // contacts are filtered out of `list` above.)
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

    /// §5f: which contactreq (if any) the add deposits to the peer's island.
    /// `.request` for a fresh add (QR, uin@host, a foreign group member),
    /// `.accept` when we're accepting a request they already sent us, and `nil`
    /// when the add is itself the RESULT of an inbound envelope (their
    /// `act:"accept"` landing here) — depositing then would loop forever.
    enum CrossIslandAnnounce: String { case request, accept }

    /// What `addCrossIslandContact` actually managed to do. `added` is the local
    /// row (the old Bool); `announced` is whether the §5f contactreq reached the
    /// peer's island. They differ when the island is unreachable, and the UI must
    /// not claim "request sent" in that case — claiming it was the original bug.
    struct CrossIslandAddOutcome {
        let added: Bool
        let announced: Bool
    }

    /// Federation (F2): add a cross-island contact `uin@host` — fetch their
    /// island's open key card, store it locally, and merge it into the list so
    /// the normal chat-open + send flow works. Returns true on success.
    @discardableResult
    func addCrossIslandContact(uin: Int, host: String) async -> Bool {
        await addCrossIslandContact(uin: uin, host: host, announce: .request).added
    }

    /// §5f-aware add. Writes the SAME local row as before (unchanged — the
    /// pinned identity/signing keys are the anti-impersonation anchor and stay
    /// exactly where the key-card fetch puts them), then deposits a
    /// `contactreq` to the peer's island so the add is no longer one-sided.
    func addCrossIslandContact(
        uin: Int, host: String,
        announce: CrossIslandAnnounce?, note: String? = nil
    ) async -> CrossIslandAddOutcome {
        // A neighbour on our OWN island goes through the ordinary contact
        // request, not the federation path. This happens when the address was
        // written out in full (`uin@api.rcq.app`) and when a peer's envelope
        // was stamped with a host we serve under another name (the CF front) —
        // routing those here filed a second, roster-shadowing copy of somebody
        // who was never actually on another island.
        if Multihome.isOwnHost(host) {
            do {
                try await sendAddRequest(to: uin)
                return CrossIslandAddOutcome(added: true, announced: true)
            } catch {
                // A duplicate (409) still means the peer holds a request from us.
                return CrossIslandAddOutcome(added: true, announced: true)
            }
        }
        guard let card = await CrossIslandSender.fetchCard(host: host, uin: uin) else {
            return CrossIslandAddOutcome(added: false, announced: false)
        }
        // Presence isn't tracked across islands, so don't fake `.online` — show
        // offline/unknown rather than a green dot we can't back up.
        let nick = (card.nickname?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "\(uin)@\(host)"
        var c = Contact(
            uin: uin, nickname: nick, status: .offline, statusMessage: card.status_message,
            blocked: false, identityKey: card.identity_key, signingKey: card.signing_key,
            signalIdentityKey: card.signal_identity_key, gender: card.gender, unread: 0, lastSeen: nil
        )
        c.host = host
        CrossIslandStore.shared.save(c)
        if !contacts.contains(where: { $0.uin == uin }) { contacts.append(c) }
        // §5f — the half that was missing. Deposit the contactreq to the peer's
        // PRIMARY island so they actually learn about us. Never touches the row
        // above; a failed deposit leaves the local add intact and the caller
        // reports honestly that nothing was sent.
        guard let announce else { return CrossIslandAddOutcome(added: true, announced: false) }
        let sent = await CrossIslandSender.depositContactReq(
            act: announce.rawValue, uin: uin, host: host,
            identityKey: card.identity_key, signingKey: card.signing_key, note: note
        )
        // §5e first-contact push. On `accept` the relationship is mutual as of
        // right now, so send our CURRENT name and picture — otherwise they hold
        // whatever their key-card snapshot said and nothing would ever refresh
        // it. A `request` carries our name inside the contactreq already and has
        // no accepted relationship yet, which is the audience §5e is limited to.
        if sent, announce == .accept {
            await CrossIslandSender.sendProfile(to: c)
        }
        return CrossIslandAddOutcome(added: true, announced: sent)
    }

    /// §5e receive: a cross-island row's display fields were just refreshed on
    /// disk — mirror them into the published list so open screens redraw, and
    /// into the App Group nickname cache so the NEXT push from this person is
    /// titled with their new name (the push path has no live session and reads
    /// only the stored snapshot).
    ///
    /// Never touches a same-island row: per-island uins collide, and the local
    /// contact owns that number here.
    func applyCrossIslandProfile(_ updated: Contact) {
        if let idx = contacts.firstIndex(where: { $0.uin == updated.uin && $0.host != nil }) {
            contacts[idx].nickname = updated.nickname
            contacts[idx].avatarMediaID = updated.avatarMediaID
            contacts[idx].avatarMediaKey = updated.avatarMediaKey
        }
        guard !contacts.contains(where: { $0.uin == updated.uin && $0.host == nil }) else { return }
        NicknameCache.upsert(
            uin: updated.uin,
            nickname: ContactAliasStore.shared.displayName(for: updated.uin, fallback: updated.nickname)
        )
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
        let fromUIN = pendingRequests.first { $0.id == requestID }?.from_uin
        pendingRequests.removeAll { $0.id == requestID }
        if accept {
            // Explicit re-add: if I'd previously deleted this UIN, clear the
            // local removal filter so their messages render again. (refresh()
            // no longer blanket-clears the filter — that resurrected contacts I
            // deliberately deleted, #8.)
            if let u = fromUIN { RemovedContactsStore.shared.remove(u) }
            await refresh()
        }
    }

    func remove(_ uin: Int) async throws {
        // Cross-island contacts live ONLY in CrossIslandStore (on-device), not
        // in the server-side /contacts list, so a DELETE /contacts/{uin} did
        // nothing and they couldn't be removed (founder report). Remove them
        // locally instead.
        if let c = contacts.first(where: { $0.uin == uin }), let host = c.host {
            CrossIslandStore.shared.remove(uin: uin, host: host)
            contacts.removeAll { $0.uin == uin }
            UnreadStore.shared.clearPeer(uin)
            BadgeCounter.reset(threadKey: BadgeCounter.threadKey(peerUIN: uin))
            BadgeCounter.syncIcon()
            RemovedContactsStore.shared.add(uin)
            return
        }
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
        // The local store is the source of truth: it works for non-contacts /
        // strangers (the server endpoint 404s for those) and drives ingest
        // filtering + the Blocked list. Flip it first, then best-effort sync the
        // server's contact `blocked` flag (the endpoint toggles it for real
        // contacts; 404s for strangers, swallowed).
        let nowBlocked = !BlockedContactsStore.shared.contains(uin)
        BlockedContactsStore.shared.set(uin, blocked: nowBlocked)
        if let idx = contacts.firstIndex(where: { $0.uin == uin }) {
            contacts[idx].blocked = nowBlocked
        }
        struct Out: Decodable { let blocked: Bool }
        let _: Out? = try? await APIClient.shared.request("POST", "/contacts/\(uin)/block")
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

    /// Populate the roster of a decoy session from the seeded conversations.
    /// These uins are synthetic (see `DecoyContactRecord`) and exist on no
    /// server, so `refresh()` deliberately returns early in a decoy session and
    /// never overwrites them. Empty keys / offline status: nothing here can be
    /// messaged, and an empty decoy is the tell the seeding exists to remove.
    func applyDecoySeed(_ rows: [DecoyContactRecord]) {
        contacts = rows.map { row in
            Contact(
                uin: row.uin,
                nickname: row.nickname,
                status: .offline,
                statusMessage: nil,
                blocked: false,
                identityKey: "",
                signingKey: ""
            )
        }
        pendingRequests = []
        outgoingRequests = []
    }
}
