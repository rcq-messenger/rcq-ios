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
        unread[groupID] = 0
    }

    func refresh() async {
        do {
            let list: [RCQGroup] = try await APIClient.shared.request("GET", "/groups")
            self.groups = list
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

    /// Owner/admin — set the free-text group description. Pass an
    /// empty string to clear it (server treats empty as "remove").
    func setDescription(groupID: Int, description: String) async throws {
        struct Body: Encodable { let description: String }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(description: description)
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

    /// Owner-only — set the token cost to join. `0` (or nil) makes
    /// the group free.
    func setEntryPrice(groupID: Int, priceTokens: Int) async throws {
        struct Body: Encodable { let entry_price_tokens: Int }
        let g: RCQGroup = try await APIClient.shared.request(
            "PATCH", "/groups/\(groupID)", body: Body(entry_price_tokens: priceTokens)
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
    /// "join by group id" path so the user sees the price + member
    /// count BEFORE committing to the wallet hit.
    struct Preview: Codable, Hashable, Identifiable {
        let id: Int
        let name: String
        let memberCount: Int
        let entryPriceTokens: Int?
        let ownerUIN: Int
        let ownerNickname: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case memberCount = "member_count"
            case entryPriceTokens = "entry_price_tokens"
            case ownerUIN = "owner_uin"
            case ownerNickname = "owner_nickname"
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

    /// Self-join. Server charges entry_price_tokens (if any) and
    /// adds the caller as a member.
    enum JoinResult {
        case success(RCQGroup)
        case insufficientTokens(required: Int, have: Int)
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
        let entryPriceTokens: Int?
        let isClosed: Bool
        let ownerUIN: Int
        let ownerNickname: String?
        /// Avatar fields mirror the standard `GroupOut` shape so a
        /// non-member sees the real group picture on the share-card.
        /// Both nil for legacy groups without an uploaded avatar.
        let avatarMediaID: String?
        let avatarMediaKey: String?

        enum CodingKeys: String, CodingKey {
            case id, name, description
            case memberCount = "member_count"
            case entryPriceTokens = "entry_price_tokens"
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
            // Wallet was debited server-side if the group was paid;
            // pull a fresh inventory snapshot so the badge ticks.
            await ItemsService.shared.refreshInventory(forceWallet: true)
            return .success(g)
        } catch APIError.http(402, let body) {
            if let req = Self.parseInt(body, key: "required"),
               let have = Self.parseInt(body, key: "have") {
                return .insufficientTokens(required: req, have: have)
            }
            return .other("group.error.join_payment".localized)
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
        if let idx = groups.firstIndex(where: { $0.id == g.id }) {
            groups[idx] = g
        } else {
            groups.insert(g, at: 0)
        }
    }

    func purge(_ groupID: Int) {
        groups.removeAll { $0.id == groupID }
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

    func groupID(for thread: ThreadID) -> Int? {
        if case .group(let id) = thread { return id } else { return nil }
    }

    func find(_ groupID: Int) -> RCQGroup? {
        groups.first(where: { $0.id == groupID })
    }
}
