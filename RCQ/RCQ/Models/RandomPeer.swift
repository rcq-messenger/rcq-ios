import Foundation

/// Live anonymous-chat partner. Server gives us this on `random_match` — both
/// sides see the *other* user's identityKey (so they can encrypt envelopes to
/// each other) and a session-scoped pair_id. UIN/nickname are kept in the
/// model for protocol-level operation but stay off the UI: random chat
/// shows "Stranger" until both sides explicitly upgrade to a real
/// contact relationship via the Add-as-contact CTA (Random Chat B).
struct RandomPeer: Hashable, Codable {
    let pairID: String
    let uin: Int
    let nickname: String
    let identityKey: String
    let signingKey: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case pairID = "pair_id"
        case uin, nickname
        case identityKey = "identity_key"
        case signingKey = "signing_key"
        case expiresAt = "expires_at"
    }
}
