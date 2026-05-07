import Foundation

/// Persistent audio room a user has subscribed to. Wire model lines up
/// 1:1 with FastAPI `AudioRoomOut`. Listed in the "Audio Rooms" section
/// on the home screen; tapping opens `AudioRoomScreen` and joins the
/// live mesh voice session.
struct AudioRoom: Identifiable, Hashable, Codable {
    let id: Int
    /// Mutable so the owner can rename the room without us
    /// rebuilding the cached row from scratch — `applyRename` patches
    /// it in place in the `rooms` array.
    var name: String
    let ownerUIN: Int
    /// 8-char unambiguous-uppercase code. Owner shares this with anyone
    /// they want in the room — pasting it into the Join sheet adds the
    /// room to the joiner's home-screen list.
    let joinKey: String
    let createdAt: Date
    /// Live count of UINs currently inside the voice session. Updates
    /// as `room_member_entered` / `room_member_left` events arrive.
    var activeCount: Int
    /// Owner-only-speaking mode. When true, non-owner mics are
    /// auto-muted client-side (the toolbar mic toggle is disabled
    /// for non-owners while this is on). Toggled via the room's
    /// "Mute all" button — owner-only.
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

/// One participant currently in the live voice session of a room.
/// Roster member, not subscription member — comes from the WS
/// `room_roster` / `room_member_entered` events, not from the DB.
struct AudioRoomMember: Identifiable, Hashable {
    let uin: Int
    let nickname: String
    /// True while the member's microphone is above the local VAD
    /// threshold. Drives the speaking ring around their avatar.
    var speaking: Bool = false
    /// True when WE muted ourselves (only meaningful for the local
    /// member's row — others never set this from the network).
    var localMuted: Bool = false
    /// Pet equipped by this member at roster time. Drives the small
    /// glyph next to the audio-room tile (same affordance as the
    /// home-screen contact list and group-info rows). Nil when the
    /// member doesn't have a pet equipped.
    var equippedPet: EquippedPet?
    /// True when the room owner has muted this user via the
    /// quick-actions sheet. The muted user's own client honors
    /// this by flipping `setMicMuted(true)`; other members render
    /// a "muted by owner" badge on the tile. Soft enforcement —
    /// mesh WebRTC means the server can't drop their audio.
    var mutedByOwner: Bool = false

    var id: Int { uin }
}
