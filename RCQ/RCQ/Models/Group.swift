import Foundation

/// Group of friends, ICQ-style. Mirrors `GroupOut`. Named `RCQGroup` to
/// avoid collision with SwiftUI's `Group` view container.
struct RCQGroup: Identifiable, Hashable, Codable {
    let id: Int
    var name: String
    var ownerUIN: Int
    var avatarSeed: Int
    /// `"all"` (everyone can post) or `"owner_only"` (broadcast mode).
    /// Sealed-sender means the server can't enforce identity at send
    /// time; iOS gates the composer to keep the contract honest.
    var postPolicy: String = "all"
    /// Tokens charged on `POST /groups/{id}/join`. NULL/0 = free.
    /// Owner gets `floor(price × 0.95)`; the 5% delta burns.
    var entryPriceTokens: Int? = nil
    var createdAt: Date
    var members: [RCQGroupMember]

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerUIN = "owner_uin"
        case avatarSeed = "avatar_seed"
        case postPolicy = "post_policy"
        case entryPriceTokens = "entry_price_tokens"
        case createdAt = "created_at"
        case members
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.ownerUIN = try c.decode(Int.self, forKey: .ownerUIN)
        self.avatarSeed = try c.decode(Int.self, forKey: .avatarSeed)
        self.postPolicy = (try? c.decodeIfPresent(String.self, forKey: .postPolicy)) ?? "all"
        self.entryPriceTokens = try? c.decodeIfPresent(Int.self, forKey: .entryPriceTokens)
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
    let equippedPet: EquippedPet?

    var id: Int { uin }

    enum CodingKeys: String, CodingKey {
        case uin, nickname, role, status
        case identityKey = "identity_key"
        case signingKey = "signing_key"
        case signalIdentityKey = "signal_identity_key"
        case equippedPet = "equipped_pet"
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
        self.equippedPet = try? c.decodeIfPresent(EquippedPet.self, forKey: .equippedPet)
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
        case .peer(let c): return c.nickname
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
