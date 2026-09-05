import Foundation

@MainActor
final class GroupService: ObservableObject {
    static let shared = GroupService()

    @Published private(set) var groups: [RCQGroup] = []
    /// Unread count per group. Mirrors what `UnreadStore` persists so
    /// the in-memory dictionary stays cheap to read from SwiftUI
    /// bindings; UnreadStore is the source of truth and survives
    /// app launches.
    @Published private(set) var unread: [Int: Int] = [:]
    /// Room rules per own-island group id, see `RoomRules`. Filled from the
    /// very same payloads the group list and the PATCH replies already carry,
    /// so it costs no extra round trip.
    @Published private(set) var roomRules: [Int: RoomRules] = [:]

    /// The rules of a room, with the permissive defaults for a group nothing
    /// has been fetched for yet (an island that predates the fields answers
    /// exactly the same way).
    func rules(_ groupID: Int) -> RoomRules { roomRules[groupID] ?? RoomRules() }

    /// The three owner-only levers `GroupPatchIn` calls `links_allowed`,
    /// `files_allowed` and `slowmode_sec`: what may be posted in the room and
    /// how often. `post_policy` (read-only room) and these together are the
    /// "freeze" controls; the desktop has had them since the group-settings
    /// modal shipped, iOS had none of them.
    ///
    /// ⚠ Kept BESIDE the group rather than on it: `RCQGroup` lives in a file
    /// this change does not own. Folding `linksAllowed` / `filesAllowed` /
    /// `slowmodeSec` into the model later is a drop-in replacement: the wire
    /// keys and the defaults are the ones written here.
    struct RoomRules: Equatable, Decodable {
        var linksAllowed: Bool = true
        var filesAllowed: Bool = true
        var slowmodeSec: Int = 0
        /// Anti-spam age floor, hours (0 = off): an account younger than
        /// this reads but cannot post. Owner-set; the island enforces it.
        var minAccountAgeHours: Int = 0

        /// The steps the island accepts (`_SLOWMODE_STEPS` in `groups.py`).
        /// A fixed menu rather than a free integer so every client draws the
        /// same picker and a room reads the same on all of them.
        static let slowmodeSteps = [0, 5, 10, 30, 60]
        /// Same story for the age floor (`_AGE_GATE_STEPS`): off, 1h, 6h,
        /// 24h, 3 days, a week, 30 days.
        static let ageGateSteps = [0, 1, 6, 24, 72, 168, 720]

