import Foundation

struct UserProfile: Codable, Hashable {
    var uin: Int
    var nickname: String
    var firstName: String?
    var lastName: String?
    var age: Int?
    var gender: String?
    var city: String?
    var country: String?
    var about: String?
    var interests: [String]
    var homepage: String?
    var status: UserStatus
    var statusMessage: String?
    var identityKey: String
    var signingKey: String
    var signalIdentityKey: String?
    /// Last-seen ISO-8601 timestamp, filtered server-side by the
    /// target user's `last_seen_visibility` setting. Nil when the
    /// owner has hidden the timestamp from the current viewer
    /// (privacy = "contacts" with non-mutual viewer, or "nobody").
    /// UserInfoView falls back to the status icon when nil.
    var lastSeen: Date?
    /// Owner-only echo of the active visibility setting. Nil for
    /// third-party fetches; populated when fetching one's own
    /// `/users/me` or `/users/{ownUIN}/info` so the Settings picker
    /// can display the current choice without a separate request.
    var lastSeenVisibility: String?
    /// Owner-only echo, same shape as `lastSeenVisibility`. Drives
    /// who can see `gender` on the profile.
    var genderVisibility: String?
    /// Owner-only echo of the group-invite policy.
    /// `everyone` (default) / `contacts` / `nobody`.
    var groupInvitePolicy: String?
    /// Owner-only echo of the trade-policy setting. Same tri-state.
    /// Server-enforced at trade-propose time; iOS surfaces the
    /// picker in Settings.
    var tradePolicy: String?
    /// Owner-only echo of the call-policy setting. Same tri-state.
    /// Hides every call affordance in the caller's own UI when set
    /// to `"nobody"`.
    var callPolicy: String?
    /// Owner-only echo of the read-receipts setting. iOS uses the
    /// cached `@AppStorage("rcq.privacy.readReceiptsVisibility")`
    /// for the send-time gate so MessageService doesn't have to
    /// round-trip `/users/me/info` on every read.
    var readReceiptsVisibility: String?
    /// Snapshot of the user's currently-equipped pet — drives the
    /// small overlay GIF on the status icon throughout the UI
    /// (contact rows, profile header, group info). Always returned;
    /// null = no pet equipped.
    var equippedPet: EquippedPet?

    enum CodingKeys: String, CodingKey {
        case uin, nickname
        case firstName = "first_name"
        case lastName = "last_name"
        case age, gender, city, country, about, interests, homepage
        case status
        case statusMessage = "status_message"
        case identityKey = "identity_key"
        case signingKey = "signing_key"
        case signalIdentityKey = "signal_identity_key"
        case lastSeen = "last_seen"
        case lastSeenVisibility = "last_seen_visibility"
        case genderVisibility = "gender_visibility"
        case groupInvitePolicy = "group_invite_policy"
        case tradePolicy = "trade_policy"
        case callPolicy = "call_policy"
        case readReceiptsVisibility = "read_receipts_visibility"
        case equippedPet = "equipped_pet"
    }
}

struct OwnIdentity: Codable {
    let uin: Int
    var nickname: String
    var status: UserStatus
    var statusMessage: String?
}
