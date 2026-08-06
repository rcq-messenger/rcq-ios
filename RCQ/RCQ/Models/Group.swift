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
    var members: [RCQGroupMember]

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case ownerUIN = "owner_uin"
        case avatarSeed = "avatar_seed"
        case postPolicy = "post_policy"
        case isClosed = "is_closed"
        case membersHidden = "members_hidden"
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
        self.pinnedText = try? c.decodeIfPresent(String.self, forKey: .pinnedText)
        self.pinnedAt = try? c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        self.pinnedBy = try? c.decodeIfPresent(Int.self, forKey: .pinnedBy)
        self.avatarMediaID = try? c.decodeIfPresent(String.self, forKey: .avatarMediaID)
        self.avatarMediaKey = try? c.decodeIfPresent(String.self, forKey: .avatarMediaKey)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.members = try c.decode([RCQGroupMember].self, forKey: .members)
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

    var id: Int { uin }

    /// True if this member may delete anyone's message (owner OR `delete` cap).
    func canDelete(ownerUIN: Int) -> Bool { uin == ownerUIN || permissions.contains("delete") }
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

    var displayName: String {
        switch self {
        // My own name for them, when I gave one. Every surface that names a
        // chat goes through here, so a rename lands everywhere at once.
        case .peer(let c):
            return MainActor.assumeIsolated { ContactAliasStore.shared.displayName(for: c.uin, fallback: c.nickname) }
        case .group(let g): return g.name
        case .randomPeer: return "chat.random.stranger".localized
        }
    }

    /// Returns the group if the viewer should see a read-only hint
    /// instead of the composer (broadcast-mode and not allowed to post).
    func broadcastReadOnly(viewerUIN: Int?) -> RCQGroup? {
        guard case .group(let g) = self else { return nil }
        guard let me = viewerUIN else { return nil }
        return g.canPost(me) ? nil : g
    }
}
