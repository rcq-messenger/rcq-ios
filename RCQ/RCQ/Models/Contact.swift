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
    /// `gender_visibility` setting; null = hide. Same shape as
    /// `NearbyPerson.gender` and `HoodMessage.gender` so the
    /// rendering helper can take any of them.
    var gender: String?
    var unread: Int = 0
    /// Tiny snapshot of the contact's currently-equipped pet — drives
    /// the small overlay GIF on top of their status icon in lists.
    /// Populated from server's `equipped_pet` field; null = no pet.
    var equippedPet: EquippedPet?

    var id: Int { uin }

    enum CodingKeys: String, CodingKey {
        case uin, nickname, status
        case statusMessage = "status_message"
        case blocked
        case identityKey = "identity_key"
        case signingKey = "signing_key"
        case signalIdentityKey = "signal_identity_key"
        case gender
        case equippedPet = "equipped_pet"
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
            equippedPet: nil
        )
    }
}
