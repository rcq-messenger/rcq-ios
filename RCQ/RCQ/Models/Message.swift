import Foundation

enum DeliveryState: String, Codable {
    case sending, sent, delivered, read, failed
}

enum MessageKind: String, Codable {
    case text
    case typing
    case offline           // marker: "received while you were away"
    case photo
    case video
    case voice             // m4a/AAC blob, durationSec = recording length
    case file              // arbitrary attachment (pdf/docx/zip/…), filename+mime in Message
    case location          // static lat/lng pinned location; coords on Message
    case systemNotice      // join/leave/rename, rendered as centred line
    case deleteForEveryone // tombstone
    case poll              // group poll: pollID + JSON-encoded {question, options, ...} in `text`
}

enum ThreadID: Hashable, Codable {
    case peer(uin: Int)
    case group(id: Int)

    var isGroup: Bool { if case .group = self { return true } else { return false } }
    /// Flat key for hashing + CoreData. `kindString` disambiguates peer
    /// UIN vs group ID since both are Int.
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
    /// Actual sender — own UIN for outbound, peer UIN for inbound 1:1,
    /// real sender for groups (recovered from envelope).
    let senderUIN: Int
    let isFromMe: Bool
    let kind: MessageKind
    let text: String
    /// Server media id. Bytes are encrypted, fetched + decrypted on demand.
    /// `var` (not `let`) so optimistic-send paths can patch in the
    /// real id once the upload settles, without rebuilding the whole
    /// struct and risking a dropped field.
    var mediaID: String?
    let sentAt: Date
    var deliveryState: DeliveryState
    var receivedWhileAway: Bool
    /// Set on deleteForEveryone tombstone — row stays, renderer shows placeholder.
    var deletedForEveryone: Bool
    /// uin → emoticon asset name. One reaction per user.
    var reactions: [Int: String]
    /// Base64 JPEG thumbnail for video messages, inline in the envelope.
    var thumbnailB64: String?
    var durationSec: Double
    /// Disappearing-message TTL. Nil = no expiry. `MessageStore` sweeper
    /// drops rows where `sentAt + ttlSeconds < now`.
    var ttlSeconds: Int?
    /// Original author's display name for forwarded messages. Nickname-only
    /// per spec — forwarding can't double as a contact-discovery vector.
    var forwardedFromName: String?
    /// Reply target id. Persisted with `replyToSnippet` so rendering
    /// survives the original being deleted (quote stays, tap-to-scroll
    /// stops working).
    var replyToID: UUID?
    /// Inline preview of the replied-to message, captured at compose time.
    var replyToSnippet: String?
    var replyToAuthorName: String?
    /// Last `.edit` envelope timestamp. Nil = never edited.
    var editedAt: Date?
    /// Shared id for media sent in one batch (multi-pick from gallery
    /// or camera). Same id on every photo/video the sender shipped
    /// together, nil for stand-alone messages. Renderer groups
    /// consecutive same-album messages into a Telegram-style cluster.
    var albumID: UUID?
    /// File-attachment metadata — populated only for `.file` kind.
    /// `fileName` is the user-visible name (with extension).
    /// `fileMime` is the MIME type as reported by the picker, used to
    /// pick the right open-with renderer on the receiving side.
    /// `fileSizeBytes` is the plaintext size before encryption.
    var fileName: String?
    var fileMime: String?
    var fileSizeBytes: Int?
    /// Coordinates for `.location` messages. Both nil for any other
    /// kind. `nil`-meaning is "no location attached" — receivers
    /// gracefully render a placeholder if a `.location` row somehow
    /// drops in without both.
    var latitude: Double?
    var longitude: Double?
    /// Server-side poll id for `.poll` messages. Drives the
    /// vote/close round-trips. The actual question + options live
    /// in `text` as JSON (PollPayload). Nil for other kinds.
    var pollID: Int?

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
        albumID: UUID? = nil,
        fileName: String? = nil,
        fileMime: String? = nil,
        fileSizeBytes: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        pollID: Int? = nil
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
        self.albumID = albumID
        self.fileName = fileName
        self.fileMime = fileMime
        self.fileSizeBytes = fileSizeBytes
        self.latitude = latitude
        self.longitude = longitude
        self.pollID = pollID
    }
}
