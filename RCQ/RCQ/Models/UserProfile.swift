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
    /// Owner-only echo, follows the `lastSeenVisibility` tri-state.
    /// Gates who can see `gender` on the profile.
    var genderVisibility: String?
    /// Owner-only echo of the profile-card visibility setting. Same
    /// tri-state. Server strips first_name/last_name/age/city/etc.
    /// for outsiders who don't pass the gate.
    var profileVisibility: String?
    /// Owner-only echo of the group-invite policy.
    /// `everyone` (default) / `contacts` / `nobody`.
    var groupInvitePolicy: String?
    /// Owner-only echo of the call-policy setting. Same tri-state.
    /// Hides every call affordance in the caller's own UI when set
    /// to `"nobody"`.
    var callPolicy: String?
    /// Owner-only echo of the read-receipts setting. iOS uses the
    /// cached `@AppStorage("rcq.privacy.readReceiptsVisibility")`
    /// for the send-time gate so MessageService doesn't have to
    /// round-trip `/users/me/info` on every read.
    var readReceiptsVisibility: String?
    /// Opt-in flag: when true, the server keeps broadcasting the
    /// owner's chosen status to contacts even when the WebSocket has
    /// been gone past the staleness threshold. Lets the user appear
    /// "around" with their selected status even when the app is not
    /// running. Owner-only echo, nil for third-party fetches.
    var presencePersistent: Bool?
    /// Optional TTL (minutes) for `presencePersistent`. 0/nil = forever.
    /// Allowed values mirror the iOS picker: 30, 60, 180, 480, 1440.
    var presenceTTLMinutes: Int?
    /// Owner-only echo of the Hall-of-Fame opt-in (consent to be
    /// considered). The founder approves who actually appears on the
    /// public wall; this flag is just the user's consent. Nil for
    /// third-party fetches.
    var hofOptIn: Bool?
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
        case profileVisibility = "profile_visibility"
        case groupInvitePolicy = "group_invite_policy"
        case callPolicy = "call_policy"
        case readReceiptsVisibility = "read_receipts_visibility"
        case presencePersistent = "presence_persistent"
        case presenceTTLMinutes = "presence_ttl_minutes"
        case hofOptIn = "hof_opt_in"
    }
}

struct OwnIdentity: Codable {
    let uin: Int
    var nickname: String
    var status: UserStatus
    var statusMessage: String?
}
