import Foundation

enum DeliveryState: String, Codable {
    case sending, sent, delivered, read, failed
}

enum MessageKind: String, Codable {
    case text
    case typing
    case offline           // a marker row indicating "received while you were away"
    case photo             // media bubble; payload references mediaID
    case video             // media bubble with thumbnail + duration; mediaID = video blob
    case voice             // voice message; mediaID = m4a/AAC blob, durationSec = recording length
    case systemNotice      // join/leave/rename/etc, rendered as a centred line
    case deleteForEveryone // tombstone — UI hides the original, peer also deletes
    case premiumPhoto      // paywalled photo — locked until recipient pays via /premium/contents/{id}/unlock
    case premiumVideo      // paywalled video — same model as .premiumPhoto
}

enum ThreadID: Hashable, Codable {
    case peer(uin: Int)
    case group(id: Int)

    var isGroup: Bool { if case .group = self { return true } else { return false } }
    /// Flat key used as a stable hash and CoreData column. Peer threads use the
    /// peer's UIN, group threads use the group ID. We rely on `kindString` to
    /// disambiguate when both spaces could collide (they typically don't, since
    /// group IDs come from a separate sequence, but the explicit kind keeps it safe).
    var rawKey: Int {
        switch self {
        case .peer(let u): return u
        case .group(let g): return g
        }
    }
    var kindString: String { isGroup ? "group" : "peer" }

    static func decode(kindString: String, rawKey: Int) -> ThreadID {
        kindString == "group" ? .group(id: rawKey) : .peer(uin: rawKey)
    }
}

struct Message: Identifiable, Hashable, Codable {
    let id: UUID
    let thread: ThreadID
    /// Whoever actually sent this. For 1:1 messages from us, equals own UIN. For
    /// inbound 1:1, equals peer UIN. For group messages, equals the actual sender
    /// (recovered from the encrypted envelope client-side).
    let senderUIN: Int
    let isFromMe: Bool
    let kind: MessageKind
    let text: String
    /// For `.photo` — server media id. The actual bytes are encrypted, fetched and
    /// decrypted on demand, then cached locally.
    let mediaID: String?
    let sentAt: Date
    var deliveryState: DeliveryState
    var receivedWhileAway: Bool
    /// Set when a deleteForEveryone tombstone arrived for this message. The row
    /// stays in the thread but the renderer shows a placeholder.
    var deletedForEveryone: Bool
    /// Reactions on this message — uin → emoticon asset name. Each user can have
    /// at most one reaction at a time; sending the same reaction toggles it off.
    var reactions: [Int: String]
    /// Base64-encoded JPEG thumbnail for video messages. Embedded inline in the
    /// envelope so the recipient can render the bubble immediately without
    /// fetching the full video file.
    var thumbnailB64: String?
    /// Video duration in seconds, used for the "MM:SS" badge on the bubble.
    var durationSec: Double
    /// Disappearing-message TTL in seconds. Nil means "stick around
    /// forever." Set by `MessageService.send`/`ingest` from either the
    /// envelope's own `ttl` field (sender's setting at send time) or
    /// the recipient's local thread setting as a fallback. The
    /// `MessageStore` sweeper deletes rows where
    /// `sentAt + ttlSeconds < now`.
    var ttlSeconds: Int?
    /// Display name of the original author when this message was
    /// forwarded into the current thread. Nil for first-hand
    /// messages. Carried inside the encrypted envelope so the
    /// recipient sees the original author even though the actual
    /// sender (`senderUIN`) is whoever forwarded. UIN is intentionally
    /// not propagated — the spec asks for nickname-only attribution
    /// so a forwarded message can't double as a contact-discovery
    /// vector.
    var forwardedFromName: String?
    /// When the user wrote this as a reply to another message, the
    /// id of the message they're replying to. Used to scroll the
    /// chat to the original on tap of the quote block. Nil for
    /// non-reply messages. Persisted alongside `replyToSnippet` so
    /// rendering survives app restarts and the original being
    /// deleted later (snippet stays, the bubble just no-longer-
    /// scrolls-on-tap).
    var replyToID: UUID?
    /// Inline preview of the message we're replying to — typically
    /// the first ~80 chars of `text`, or "📷 Photo" / "🎬 Video"
    /// for media. Baked at compose time so we don't have to look up
    /// the original on every render. Nil when not a reply.
    var replyToSnippet: String?
    /// Display name of the author of the message we're replying to.
    /// Same scoping rules as `forwardedFromName` (nickname only, no
    /// UIN). Nil when not a reply.
    var replyToAuthorName: String?
    /// Timestamp of the last edit applied to this message's body
    /// text via the `.edit` envelope. Nil = never edited. UI uses
    /// presence to show the "(edited)" suffix beside the timestamp.
    /// Only text bubbles edit; media captions don't (yet).
    var editedAt: Date?
    /// Token cost the recipient must pay to unlock this message. Set
    /// only on `.premiumPhoto` / `.premiumVideo`. Nil for any
    /// non-premium kind.
    var premiumPriceTokens: Int?
    /// True once we (the local user) have a usable media key for this
    /// premium message. The sender's local copy is always unlocked
    /// (we generated K). Recipients flip this true after a successful
    /// `/premium/contents/{id}/unlock` and the resulting ECIES-unwrap.
    /// Nil-safe default `false` so legacy / non-premium rows aren't
    /// surprised by the field.
    var premiumUnlocked: Bool

    init(
        id: UUID = UUID(),
        thread: ThreadID,
        senderUIN: Int,
        isFromMe: Bool,
        kind: MessageKind = .text,
        text: String,
        mediaID: String? = nil,
        sentAt: Date = Date(),
        deliveryState: DeliveryState = .sending,
        receivedWhileAway: Bool = false,
        deletedForEveryone: Bool = false,
        reactions: [Int: String] = [:],
        thumbnailB64: String? = nil,
        durationSec: Double = 0,
        ttlSeconds: Int? = nil,
        forwardedFromName: String? = nil,
        replyToID: UUID? = nil,
        replyToSnippet: String? = nil,
        replyToAuthorName: String? = nil,
        editedAt: Date? = nil,
        premiumPriceTokens: Int? = nil,
        premiumUnlocked: Bool = false
    ) {
        self.id = id
        self.thread = thread
        self.senderUIN = senderUIN
        self.isFromMe = isFromMe
        self.kind = kind
        self.text = text
        self.mediaID = mediaID
        self.sentAt = sentAt
        self.deliveryState = deliveryState
        self.receivedWhileAway = receivedWhileAway
        self.deletedForEveryone = deletedForEveryone
        self.reactions = reactions
        self.thumbnailB64 = thumbnailB64
        self.durationSec = durationSec
        self.ttlSeconds = ttlSeconds
        self.forwardedFromName = forwardedFromName
        self.replyToID = replyToID
        self.replyToSnippet = replyToSnippet
        self.replyToAuthorName = replyToAuthorName
        self.editedAt = editedAt
        self.premiumPriceTokens = premiumPriceTokens
        self.premiumUnlocked = premiumUnlocked
    }
}
