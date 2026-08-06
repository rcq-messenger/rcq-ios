import Foundation

/// The neutral record that travels in a `.rcqbak`, and the mapping between it
/// and this client's `Message`.
///
/// Kept apart from `BackupService` on purpose: everything here is pure, so it
/// can be exercised without a Core Data stack, a signed-in account or a
/// network. The one bug this format has already produced was a mapping bug
/// that no amount of "it compiles" would have caught.
enum BackupRecordMapping {

    // MARK: - the neutral record

    /// The record that actually travels in the archive.
    ///
    /// Deliberately NOT this client's own model: Android keeps a `ChatMessage`,
    /// the browser keeps its own rows and this one keeps a `Message`, so
    /// writing any of them into the file would make "took it on Android,
    /// restored it on an iPhone" a lie. Every client maps to and from THIS.
    ///
    /// ⚠ Every field is optional, and that is load-bearing rather than tidy. A
    /// writer with nothing to put in a field leaves the key out altogether, and
    /// a reader that falls over an absent key is broken — that exact mistake
    /// made a browser-written archive restore on Android as zero messages with
    /// a success message on screen. Absent reads as empty here.
    struct Record: Codable {
        var id: String?
        var peer: Int?
        var group: Int?
        var from_me: Bool?
        var sender: Int?
        var sent_at: Int64?
        var kind: String?
        var body: String?
        var media_id: String?
        var media_key: String?
        var file_name: String?
        var file_mime: String?
        var file_size: Int64?
        var duration_sec: Double?
        var thumb_b64: String?
        var lat: Double?
        var lng: Double?
        var spoiler: Bool?
        var album_id: String?
        var edited: Bool?
        var reply_to_id: String?
        var reply_to_author: String?
        var reply_to_snippet: String?
        var reactions: [String: String]?
        var expires_at: Int64?
        // Additive, and only this client writes them today. The format says a
        // reader ignores what it does not know, so these cost the other two
        // nothing and stop an iPhone-to-iPhone restore from flattening an edit
        // timestamp, a forward credit or a deletion into ordinary text.
        var edited_at: Int64?
        var forwarded_from: String?
        var deleted_for_everyone: Bool?
        var poll_id: Int?
    }

    /// Android calls a join/leave line `system`; this client calls the same
    /// thing `systemNotice`. Everything else already agrees, and an unknown
    /// kind falls back to text on every client, so this one pair is mapped
    /// rather than left to drift.
    private static func wireKind(_ kind: MessageKind) -> String {
        kind == .systemNotice ? "system" : kind.rawValue
    }

    private static func localKind(_ wire: String?) -> MessageKind {
        guard let wire else { return .text }
        if wire == "system" { return .systemNotice }
        return MessageKind(rawValue: wire) ?? .text
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func toRecord(_ m: Message) -> Record {
        // This client keeps the blob id and its key in one field, joined by a
        // pipe; the archive keeps them apart, the way the other two do.
        var mediaID: String?
        var mediaKey: String?
        if let raw = m.mediaID {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            mediaID = parts.first
            mediaKey = parts.count == 2 ? parts[1] : nil
        }
        var r = Record()
        r.id = m.id.uuidString
        switch m.thread {
        case .peer(let uin): r.peer = uin
        case .group(let id): r.group = id
        }
        r.from_me = m.isFromMe
        // The peer of a 1:1 is already named by `peer`, so the field is left
        // out there and the record reads the same on every client.
        r.sender = m.thread.isGroup ? m.senderUIN : nil
        r.sent_at = ms(m.sentAt)
        r.kind = wireKind(m.kind)
        r.body = m.text
        r.media_id = mediaID
        r.media_key = mediaKey
        r.file_name = m.fileName
        r.file_mime = m.fileMime
        r.file_size = m.fileSizeBytes.map(Int64.init)
        r.duration_sec = m.durationSec > 0 ? m.durationSec : nil
        r.thumb_b64 = m.thumbnailB64
        r.lat = m.latitude
        r.lng = m.longitude
        r.spoiler = m.isSpoiler
        r.album_id = m.albumID?.uuidString
        r.edited = m.editedAt != nil
        r.edited_at = m.editedAt.map(ms)
        r.reply_to_id = m.replyToID?.uuidString
        r.reply_to_author = m.replyToAuthorName
        r.reply_to_snippet = m.replyToSnippet
        // Always written, even empty: a reader meeting an absent field has to
        // guess, and one of them guessed wrong badly enough to drop a file.
        r.reactions = Dictionary(uniqueKeysWithValues: m.reactions.map { (String($0.key), $0.value) })
        r.expires_at = m.ttlSeconds.map { ms(m.sentAt.addingTimeInterval(TimeInterval($0))) }
        r.forwarded_from = m.forwardedFromName
        r.deleted_for_everyone = m.deletedForEveryone ? true : nil
        r.poll_id = m.pollID
        return r
    }

    /// Back into this client's shape, or nil when the line cannot be a message
    /// here at all. Nil rather than a throw: one unreadable record costs that
    /// record and nothing more.
    static func toMessage(_ r: Record, ownUIN: Int) -> Message? {
        guard let idString = r.id, let id = UUID(uuidString: idString) else { return nil }
        // Exactly one of the two is set; a record naming neither thread has
        // nowhere to land and would otherwise show up as a chat with #0.
        let thread: ThreadID
        if let group = r.group {
            thread = .group(id: group)
        } else if let peer = r.peer {
            thread = .peer(uin: peer)
        } else {
            return nil
        }
        let fromMe = r.from_me ?? false
        let sentAt = date(r.sent_at ?? 0)
        let mediaID: String? = {
            guard let id = r.media_id, !id.isEmpty else { return nil }
            guard let key = r.media_key, !key.isEmpty else { return id }
            return "\(id)|\(key)"
        }()
        return Message(
            id: id,
            thread: thread,
            // A 1:1 record has no explicit sender, so it is me or the peer of
            // that thread.
            senderUIN: r.sender ?? (fromMe ? ownUIN : thread.rawKey),
            isFromMe: fromMe,
            kind: localKind(r.kind),
            text: r.body ?? "",
            mediaID: mediaID,
            sentAt: sentAt,
            // Anything restored is history: it either arrived or it was sent
            // long ago, so it is never left looking like it is still on its way.
            deliveryState: .delivered,
            receivedWhileAway: false,
            deletedForEveryone: r.deleted_for_everyone ?? false,
            reactions: Dictionary(
                uniqueKeysWithValues: (r.reactions ?? [:]).compactMap { key, value in
                    Int(key).map { ($0, value) }
                },
            ),
            thumbnailB64: r.thumb_b64,
            durationSec: r.duration_sec ?? 0,
            ttlSeconds: r.expires_at.map { max(1, Int(($0 - ms(sentAt)) / 1000)) },
            forwardedFromName: r.forwarded_from,
            replyToID: r.reply_to_id.flatMap(UUID.init(uuidString:)),
            replyToSnippet: r.reply_to_snippet,
            replyToAuthorName: r.reply_to_author,
            // `edited_at` when a client that keeps one wrote the file, else the
            // send time: the mark matters, the exact minute does not.
            editedAt: r.edited_at.map(date) ?? ((r.edited ?? false) ? sentAt : nil),
            albumID: r.album_id.flatMap(UUID.init(uuidString:)),
            fileName: r.file_name,
            fileMime: r.file_mime,
            fileSizeBytes: r.file_size.map(Int.init),
            latitude: r.lat,
            longitude: r.lng,
            pollID: r.poll_id,
            isSpoiler: r.spoiler ?? false,
        )
    }
}
