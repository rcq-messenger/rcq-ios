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

    func clearUnread(_ groupID: Int) {
        UnreadStore.shared.clearGroup(groupID)
        BadgeCounter.reset(threadKey: BadgeCounter.threadKey(groupID: groupID))
        BadgeCounter.syncIcon()
        unread[groupID] = 0
    }

    func refresh() async {
        if PanicPINService.shared.isDecoy { return }
        do {
            let list: [RCQGroup] = try await APIClient.shared.request("GET", "/groups")
            // §5c: groups joined on OTHER islands, fetched with the guest creds;
            // ids rewritten to the local alias + host stamped. Per-island
            // failures degrade to "no groups from there" — never block the own
            // list (the 30s drain refreshes expired guest creds).
            var foreign: [RCQGroup] = []
            for v in VisitedIslandsStore.shared.list() {
                foreign += await CrossIslandGroups.guestGroups(host: v.host)
            }
            self.groups = list + foreign
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
        let g: RCQGroup = try await APIClient.shared.request(
            "POST", "/groups", body: Body(name: name, member_uins: memberUINs)
        )
        upsert(g)
        return g
    }

    func reload(_ groupID: Int) async throws -> RCQGroup {
        let g: RCQGroup = try await APIClient.shared.request("GET", "/groups/\(groupID)")
        upsert(g)
        return g
    }

    func addMember(groupID: Int, uin: Int) async throws {
        struct Body: Encodable { let uin: Int }
        let g: RCQGroup = try await APIClient.shared.request(
            "POST", "/groups/\(groupID)/members", body: Body(uin: uin)
        )
        upsert(g)
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
    func addCrossIslandMember(group: RCQGroup, contact: Contact) async throws {
        guard let contactHost = contact.host else { throw CrossIslandAddError.notCrossIsland }
        let groupHost = group.host ?? Multihome.ownHost()
        // Contact already lives on the group's island → a normal same-island add.
        if contactHost.lowercased() == groupHost.lowercased() {
            try await addMember(groupID: group.id, uin: contact.uin)
            return
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
        try? await MessageService.shared.send(text: link, to: contact)
    }

    func removeMember(groupID: Int, uin: Int) async throws {
        let _: EmptyResponse = try await APIClient.shared.request(
            "DELETE", "/groups/\(groupID)/members/\(uin)"
        )
        if uin == AuthService.shared.ownUIN {
            groups.removeAll { $0.id == groupID }
            MessageStore.shared.clearThread(.group(id: groupID))
            clearUnread(groupID)
        } else {
            _ = try? await reload(groupID)
        }
    }

    func leave(_ groupID: Int) async throws {
        guard let me = AuthService.shared.ownUIN else { return }
        try await removeMember(groupID: groupID, uin: me)
    }

    func rename(groupID: Int, name: String) async throws {
        struct Body: Encodable { let name: String }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(name: name)
        )
        upsert(g)
    }

    /// Owner: grant/revoke a member's moderator caps (subset of
    /// delete|members|info). Returns the updated group with the new roster.
    func setMemberPermissions(groupID: Int, uin: Int, permissions: [String]) async throws {
        struct Body: Encodable { let permissions: [String] }
        let g: RCQGroup = try await APIClient.shared.request(
            "POST", "/groups/\(groupID)/members/\(uin)/permissions", body: Body(permissions: permissions)
        )
        upsert(g)
    }

    /// Owner/admin — set the free-text group description. Pass an
    /// empty string to clear it (server treats empty as "remove").
    func setDescription(groupID: Int, description: String) async throws {
        struct Body: Encodable { let description: String }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(description: description)
        )
        upsert(g)
    }

    /// Owner/admin — set the sticky pinned announcement. Pass an empty
    /// string to clear (server flips the column back to NULL).
    func setPinnedText(groupID: Int, pinnedText: String) async throws {
        struct Body: Encodable { let pinned_text: String }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(pinned_text: pinnedText)
        )
        upsert(g)
    }

    /// Owner-only — flip the broadcast mode. `"all"` lets everyone
    /// post, `"owner_only"` makes the group a one-way channel.
    func setPostPolicy(groupID: Int, policy: String) async throws {
        struct Body: Encodable { let post_policy: String }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(post_policy: policy)
        )
        upsert(g)
    }

    /// Owner-only — flip `is_closed`. Closed groups reject self-join
    /// (the share-to-friend deep link 403s); only an owner-issued
    /// invite (the `add_member` endpoint) inserts membership.
    func setIsClosed(groupID: Int, isClosed: Bool) async throws {
        struct Body: Encodable { let is_closed: Bool }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(is_closed: isClosed)
        )
        upsert(g)
    }

    /// Owner-only — hide the member roster in Group Info from
    /// everyone but the owner.
    func setMembersHidden(groupID: Int, hidden: Bool) async throws {
        struct Body: Encodable { let members_hidden: Bool }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(members_hidden: hidden)
        )
        upsert(g)
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
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH",
            "/groups/\(groupID)",
            body: Body(
                avatar_media_id: mediaID ?? "",
                avatar_media_key: keyBase64 ?? "",
            ),
        )
        upsert(g)
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

        enum CodingKeys: String, CodingKey {
            case id, name
            case memberCount = "member_count"
            case ownerUIN = "owner_uin"
            case ownerNickname = "owner_nickname"
            case avatarMediaID = "avatar_media_id"
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
            let g: RCQGroup = try await APIClient.shared.request(
                "POST", "/groups/\(groupID)/join",
            )
            upsert(g)
            return .success(g)
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
        MessageStore.shared.clearThread(.group(id: groupID))
        clearUnread(groupID)
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
        let myUIN = AuthService.shared.ownUIN
        if let me = myUIN, !g.members.contains(where: { $0.uin == me }) {
            groups.removeAll { $0.id == g.id }
            BadgeCounter.reset(threadKey: BadgeCounter.threadKey(groupID: g.id))
            BadgeCounter.syncIcon()
            return
        }
        if let idx = groups.firstIndex(where: { $0.id == g.id }) {
            groups[idx] = g
        } else {
            groups.insert(g, at: 0)
        }
    }

    func purge(_ groupID: Int) {
        groups.removeAll { $0.id == groupID }
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
        groups = []
        unread = [:]
    }

    func clearForDecoy() {
        groups = []
        unread = [:]
    }

    func groupID(for thread: ThreadID) -> Int? {
        if case .group(let id) = thread { return id } else { return nil }
    }

    func find(_ groupID: Int) -> RCQGroup? {
        groups.first(where: { $0.id == groupID })
    }
}