        enum CodingKeys: String, CodingKey {
            case linksAllowed = "links_allowed"
            case filesAllowed = "files_allowed"
            case slowmodeSec = "slowmode_sec"
            case minAccountAgeHours = "min_account_age_hours"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // An older island sends none of these. "Everything allowed,
            // no slowmode, no age floor" is exactly how such a room behaves.
            self.linksAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .linksAllowed)) ?? true
            self.filesAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .filesAllowed)) ?? true
            self.slowmodeSec = (try? c.decodeIfPresent(Int.self, forKey: .slowmodeSec)) ?? 0
            self.minAccountAgeHours = (try? c.decodeIfPresent(Int.self, forKey: .minAccountAgeHours)) ?? 0
        }
    }

    /// One `GroupOut` read twice: once as the model, once as the rules the
    /// same payload carries. Every group response goes through this, so the
    /// rules map is never a fetch of its own.
    private struct GroupWithRules: Decodable {
        let group: RCQGroup
        let rules: RoomRules

        init(from decoder: Decoder) throws {
            self.group = try RCQGroup(from: decoder)
            self.rules = try RoomRules(from: decoder)
        }
    }

    private init() {
        // Hydrate from the persisted store on first access so the
        // contact-list group rows show their badges before any
        // refresh has run.
        self.unread = UnreadStore.shared.allGroupCounts
    }

    func incrementUnread(_ groupID: Int) {
        UnreadStore.shared.incrementGroup(groupID)
        unread[groupID, default: 0] += 1
    }

    /// A page of unread bumps, applied in one pass. See
    /// `ContactService.applyUnreadDeltas`.
    func applyUnreadDeltas(_ deltas: [Int: Int]) {
        guard !deltas.isEmpty else { return }
        UnreadStore.shared.incrementGroups(deltas)
        var next = unread
        for (id, delta) in deltas where delta > 0 {
            next[id, default: 0] += delta
        }
        unread = next
    }

    func clearUnread(_ groupID: Int) {
        UnreadStore.shared.clearGroup(groupID)
        BadgeCounter.reset(threadKey: BadgeCounter.threadKey(groupID: groupID))
        BadgeCounter.syncIcon()
        unread[groupID] = 0
    }

    /// One gsknack per room per six hours when its sealed blob exists and our
    /// key (if any) does not open it (stage 6 phase 2). The reply lands as a
    /// gskey on the ordinary sealed path.
    private var askedRoomKeyAt: [Int: Date] = [:]

    private func maybeAskRoomKey(_ g: RCQGroup) {
        guard let blob = g.stateBlob else { return }
        if let held = RoomKeyStore.shared.key(g.id), GroupStateSeal.open(blob, keyB64: held.key) != nil { return }
        if let last = askedRoomKeyAt[g.id], Date().timeIntervalSince(last) < 6 * 3600 { return }
        askedRoomKeyAt[g.id] = Date()
        guard let owner = g.members.first(where: { $0.uin == g.ownerUIN }), !owner.identityKey.isEmpty else { return }
        Task { await MessageService.shared.sendRoomKeyAsk(gid: g.id, to: owner) }
    }

    /// Paint the group list from disk before the network is asked (see
    /// `RosterSnapshot`). Called from `AppState.doBoot`, never from `init`.
    @discardableResult
    func hydrateFromSnapshot() -> Bool {
        if PanicPINService.shared.isDecoy { return false }
        return applySnapshot(RosterSnapshot.load(.groups, as: [RCQGroup].self))
    }

    /// The main-actor half of hydration; the decode happened wherever the
    /// caller ran it (doBoot: a detached task - `RosterSnapshot.loadOffMain`).
    @discardableResult
    func applySnapshot(_ list: [RCQGroup]?) -> Bool {
        guard let list, !list.isEmpty else { return false }
        groups = list
        unread = UnreadStore.shared.allGroupCounts
        return true
    }

    /// One fetch at a time; the second caller awaits the first (the chat
    /// list's `.task` and the boot's catch-up ask within the same frame).
    private var refreshInFlight: Task<Void, Never>?
    private var rosterEpoch = 0
    /// The account the list belongs to; see ContactService.
    private var rosterAccount: UUID?
    /// True once a live `/groups` answer landed this session. Until then
    /// there is nothing to write, and after it an EMPTY list is written like
    /// any other: a user who left their last group must not find it back on
    /// the next cold start.
    private var groupsLoaded = false

    private var wantsFollowUp = false

    /// See `ContactService.refresh(joinInFlight:)`.
    func refresh(joinInFlight: Bool = false) async {
        guard AppState.shared.networkReady else { return }
        if let running = refreshInFlight {
            if joinInFlight {
                await running.value
                return
            }
            wantsFollowUp = true
            await running.value
            if !wantsFollowUp {
                if let next = refreshInFlight { await next.value }
                return
            }
        }
        wantsFollowUp = false
        let epoch = rosterEpoch
        let account = AccountManager.shared.activeAccountID
        let task = Task { @MainActor in await self.refreshNow(epoch: epoch, account: account) }
        refreshInFlight = task
        await task.value
        if refreshInFlight == task { refreshInFlight = nil }
    }

    /// The own-island groups as they stand, to disk. Not the foreign ones:
    /// `host` is not part of a group's wire shape, so a cross-island group
    /// would come back as an own-island one under a negative alias id; they
    /// are re-fetched from their islands by the next refresh. Without the
    /// rosters either (fetched per group on demand; the beta group's alone
    /// would be the size of the file).
    func saveSnapshot() {
        guard groupsLoaded else { return }
        let own = groups.filter { $0.host == nil }.map { g -> RCQGroup in var l = g; l.members = []; return l }
        RosterSnapshot.save(own, as: .groups, accountID: rosterAccount)
    }

    private func refreshNow(epoch: Int, account: UUID?) async {
        if PanicPINService.shared.isDecoy { return }
        do {
            // Without the roster: a chat-list row wants a name, a picture and a
            // count, and the roster is the expensive half — every member with
            // two base64 keys, which on the beta group is a couple of hundred
            // kilobytes on the boot path, on every poll. It is fetched per
            // group, on demand, by `ensureRoster`.
            let rows: [GroupWithRules] = try await APIClient.shared.request(
                "GET", "/groups", query: ["members": "0"]
            )
            let list = rows.map(\.group)
            guard epoch == rosterEpoch, !PanicPINService.shared.isLocked else { return }
            // §5c: groups joined on OTHER islands, fetched with the guest creds;
            // ids rewritten to the local alias + host stamped. Per-island
            // failures degrade to "no groups from there" — never block the own
            // list (the 30s drain refreshes expired guest creds).
            // The host can be a visited/guest island OR one of our BACKUP islands
            // (multihome). A group on a backup island MUST be listed here too or
            // it shows message-only with no name/roster ("Группа / 0 участников").
            // Dedup hosts (one can be both).
            let ownUIN = AuthService.shared.ownUIN
            var foreign: [RCQGroup] = []
            var seenHosts = Set<String>()
            for v in VisitedIslandsStore.shared.list() where seenHosts.insert(v.host.lowercased()).inserted {
                foreign += await CrossIslandGroups.guestGroups(host: v.host, ownUIN: ownUIN)
            }
            if let me = ownUIN {
                for h in MultihomeStore.shared.list(ownUin: me) where seenHosts.insert(h.host.lowercased()).inserted {
                    foreign += await CrossIslandGroups.guestGroups(host: h.host, ownUIN: ownUIN)
                }
            }
            // Keep a roster we already paid for rather than dropping it back to
            // empty on every poll.
            let known = Dictionary(self.groups.map { ($0.id, $0.members) }, uniquingKeysWith: { a, _ in a })
            let own = list.map { g -> RCQGroup in
                guard g.members.isEmpty, let cached = known[g.id], !cached.isEmpty else { return g }
                var merged = g
                merged.members = cached
                return merged
            }
            guard epoch == rosterEpoch, account == AccountManager.shared.activeAccountID,
                  !PanicPINService.shared.isLocked else { return }
            // Stage 6 phase 2: rooms we hold the key for render their SEALED
            // identity; everyone else gets the columns unchanged. A blob we
            // cannot open earns one throttled ask toward the owner.
            self.groups = (own + foreign).map { g in
                let overlaid = GroupStateSeal.overlay(g, keyB64: RoomKeyStore.shared.key(g.id)?.key)
                self.maybeAskRoomKey(g)
                return overlaid
            }
            for row in rows { self.roomRules[row.group.id] = row.rules }
            self.rosterAccount = account
            self.groupsLoaded = true
            saveSnapshot()
            // Mirror id → name into the App Group so the NSE can title a
            // group-message push with the group's name (not just the sender).
            GroupNameCache.setAll(Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
            // Re-sync from the persisted store in case background
            // pushes mutated it while we were offline.
            self.unread = UnreadStore.shared.allGroupCounts
        } catch {
            // Soft-fail: keep cache.
        }
    }

    func create(name: String, memberUINs: [Int]) async throws -> RCQGroup {
        struct Body: Encodable { let name: String; let member_uins: [Int] }
        let row: GroupWithRules = try await APIClient.shared.request(
            "POST", "/groups", body: Body(name: name, member_uins: memberUINs)
        )
        roomRules[row.group.id] = row.rules
        upsert(row.group)
        noteMembershipBegan()
        return row.group
    }

    /// Stage 5: a room this account just entered has its log cursor seeded
    /// at the head by the island itself; one log fetch right away is the
    /// cheap second line, so the cursor exists on this device's side too
    /// before anyone posts and a first read of the room after a post can
    /// never start past it. Idempotent, and a no-op on an island without
    /// the room log.
    private func noteMembershipBegan() {
        Task { await MessageService.shared.fetchGroupLog() }
    }

    func reload(_ groupID: Int) async throws -> RCQGroup {
        let row: GroupWithRules = try await APIClient.shared.request("GET", "/groups/\(groupID)")
        roomRules[groupID] = row.rules
        upsert(row.group)
        return row.group
    }

    /// The rules of every own-island room, without the rosters. The list poll
    /// fills the same map for free; this is the explicit ask for the one screen
    /// that must not draw a stale toggle (group settings), and it is the
    /// roster-less shape of the list, not a per-group fetch.
    func refreshRules() async {
        guard AppState.shared.networkReady, !PanicPINService.shared.isDecoy else { return }
        struct Row: Decodable {
            let id: Int
            let rules: RoomRules
            enum CodingKeys: String, CodingKey { case id }
            init(from decoder: Decoder) throws {
                self.id = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .id)
                self.rules = try RoomRules(from: decoder)
            }
        }
        guard let rows: [Row] = try? await APIClient.shared.request(
            "GET", "/groups", query: ["members": "0"]
        ) else { return }
        for r in rows { roomRules[r.id] = r.rules }
    }

    /// Groups whose roster has been fetched from the island at least once in
    /// this app run. See `ensureRoster` for why "at least once" and not
    /// "when empty".
    private var rosterFetched = Set<Int>()

    /// The group WITH its roster, fetching it if the list did not carry one.
    ///
    /// ⚠ Anything that encrypts per recipient must go through this and not
    /// through `find`. The list is fetched without rosters now, so a cached
    /// group can legitimately have an empty member list, and sending against
    /// that would deliver to nobody while looking like it worked. A foreign
    /// group is left alone: its roster comes from its own island, and its id
    /// here is a local negative alias that our island knows nothing about.
    ///
    /// ⚠ Fetched once per group per app run even when a roster is already
    /// here, because the one that is here is whatever the first payload of the
    /// run happened to carry and nothing overwrites it afterwards: the list
    /// poll asks `?members=0` and `refreshNow`/`upsert` both deliberately keep
    /// the roster they already paid for, and the membership broadcast for a
    /// room over a hundred people carries the group id alone. So a member who
    /// set a picture, renamed themselves or joined after that first payload
    /// stayed invisible for the rest of the run, which is founder item 29,
    /// "a group member who is not my contact shows no avatar": a contact's
    /// picture is refreshed by every `/contacts` poll, a group member's was
    /// refreshed by nothing. Android fixed the same hole with the same rule
    /// (`Session.kt`, `rosterFetched`).
    @discardableResult
    /// [refresh] fetches even when a roster is already held.
    ///
    /// ⚠ A roster carries PRESENCE, and that field is as old as the fetch, so
    /// one held for an hour reports a room full of offline people. Anything
    /// that puts a status in front of somebody asks for it fresh; anything that
    /// only needs keys or names does not, because the roster of a big room is
    /// expensive (the beta room is 2200 people).
    func ensureRoster(_ groupID: Int, refresh: Bool = false) async -> RCQGroup? {
        guard let cached = find(groupID) else { return nil }
        if cached.host != nil { return cached }
        if !refresh && !cached.members.isEmpty && rosterFetched.contains(groupID) { return cached }
        guard let full: GroupWithRules = try? await APIClient.shared.request(
            "GET", "/groups/\(groupID)"
        ) else { return cached }
        rosterFetched.insert(groupID)
        roomRules[groupID] = full.rules
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return full.group }
        // Only the roster is taken: everything else on the row is already live
        // and may have been patched locally while this was in flight.
        groups[idx].members = full.group.members
        groups[idx].memberCount = full.group.memberCount
        return groups[idx]
    }

    func addMember(groupID: Int, uin: Int) async throws {
        struct Body: Encodable { let uin: Int }
        let row: GroupWithRules = try await APIClient.shared.request(
            "POST", "/groups/\(groupID)/members", body: Body(uin: uin)
        )
        roomRules[groupID] = row.rules
        upsert(row.group)
        // Stage 6 phase 2: the inviter hands the new member the room state
        // key at the moment of adding (design doc, road 3). Best-effort -
        // a missed hand-off is one gsknack away.
        if let held = RoomKeyStore.shared.key(groupID),
           let member = row.group.members.first(where: { $0.uin == uin }),
           !member.identityKey.isEmpty {
            Task {
                await MessageService.shared.sendRoomKey(gid: groupID, held: held, to: member)
            }
        }
    }

    enum CrossIslandAddError: Error { case notCrossIsland, unreachable }

    /// §5c owner-initiated cross-island add: put a contact who lives on ANOTHER
    /// island into a (local) group. The group's island has no account for the
    /// foreign uin (that's the "no such user" 404), so resolve-or-register the
    /// contact's PUBLIC keys there to get a local uin, add THAT uin, then send
    /// the contact the group link so they guest-register (recover-first → the
    /// SAME uin) and start polling. Added FIRST, their later /join
    /// short-circuits on "already a member" BEFORE the closed-group gate, so
    /// this works for CLOSED groups too. Foreign groups (alias id) keep the
    /// §5c management limit — owner-add there routes to the own island.
    /// Returns whether the INVITE LINK actually reached the contact. The link
    /// is the only channel the invitee learns about the group through (§5c:
    /// the island never notifies them), so a swallowed send here was half of
    /// megalist A3 — the inviter saw success while the invitee saw nothing.
    /// The member IS on the roster either way; a false return means "tell the
    /// user to hand over the link themselves".
    @discardableResult
    func addCrossIslandMember(group: RCQGroup, contact: Contact) async throws -> Bool {
        guard let contactHost = contact.host else { throw CrossIslandAddError.notCrossIsland }
        let groupHost = group.host ?? Multihome.ownHost()
        // Contact already lives on the group's island → a normal same-island add.
        if contactHost.lowercased() == groupHost.lowercased() {
            try await addMember(groupID: group.id, uin: contact.uin)
            return true
        }
        let nick = contact.nickname.isEmpty ? "user-\(contact.uin)" : contact.nickname
        var resolved = await CrossIslandGroups.resolveUinForKey(host: groupHost, signingKeyB64: contact.signingKey)
        if resolved == nil {
            resolved = await CrossIslandGroups.registerForeignKeys(
                host: groupHost, identityKey: contact.identityKey, signingKey: contact.signingKey, nickname: nick
            )
        }
        guard let localUin = resolved else { throw CrossIslandAddError.unreachable }
        // Add the resolved local uin to the roster (group.host == nil → own
        // island; this is the founder's common case).
        try await addMember(groupID: group.id, uin: localUin)
        // Notify the contact via a cross-island 1:1 — the link renders as a join
        // card on their side; tapping it completes the loop.
        let link = "https://rcq.app/g/\(group.id)@\(groupHost)"
        do {
            try await MessageService.shared.send(text: link, to: contact)
            return true
        } catch {
            return false
        }
    }

    func removeMember(groupID: Int, uin: Int) async throws {
        let _: EmptyResponse = try await APIClient.shared.request(
            "DELETE", "/groups/\(groupID)/members/\(uin)"
        )
        if uin == AuthService.shared.ownUIN {
            groups.removeAll { $0.id == groupID }
            roomRules[groupID] = nil
            rosterFetched.remove(groupID)
            MessageStore.shared.clearThread(.group(id: groupID))
            clearUnread(groupID)
        } else {
            _ = try? await reload(groupID)
        }
    }

    func leave(_ groupID: Int) async throws {
        guard let me = AuthService.shared.ownUIN else { return }
        try await removeMember(groupID: groupID, uin: me)
        // Leaving is an explicit local action, which is the only thing that
        // ever prunes the sections slot. The key carries the group's HOST: a
        // foreign group's local id is a negative alias allocated in first-sight
        // order and means nothing on another device.
        SectionsVault.forgetSectionMember(Sections.key(forGroupID: groupID))
    }

    /// Every partial group update goes through here: one PATCH, one decode of
    /// the reply into both the model and the room rules it carries, one upsert.
    @discardableResult
    private func patchGroup(_ groupID: Int, _ body: Encodable) async throws -> RCQGroup {
        let row: GroupWithRules = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: body
        )
        roomRules[groupID] = row.rules
        upsert(row.group)
        return row.group
    }

    func rename(groupID: Int, name: String) async throws {
        struct Body: Encodable { let name: String }
        try await patchGroup(groupID, Body(name: name))
    }

    /// SPEC 6.6, the full capability list, in the order the island stores it.
    /// The owner holds all three implicitly and is the only caller the island
    /// lets grant them, so there is no escalation chain.
    ///   `delete`  retract another member's message for everyone
    ///   `members` remove members
    ///   `info`    edit name, description, picture, pinned message
    /// There is no admin ROLE behind these: the role column is never written to
    /// "admin" anywhere on the island. Nor is a cap ownership. The crown moves
    /// in exactly two ways, and `transferOwner` below is the deliberate one
    /// (the other is the owner leaving, which promotes the oldest member).
    static let allPermissions = ["delete", "members", "info"]

    /// Owner: grant/revoke a member's moderator caps (any subset of
    /// `allPermissions`; the empty list demotes back to a plain member).
    /// Returns with the updated group and roster already upserted.
    func setMemberPermissions(groupID: Int, uin: Int, permissions: [String]) async throws {
        struct Body: Encodable { let permissions: [String] }
        // Canonical order + no strangers, the same shape the island stores;
        // it rejects an unknown cap with a 400 rather than ignoring it.
        let clean = Self.allPermissions.filter { permissions.contains($0) }
        let row: GroupWithRules = try await APIClient.shared.request(
            "POST", "/groups/\(groupID)/members/\(uin)/permissions", body: Body(permissions: clean)
        )
        roomRules[groupID] = row.rules
        upsert(row.group)
    }

    // MARK: - Ownership

    /// Why the island refused a handover, in its own vocabulary. Every one of
    /// these is a fact about the TARGET or about us rather than a network
    /// hiccup, so each gets its own sentence instead of a shared "could not".
    enum TransferOwnerError: Error {
        /// 403. We are not the owner any more (somebody else's transfer, or
        /// our own from another device, landed first).
        case ownerOnly
        /// 400. The target is us.
        case alreadyOwner
        /// 404. No membership row for them in this group any more.
        case notAMember
        /// 404. A membership row whose account this island cannot resolve: a
        /// burned or migrated account, or a member of another island. There is
        /// no wire form for "the owner lives elsewhere", so this is refused
        /// rather than approximated.
        case noSuchUser
        /// 409. The account cannot authenticate at all, so it could not pull a
        /// single owner lever and the room would be left unmanageable.
        case targetSuspended
        /// 429, ten per hour. `retryAfter` is the island's own count of
        /// seconds, when it sent one.
        case rateLimited(retryAfter: Int?)
        /// Anything else: no connection, a 500, or an island too old to have
        /// the endpoint at all (a bare 404 from the router, no `detail.code`).
        case other(String)

        var message: String {
            switch self {
            case .ownerOnly:       return "group.transfer.err.owner_only".localized
            case .alreadyOwner:    return "group.transfer.err.already_owner".localized
            case .notAMember:      return "group.transfer.err.not_a_member".localized
            case .noSuchUser:      return "group.transfer.err.no_such_user".localized
            case .targetSuspended: return "group.transfer.err.target_suspended".localized
            case .rateLimited(let wait):
                guard let wait, wait > 0 else { return "group.transfer.err.rate_limited".localized }
                return "group.transfer.err.rate_limited_in".localized(wait)
            case .other(let text):
                return text.isEmpty ? "group.transfer.err.failed".localized : text
            }
        }
    }

    /// Hand the whole room to another member (founder item 23, the half that
    /// needed a server). Owner only, and one way from here: the island answers
    /// with the group as it now stands, and the moment that lands we are a
    /// plain member of it.
    ///
    /// ⚠ The response replaces the WHOLE local group, not just `ownerUIN`. The
    /// roles moved with it (their row became the owner's, ours stopped being)
    /// and so did both `permissions` lists, because a capability is a grant
    /// FROM the owner and the owner is somebody else now. Patching the single
    /// field would leave every screen still drawing our row with rights it no
    /// longer has, and the client-enforced `delete` cap honouring them.
    ///
    /// ⚠ OWN-ISLAND ONLY. Group membership is local by construction: a member
    /// is a bare number that means something only against this island's users,
    /// so the island refuses a target it cannot resolve (`no_such_user`) and
    /// there is no form in which "the new owner lives on island B" can be
    /// expressed. A cross-island group's id here is a local negative alias our
    /// island knows nothing about; callers gate on `group.host == nil`.
    @discardableResult
    func transferOwner(groupID: Int, toUIN: Int) async throws -> RCQGroup {
        struct Body: Encodable { let to_uin: Int }
        do {
            let row: GroupWithRules = try await APIClient.shared.request(
                "POST", "/groups/\(groupID)/transfer-owner", body: Body(to_uin: toUIN)
            )
            roomRules[groupID] = row.rules
            upsert(row.group)
            return row.group
        } catch {
            throw Self.transferRefusal(error)
        }
    }

    /// The island's refusal, typed. `detail.code` is the branch; the status is
    /// only consulted for a 429 that reached us through something that ate the
    /// body (a proxy, an older limiter), because the ceiling is still the thing
    /// that happened.
    static func transferRefusal(_ error: Error) -> TransferOwnerError {
        if let typed = error as? TransferOwnerError { return typed }
        guard let api = error as? APIError, case .http(let status, let body) = api else {
            return .other(APIErrorPresenter.friendly(error))
        }
        switch parseCode(body) {
        case "owner_only":       return .ownerOnly
        case "already_owner":    return .alreadyOwner
        case "not_a_member":     return .notAMember
        case "no_such_user":     return .noSuchUser
        case "target_suspended": return .targetSuspended
        case "rate_limited":     return .rateLimited(retryAfter: parseInt(body, key: "retry_after"))
        default: break
        }
        if status == 429 { return .rateLimited(retryAfter: parseInt(body, key: "retry_after")) }
        return .other("group.transfer.err.failed".localized)
    }

    /// One sentence for a handover that did not land, whatever it was.
    static func transferFailureMessage(_ error: Error) -> String {
        transferRefusal(error).message
    }

    /// The COMPACT `group_membership_changed`: above a hundred members the
    /// island cannot afford to push the whole snapshot to everyone, so it
    /// sends the group id and `owner_uin` alone (`_broadcast_membership`).
    ///
    /// ⚠ Ignoring it is not harmless. Every other owner-only lever is enforced
    /// by the island, which 403s a stale client the moment it pulls one; the
    /// moderator `delete` cap is honoured by the RECEIVING client against its
    /// cached roster, because sealed sender leaves the island no sender to
    /// check. So a stale `ownerUIN` is a revoked owner whose deletes still land
    /// on every big group, until the next boot.
    ///
    /// Only the number is written, and nothing is FETCHED here: the event
    /// exists precisely because the roster of a room this size is too expensive
    /// to move, and pulling one on every frame would spend exactly what the
    /// compact form saved. Nothing reads a stale role as a right, either -
    /// `RCQGroupMember.canDelete` asks for role "admin" or an explicit cap, and
    /// the ex-owner's row carries neither.
    ///
    /// ⚠ What IS recorded is that the cached roster is now out of date, which
    /// is #836's first point: someone joining a big room reached the other
    /// members only after a RESTART, because `ensureRoster` answers from cache
    /// once it has fetched a room and nothing ever cleared that mark. Dropping
    /// it costs one fetch, and only for whoever actually opens the member list.
    func applyOwnerLocally(groupID: Int, ownerUIN: Int) {
        rosterFetched.remove(groupID)
        guard let idx = groups.firstIndex(where: { $0.id == groupID }),
              groups[idx].ownerUIN != ownerUIN else { return }
        groups[idx].ownerUIN = ownerUIN
    }

    /// Owner/admin — set the free-text group description. Pass an
    /// empty string to clear it (server treats empty as "remove").
    func setDescription(groupID: Int, description: String) async throws {
        struct Body: Encodable { let description: String }
        try await patchGroup(groupID, Body(description: description))
    }

    /// The pin slot the server actually has: `GroupPatchIn.pinned_text` is a
    /// The island's pin slot, and anything longer is rejected with 422
    /// BEFORE the row is written. Nothing on the wire tells the user that,
    /// so a long message pinned from the chat used to leave the PREVIOUS pin
    /// standing while the optimistic swap made it look replaced, until the
    /// next poll put the old text back ("не заменяет ранее закреплённое").
    /// Clients do the cutting. 500 until 29.08, when the founder raised the
    /// server column to 4096 (megalist A6); an old island still on 500 keeps
    /// refusing longer pins with the same visible rollback, which is the
    /// price of not probing every island's limit.
    static let pinnedTextLimit = 4096

    /// Longest prefix of `text` that fits `budget` unicode scalars. Scalars
    /// because that is the unit the server counts; whole characters because
    /// cutting inside a grapheme cluster splits a glyph in half.
    private static func pinnedPrefix(_ text: String, budget: Int) -> String {
        var out = ""
        var used = 0
        for ch in text {
            let next = used + ch.unicodeScalars.count
            if next > budget { break }
            out.append(ch)
            used = next
        }
        return out
    }

    /// A pin on its way to the server: trimmed and cut to the slot, with an
    /// ellipsis marking the cut so a reader sees that the text continues.
    static func clampPinnedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > pinnedTextLimit else { return trimmed }
        let cut = pinnedPrefix(trimmed, budget: pinnedTextLimit - 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "…"
    }

    /// A pin someone is TYPING: truncate only. Trimming here would eat the
    /// space they just pressed.
    static func cappedPinnedInput(_ text: String) -> String {
        guard text.unicodeScalars.count > pinnedTextLimit else { return text }
        return pinnedPrefix(text, budget: pinnedTextLimit)
    }

    /// A pin that did not land, in words. 403 is the one the user can act on
    /// (the group took the info right away, or never granted it); everything
    /// else is the usual connection story.
    static func pinFailureMessage(_ error: Error) -> String {
        if let apiErr = error as? APIError, case .http(let status, _) = apiErr {
            // The group took the info right away, or never granted it.
            if status == 403 { return "chat.pin.error.forbidden".localized }
            // The slot refused the body itself (length, shape). Clamping should
            // keep us out of here, but a server that tightens the field must
            // still say something the reader can act on.
            if status == 400 || status == 422 { return "chat.pin.error.rejected".localized }
        }
        let friendly = APIErrorPresenter.friendly(error)
        return friendly.isEmpty ? "chat.pin.error.generic".localized : friendly
    }

    /// Owner/admin — set the sticky pinned announcement. Pass an empty
    /// string to clear (server flips the column back to NULL). Clamped here
    /// rather than at each call site: this is the only door to the slot, and
    /// an over-long body is a 422 that never touches the row.
    func setPinnedText(groupID: Int, pinnedText: String) async throws {
        struct Body: Encodable { let pinned_text: String }
        try await patchGroup(groupID, Body(pinned_text: Self.clampPinnedText(pinnedText)))
    }

    /// Optimistically swap a group's pinned text in the local published list so
    /// the chat banner updates INSTANTLY when pinning from a message, before the
    /// PATCH round-trips. The server response (via setPinnedText/upsert or the
    /// group_membership_changed WS event) reconciles it. Empty string clears.
    func applyPinnedTextLocally(groupID: Int, pinnedText: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var g = groups[idx]
        let trimmed = pinnedText.trimmingCharacters(in: .whitespacesAndNewlines)
        g.pinnedText = trimmed.isEmpty ? nil : trimmed
        groups[idx] = g
    }

    /// Owner-only — flip the broadcast mode. `"all"` lets everyone
    /// post, `"owner_only"` makes the group a one-way channel. The
    /// read-only half of the founder's "заморозка".
    func setPostPolicy(groupID: Int, policy: String) async throws {
        struct Body: Encodable { let post_policy: String }
        try await patchGroup(groupID, Body(post_policy: policy))
    }

    /// Owner-only — flip `is_closed`. Closed groups reject self-join
    /// (the share-to-friend deep link 403s); only an owner-issued
    /// invite (the `add_member` endpoint) inserts membership.
    func setIsClosed(groupID: Int, isClosed: Bool) async throws {
        struct Body: Encodable { let is_closed: Bool }
        try await patchGroup(groupID, Body(is_closed: isClosed))
    }

    /// Owner-only — hide the member roster in Group Info from
    /// everyone but the owner.
    func setMembersHidden(groupID: Int, hidden: Bool) async throws {
        struct Body: Encodable { let members_hidden: Bool }
        try await patchGroup(groupID, Body(members_hidden: hidden))
    }

    /// Voluntary catalog (stage 6): publish or unlist the room's name and
    /// description. Admin-or-owner on the island (the "info" capability),
    /// same gate as renaming - it is the same information.
    func setInCatalog(groupID: Int, listed: Bool) async throws {
        struct Body: Encodable { let in_catalog: Bool }
        try await patchGroup(groupID, Body(in_catalog: listed))
    }

    /// Owner-only: may links in this room be opened. Client-honored, because the
    /// island cannot see inside a sealed envelope, so it publishes the rule
    /// and every client renders links as plain text while it is off.
    func setLinksAllowed(groupID: Int, allowed: Bool) async throws {
        struct Body: Encodable { let links_allowed: Bool }
        try await patchGroup(groupID, Body(links_allowed: allowed))
    }

    /// Owner-only: may files be sent here. Client-honored, same reason as
    /// `setLinksAllowed`.
    func setFilesAllowed(groupID: Int, allowed: Bool) async throws {
        struct Body: Encodable { let files_allowed: Bool }
        try await patchGroup(groupID, Body(files_allowed: allowed))
    }

    /// Owner-only: the pause between messages for each member, in seconds.
    /// The other half of "заморозка": the room stays open but stops being a
    /// place anyone can flood. Only `RoomRules.slowmodeSteps` are accepted;
    /// anything else is a 422 that never reaches the row. Enforced by the
    /// island itself for authenticated senders, moderators and owner exempt.
    func setSlowmode(groupID: Int, seconds: Int) async throws {
        struct Body: Encodable { let slowmode_sec: Int }
        guard RoomRules.slowmodeSteps.contains(seconds) else { return }
        try await patchGroup(groupID, Body(slowmode_sec: seconds))
    }

    /// Owner-only: the anti-spam age floor (#803). Only
    /// `RoomRules.ageGateSteps` are accepted; the island enforces the rule
    /// itself for authenticated senders, owner and admins exempt.
    func setAgeGate(groupID: Int, hours: Int) async throws {
        struct Body: Encodable { let min_account_age_hours: Int }
        guard RoomRules.ageGateSteps.contains(hours) else { return }
        try await patchGroup(groupID, Body(min_account_age_hours: hours))
    }

    /// Admin / owner — swap the uploaded avatar. Pass `nil` for both
    /// fields to clear (the server treats empty strings as "remove"
    /// because Pydantic can't distinguish "field absent" from "field
    /// = null" otherwise).
    func setAvatar(groupID: Int, mediaID: String?, keyBase64: String?) async throws {
        struct Body: Encodable {
            let avatar_media_id: String
            let avatar_media_key: String
        }
        try await patchGroup(groupID, Body(
            avatar_media_id: mediaID ?? "",
            avatar_media_key: keyBase64 ?? "",
        ))
    }

    /// Lightweight info for a non-member — used by AddContactView's
    /// "join by group id" path so the user sees the member count
    /// BEFORE committing.
    struct Preview: Codable, Hashable, Identifiable {
        let id: Int
        let name: String
        let memberCount: Int
        let ownerUIN: Int
        let ownerNickname: String?
        let avatarMediaID: String?
        let avatarMediaKey: String?
        /// The island's badge on the room, as `GroupPreviewOut.badge`.
        var badge: String? = nil

        enum CodingKeys: String, CodingKey {
            case id, name
            case memberCount = "member_count"
            case ownerUIN = "owner_uin"
            case ownerNickname = "owner_nickname"
            case avatarMediaID = "avatar_media_id"
            case badge
            case avatarMediaKey = "avatar_media_key"
        }
    }

    func preview(groupID: Int) async -> Preview? {
        do {
            let p: Preview = try await APIClient.shared.request(
                "GET", "/groups/\(groupID)/preview"
            )
            return p
        } catch {
            return nil
        }
    }

    /// Find joinable groups by name substring (or exact id when `q`
    /// is digits). Server filters out groups the caller is already a
    /// member of, so the returned list is always actionable through
    /// the JoinGroupSheet flow.
    /// Open rooms the caller is not in, biggest first: what an empty home
    /// shows instead of nothing (founder, 05.09). Failure is an empty list,
    /// and an empty list draws no strip.
    func discover(limit: Int = 12) async -> [Preview] {
        do {
            let rows: [Preview] = try await APIClient.shared.request(
                "GET", "/groups/discover", query: ["limit": String(limit)]
            )
            return rows
        } catch {
            return []
        }
    }

    func search(query: String, limit: Int = 20) async -> [Preview] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        do {
            let rows: [Preview] = try await APIClient.shared.request(
                "GET", "/groups/search",
                query: ["q": trimmed, "limit": String(limit)]
            )
            return rows
        } catch {
            return []
        }
    }

    /// Self-join. Server adds the caller as a member of an open group.
    enum JoinResult {
        case success(RCQGroup)
        case blocked
        /// Group is closed — share-to-friend recipients can preview
        /// but not self-join. Owner has to invite them explicitly.
        case closed
        case other(String)
    }

    /// Mirror of backend `GroupPreviewOut`. Powers the share-card and
    /// the join sheet — both fetch this for a group the viewer isn't
    /// (yet) a member of.
    struct GroupPreview: Codable, Hashable {
        let id: Int
        let name: String
        /// Group description blurb — nil when the owner hasn't set one.
        let description: String?
        let memberCount: Int
        let isClosed: Bool
        let ownerUIN: Int
        let ownerNickname: String?
        let avatarMediaID: String?
        let avatarMediaKey: String?

        enum CodingKeys: String, CodingKey {
            case id, name, description
            case memberCount = "member_count"
            case isClosed = "is_closed"
            case ownerUIN = "owner_uin"
            case ownerNickname = "owner_nickname"
            case avatarMediaID = "avatar_media_id"
            case avatarMediaKey = "avatar_media_key"
        }
    }

    func join(groupID: Int) async -> JoinResult {
        do {
            let row: GroupWithRules = try await APIClient.shared.request(
                "POST", "/groups/\(groupID)/join",
            )
            roomRules[groupID] = row.rules
            upsert(row.group)
            noteMembershipBegan()
            return .success(row.group)
        } catch APIError.http(403, let body) {
            // 403 from /join now covers two distinct cases: caller is
            // blocked by the owner, OR the group is closed and only
            // accepts owner-issued invitations. Decode `detail.code`
            // to surface the right sheet copy.
            if (body ?? "").contains("group_closed") {
                return .closed
            }
            return .blocked
        } catch {
            return .other(error.localizedDescription)
        }
    }

    func fetchPreview(groupID: Int) async -> GroupPreview? {
        do {
            let out: GroupPreview = try await APIClient.shared.request(
                "GET", "/groups/\(groupID)/preview"
            )
            return out
        } catch {
            return nil
        }
    }

    /// `detail.code` out of an error body: the shape every structured refusal
    /// on this island uses (`{"detail": {"code": "...", ...}}`). Nil for the
    /// router's own `{"detail": "Not Found"}`, which is how an island too old
    /// for an endpoint answers.
    private static func parseCode(_ body: String?) -> String? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any] else {
            return nil
        }
        return detail["code"] as? String
    }

    private static func parseInt(_ body: String?, key: String) -> Int? {
        guard let raw = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let detail = json["detail"] as? [String: Any] else {
            return nil
        }
        return detail[key] as? Int
    }

    func delete(_ groupID: Int) async throws {
        let _: EmptyResponse = try await APIClient.shared.request(
            "DELETE", "/groups/\(groupID)"
        )
        groups.removeAll { $0.id == groupID }
        roomRules[groupID] = nil
        rosterFetched.remove(groupID)
        MessageStore.shared.clearThread(.group(id: groupID))
        clearUnread(groupID)
        SectionsVault.forgetSectionMember(Sections.key(forGroupID: groupID))
    }

    func upsert(_ g: RCQGroup) {
        // If the server is telling us about a group we're no longer a
        // member of, purge it instead of adding it back. This fires
        // right after the leave/remove flow: the server broadcasts a
        // `group_membership_changed` to every previously-member UIN
        // (so the iOS client of the just-removed user knows to drop
        // the group), and the old upsert blindly re-inserted the
        // group on the leaver's device — they'd leave, see the row
        // vanish from `groups.remove(...)`, then watch the WS event
        // put it right back.
        //
        // ⚠ An EMPTY roster is not the same statement as "you are not in it".
        // Payloads without a roster exist now (the list is fetched with
        // `?members=0`, and the server sends the compact form for groups over
        // a hundred people), and reading one as a removal would delete the
        // biggest groups off the device.
        let myUIN = AuthService.shared.ownUIN
        if let me = myUIN, !g.members.isEmpty, !g.members.contains(where: { $0.uin == me }) {
            groups.removeAll { $0.id == g.id }
            BadgeCounter.reset(threadKey: BadgeCounter.threadKey(groupID: g.id))
            BadgeCounter.syncIcon()
            return
        }
        if let idx = groups.firstIndex(where: { $0.id == g.id }) {
            var next = g
            // Keep a roster we already paid for rather than dropping it for a
            // payload that simply did not carry one.
            if next.members.isEmpty { next.members = groups[idx].members }
            groups[idx] = next
        } else {
            groups.insert(g, at: 0)
        }
    }

    func purge(_ groupID: Int) {
        groups.removeAll { $0.id == groupID }
        roomRules[groupID] = nil
        rosterFetched.remove(groupID)
        // Drop the icon-badge slot for this group so the counter
        // doesn't stick after a leave / group_deleted event.
        BadgeCounter.reset(threadKey: BadgeCounter.threadKey(groupID: groupID))
        BadgeCounter.syncIcon()
    }

    /// Patch a member's status across every group they're in. Called by AppState
    /// on each `presence` event so the GroupInfoView icons track live presence
    /// just like the contact list does.
    func updateMemberPresence(uin: Int, status: UserStatus) {
        for gi in groups.indices {
            for mi in groups[gi].members.indices where groups[gi].members[mi].uin == uin {
                groups[gi].members[mi].status = status
            }
        }
    }

    /// Local cache reset used by the burn flow.
    func wipe() {
        rosterEpoch += 1
        rosterAccount = nil
        groupsLoaded = false
        refreshInFlight = nil
        groups = []
        unread = [:]
        roomRules = [:]
        // The next account's group ids are its own; a leftover "already
        // fetched" mark would deny it its first roster.
        rosterFetched = []
    }

    func clearForDecoy() {
        rosterEpoch += 1
        refreshInFlight = nil
        groups = []
        unread = [:]
        roomRules = [:]
        rosterFetched = []
    }

    func groupID(for thread: ThreadID) -> Int? {
        if case .group(let id) = thread { return id } else { return nil }
    }

    func find(_ groupID: Int) -> RCQGroup? {
        groups.first(where: { $0.id == groupID })
    }
}
