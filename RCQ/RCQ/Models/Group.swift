import Foundation

/// Group of friends, ICQ-style. Mirrors `GroupOut`. Named `RCQGroup` to
/// avoid collision with SwiftUI's `Group` view container.
struct RCQGroup: Identifiable, Hashable, Codable {
    /// For a cross-island group (§5c) the client rewrites this to the local
    /// NEGATIVE alias at the fetch boundary; the server-side id lives in
    /// VisitedIslandsStore's alias map. `var` so that rewrite is in place.
    var id: Int
    var name: String
    /// CLIENT-SIDE only (§5c): the island a cross-island group lives on. Never
    /// sent by a server (not in CodingKeys); nil for own-island groups.
    var host: String? = nil
    /// Owner/admin-set free-text description. Nil when unset —
    /// Group Info hides the blurb and the join sheet skips the row.
    var description: String? = nil
    var ownerUIN: Int
    var avatarSeed: Int
    /// `"all"` (everyone can post) or `"owner_only"` (broadcast mode).
    /// Sealed-sender means the server can't enforce identity at send
    /// time; iOS gates the composer to keep the contract honest.
    var postPolicy: String = "all"
    /// Closed groups can only be entered via an owner-issued
    /// invite. The share-to-friend deep link 403s on `/join`.
    /// Toggle is owner-only in Group Settings.
    var isClosed: Bool = false
    /// When true, the member roster is hidden in Group Info from
    /// everyone but the owner. Display-only — `members` still
    /// arrives (needed for per-recipient group encryption).
    var membersHidden: Bool = false
    /// Voluntary catalog (stage 6): true only when the owner listed the room;
    /// island search matches catalog rows only. Off = link-only discovery.
    var inCatalog: Bool = false
    /// Pinned plaintext announcement, owner/admin-editable. Nil when
    /// unset. Rendered as a sticky banner above the chat message list
    /// so new joiners (who can't see encrypted history) at least see
    /// the rules / welcome. Server stores plaintext — see backend
    /// model comment for the rationale.
    var pinnedText: String? = nil
    var pinnedAt: Date? = nil
    var pinnedBy: Int? = nil
    /// Uploaded group avatar — encrypted blob id + per-blob AES key
    /// (base64). Both NULL = no custom avatar, fall back to the
    /// generic person.3 glyph.
    var avatarMediaID: String? = nil
    var avatarMediaKey: String? = nil
    var createdAt: Date
    /// How many people are in the group, independent of whether `members` was
    /// fetched. Every list row needs the number and nothing else, and the
    /// roster is the expensive half of a group payload — every member with two
    /// base64 keys, which on the beta group is most of a megabyte.
    var memberCount: Int = 0
    /// ⚠ Can legitimately be EMPTY. The chat list is fetched with `?members=0`,
    /// so a group in `GroupService.groups` may carry no roster at all until
    /// something asks for one. Anything that encrypts per recipient must go
    /// through `GroupService.ensureRoster` first — sending against an empty
    /// roster delivers to nobody while looking like it worked.
    var members: [RCQGroupMember]

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case memberCount = "member_count"
        case ownerUIN = "owner_uin"
        case avatarSeed = "avatar_seed"
        case postPolicy = "post_policy"
        case isClosed = "is_closed"
        case membersHidden = "members_hidden"
        case inCatalog = "in_catalog"
        case pinnedText = "pinned_text"
        case pinnedAt = "pinned_at"
        case pinnedBy = "pinned_by"
        case avatarMediaID = "avatar_media_id"
        case avatarMediaKey = "avatar_media_key"
        case createdAt = "created_at"
        case members
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try? c.decodeIfPresent(String.self, forKey: .description)
        self.ownerUIN = try c.decode(Int.self, forKey: .ownerUIN)
        self.avatarSeed = try c.decode(Int.self, forKey: .avatarSeed)
        self.postPolicy = (try? c.decodeIfPresent(String.self, forKey: .postPolicy)) ?? "all"
        self.isClosed = (try? c.decodeIfPresent(Bool.self, forKey: .isClosed)) ?? false
        self.membersHidden = (try? c.decodeIfPresent(Bool.self, forKey: .membersHidden)) ?? false
        self.inCatalog = (try? c.decodeIfPresent(Bool.self, forKey: .inCatalog)) ?? false
        self.pinnedText = try? c.decodeIfPresent(String.self, forKey: .pinnedText)
        self.pinnedAt = try? c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        self.pinnedBy = try? c.decodeIfPresent(Int.self, forKey: .pinnedBy)
        self.avatarMediaID = try? c.decodeIfPresent(String.self, forKey: .avatarMediaID)
        self.avatarMediaKey = try? c.decodeIfPresent(String.self, forKey: .avatarMediaKey)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.members = try c.decode([RCQGroupMember].self, forKey: .members)
        // Older islands do not send it; the roster's own size is right there.
        let declared = (try? c.decodeIfPresent(Int.self, forKey: .memberCount)) ?? 0
        self.memberCount = declared > 0 ? declared : self.members.count
    }

    func isAdmin(_ uin: Int) -> Bool {
        members.first(where: { $0.uin == uin })?.role == "admin"
            || ownerUIN == uin
    }

    func contains(_ uin: Int) -> Bool {
        members.contains(where: { $0.uin == uin })
    }

    func canPost(_ uin: Int) -> Bool {
        if uin == ownerUIN { return true }
        return postPolicy != "owner_only"
    }

    /// May [uin] retract OTHER people's messages here (founder batch 21.08,
    /// item 3; web precedent: incoming-store.ts groupModerator)? The owner
    /// may — checked off the group row itself, because the chat list is
    /// fetched `?members=0` and `members` can legitimately be empty (see the
    /// warning on that property). An admin / delete-cap member needs the
    /// cached roster.
    func moderator(_ uin: Int) -> Bool {
        uin == ownerUIN || members.first { $0.uin == uin }?.canDelete(ownerUIN: ownerUIN) == true
    }
}

