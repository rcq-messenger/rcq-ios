import Foundation

/// Persistent audio room a user has subscribed to. Mirrors `AudioRoomOut`.
struct AudioRoom: Identifiable, Hashable, Codable {
    let id: Int
    var name: String
    let ownerUIN: Int
    /// 8-char unambiguous-uppercase code shared by the owner.
    let joinKey: String
    let createdAt: Date
    /// Live count of UINs currently inside the voice session.
    var activeCount: Int
    /// When true, non-owner mics are auto-muted client-side. Soft
    /// enforcement — mesh WebRTC means the server can't drop audio.
    var ownerOnlySpeaking: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerUIN = "owner_uin"
        case joinKey = "join_key"
        case createdAt = "created_at"
        case activeCount = "active_count"
        case ownerOnlySpeaking = "owner_only_speaking"
    }
}

/// One participant in the live voice session — roster member, not subscription member.
struct AudioRoomMember: Identifiable, Hashable {
    let uin: Int
    let nickname: String
    /// True while the member's mic is above the local VAD threshold.
    var speaking: Bool = false
    /// True when WE muted ourselves (only meaningful for the local row).
    var localMuted: Bool = false
    var equippedPet: EquippedPet?
    /// Owner muted this user. Muted client honors via `setMicMuted(true)`;
    /// others render a "muted by owner" badge.
    var mutedByOwner: Bool = false

    var id: Int { uin }
}
