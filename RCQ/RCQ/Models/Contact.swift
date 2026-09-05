import Foundation

struct Contact: Identifiable, Hashable, Codable {
    let uin: Int
    var nickname: String
    var status: UserStatus
    var statusMessage: String?
    var blocked: Bool
    /// X25519 ECDH public key (base64 raw 32 bytes). Senders use it to derive
    /// the per-message AEAD key.
    var identityKey: String
    /// Ed25519 signing public key (base64 raw 32 bytes). Recipients use it to
    /// authenticate the sealed-sender envelope.
    var signingKey: String
    /// Stage 3 marker — non-null means this peer has uploaded a libsignal
    /// PreKey bundle and we should ride v=2 envelopes for them. Null means
    /// Stage 2-only and senders fall back to v=1 ECIES.
    var signalIdentityKey: String?
    /// Gender icon hint. Server has already applied the contact's
    /// `gender_visibility` setting; null = hide. The icon-rendering
    /// helper accepts this alongside `NearbyPerson.gender`, which
    /// carries the same string values.
    var gender: String?
    var unread: Int = 0
    /// Server-gated by the contact's `last_seen_visibility`; null
    /// when the contact is currently online (status conveys that),
    /// or when they've hidden it. Use `relativeLastSeen()` to render.
    var lastSeen: Date?
    /// Whether WE may call this contact, per THEIR `call_policy` ("nobody"
    /// hides our call buttons). Optional for back-compat with an older server
    /// that omits it — nil is treated as callable. The server enforces the
    /// policy on the call_offer regardless.
    var callable: Bool? = nil
    /// Whether WE may open this contact's profile card, per THEIR
    /// `profile_card_policy` (founder item 22). The exact twin of `callable`
    /// one line up: the island computes the verdict per viewer and publishes
    /// the boolean, never the raw policy.
    ///
    /// Optional for back-compat with an island that omits it, and nil FAILS
    /// OPEN at `ProfileCardPrivacy.canOpenCard`. The island withholds the card
    /// fields regardless, so the worst a stale nil buys is a link that opens a
    /// card stripped down to its identity floor.
    ///
    /// ⚠ NOT in `CodingKeys` by accident: it must survive `CrossIslandStore`'s
    /// JSON persistence the way `host` does, so it IS listed there.
    var profileOpenable: Bool? = nil
    /// Federation (F2): the island host where this peer lives, set ONLY for a
    /// cross-island contact (stored locally, never from the server `/contacts`).
    /// When present, `MessageService.sendEnvelope` deposits to their island via
    /// federation-send instead of the flagship. Must be in CodingKeys so it
    /// survives `CrossIslandStore`'s JSON persistence.
    var host: String? = nil
    /// Profile picture: an encrypted blob id plus its key. The island fills
    /// these in only for people allowed to see it (a mutual contact, yourself,
    /// or a member of a group you are in), so the client never has to gate it.
    var avatarMediaID: String? = nil
    var avatarMediaKey: String? = nil
    /// The island's mark: nil or a kind ("official", "tester", ...). Optional
    /// on purpose: the synthesised decoder throws on a missing non-Optional
    /// key, and an older island does not send it.
    var badge: String? = nil

    /// The key that actually opens this person's picture.
    ///
    /// The island no longer holds the key for a picture set under the
    /// profile-key model (docs/profile-key-design.md), so `avatarMediaKey`
    /// arrives nil and the real key is the one its owner sealed to us. Reading
    /// it HERE means every screen that draws a face gets it without a copy of
    /// the fallback each. Still nil for someone who never handed it over -
    /// which draws the same lettered tile as "no picture at all", deliberately
    /// indistinguishable so the tile never becomes an "am I entitled" oracle.
    @MainActor
    var avatarKeyResolved: String? {
        if let k = avatarMediaKey, !k.isEmpty { return k }
        return ProfileKeyStore.shared.key(for: uin)
    }

    var id: Int { uin }

    enum CodingKeys: String, CodingKey {
        case uin, nickname, status
        case statusMessage = "status_message"
        case blocked
        case identityKey = "identity_key"
        case signingKey = "signing_key"
        case signalIdentityKey = "signal_identity_key"
        case gender
        case lastSeen = "last_seen"
        case callable
        case profileOpenable = "profile_openable"
        case host
        case avatarMediaID = "avatar_media_id"
        case avatarMediaKey = "avatar_media_key"
        case badge
    }

    /// Synthetic "Saved Messages" peer — the user's own UIN dressed up
    /// as a Contact so we can reuse the regular `ChatView` /
    /// `MessageService` plumbing without a parallel save-only code
    /// path. Sends to this contact short-circuit at
    /// `MessageService.sendEnvelope` (no network, just a local
    /// MessageStore append + delivered state). Header in `ChatView`
    /// special-cases `uin == ownUIN` to render "Saved Messages"
    /// instead of nickname/UIN.
    static func savedMessagesSelf(ownUIN: Int) -> Contact {
        Contact(
            uin: ownUIN,
            nickname: "Saved Messages",
            status: .online,
            statusMessage: nil,
            blocked: false,
            identityKey: "",
            signingKey: "",
            signalIdentityKey: nil,
            gender: nil,
            unread: 0,
            lastSeen: nil
        )
    }

    /// Minimal placeholder for a blocked UIN we have no contact row for (e.g. a
    /// blocked group member who was never a contact) so it can still appear in
    /// the Blocked list. Display-only; keys are empty (never used to send).
    static func blockedStub(uin: Int) -> Contact {
        Contact(
            uin: uin,
            nickname: "\(uin)",
            status: .offline,
            statusMessage: nil,
            blocked: true,
            identityKey: "",
            signingKey: "",
            signalIdentityKey: nil,
            gender: nil,
            unread: 0,
            lastSeen: nil
        )
    }
}