struct RCQGroupMember: Identifiable, Hashable, Codable {
    let uin: Int
    let nickname: String
    let role: String  // owner | admin | member
    var status: UserStatus
    /// X25519 ECDH public key (base64).
    let identityKey: String
    /// Ed25519 signing public key (base64).
    let signingKey: String
    /// Non-null = member runs libsignal (Stage 3 eligible).
    let signalIdentityKey: String?
    /// Granular moderator caps the owner granted (subset of delete|members|info).
    /// Owner implicitly has all; a non-owner with any cap is a moderator.
    let permissions: [String]
    /// This member's client(s) understand the sender-keys group path (gmsg
    /// broadcast + skdm). False → only the legacy per-member fan-out reaches
    /// them (dual-send migration). See RCQ/docs/sender-keys-design.md.
    let senderKeys: Bool
    /// Profile picture, gated by MEMBERSHIP rather than by the contact list:
    /// sharing a group is the relationship here, the same one that already
    /// exposes the nickname on this row.
    var avatarMediaID: String? = nil
    var avatarMediaKey: String? = nil
    /// The island's per-viewer verdict on this member's profile card (founder
    /// item 22): may THIS client turn the name into a link? A member list is
    /// the first surface the setting names, and the roster row is the only
    /// place the answer can travel, because a reaction or a photo carries
    /// nothing but a UIN.
    ///
    /// Nil on the fan-out frames (`group_created`, `group_membership_changed`,
    /// `room_member_entered`): one payload goes to many recipients, so there is
    /// no single viewer to answer for. Nil FAILS OPEN and the next roster read
    /// repaints it.
    var profileOpenable: Bool? = nil

    var id: Int { uin }

    /// True if this member may delete anyone's message: the owner, an ADMIN,
    /// or a member the owner granted the `delete` cap. Role "admin" joined
    /// the rule in founder batch 21.08, item 3 ("админ не может удалить
    /// чужое сообщение") — the web shipped it first (incoming-store.ts
    /// groupModerator), Android in the same batch; the granted cap stays so
    /// existing delete-moderators keep the power they were given.
    func canDelete(ownerUIN: Int) -> Bool {
        uin == ownerUIN || role == "admin" || permissions.contains("delete")
    }
    /// True if this member may manage group info — pin, rename, etc. (owner OR
    /// `info` cap). Gates pinning a message from the chat.
    func canManageInfo(ownerUIN: Int) -> Bool { uin == ownerUIN || permissions.contains("info") }

    enum CodingKeys: String, CodingKey {
        case uin, nickname, role, status, permissions
        case identityKey = "identity_key"
        case signingKey = "signing_key"
        case signalIdentityKey = "signal_identity_key"
        case senderKeys = "sender_keys"
        case avatarMediaID = "avatar_media_id"
        case avatarMediaKey = "avatar_media_key"
        case profileOpenable = "profile_openable"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.uin = try c.decode(Int.self, forKey: .uin)
        self.nickname = try c.decode(String.self, forKey: .nickname)
        self.role = try c.decode(String.self, forKey: .role)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "offline"
        self.status = UserStatus(rawValue: raw) ?? .offline
        // Encrypt path skips members with empty keys (silent drop, no crash).
        self.identityKey = (try? c.decodeIfPresent(String.self, forKey: .identityKey)) ?? ""
        self.signingKey = (try? c.decodeIfPresent(String.self, forKey: .signingKey)) ?? ""
        self.signalIdentityKey = try? c.decodeIfPresent(String.self, forKey: .signalIdentityKey)
        self.permissions = (try? c.decodeIfPresent([String].self, forKey: .permissions)) ?? []
        self.senderKeys = (try? c.decodeIfPresent(Bool.self, forKey: .senderKeys)) ?? false
        self.avatarMediaID = try? c.decodeIfPresent(String.self, forKey: .avatarMediaID)
        self.avatarMediaKey = try? c.decodeIfPresent(String.self, forKey: .avatarMediaKey)
        self.profileOpenable = try? c.decodeIfPresent(Bool.self, forKey: .profileOpenable)
    }
}

/// What ChatView is talking to — peer contact, group, or random-chat session.
/// Random messages live in `RandomChatService.messages` only (ephemeral).
enum ChatTarget: Hashable {
    case peer(Contact)
    case group(RCQGroup)
    case randomPeer(RandomPeer)

    var thread: ThreadID {
        switch self {
        case .peer(let c): return .peer(uin: c.uin)
        case .group(let g): return .group(id: g.id)
        case .randomPeer(let p): return .peer(uin: p.uin)
        }
    }

    /// ⚠ `@MainActor` and not `assumeIsolated`.
    ///
    /// It used to reach the alias store through `MainActor.assumeIsolated`,
    /// which asserts the caller is already on the main actor and traps the
    /// process when it is not — the same construct that made the full network
    /// check kill the app every time it ran. Declaring the isolation instead
    /// hands the question to the compiler, where a wrong caller is a build
    /// error rather than a crash on someone's phone.
    @MainActor
    var displayName: String {
        switch self {
        // My own name for them, when I gave one. Every surface that names a
        // chat goes through here, so a rename lands everywhere at once.
        case .peer(let c):
            return ContactAliasStore.shared.displayName(for: c.uin, fallback: c.nickname)
        case .group(let g): return g.name
        case .randomPeer: return "chat.random.stranger".localized
        }
    }
}
