import CoreData
import Foundation

/// On-device message history. Server never persists plaintext — all
/// history lives client-side. Programmatic CoreData model (no xcdatamodeld);
/// SQLite store with `FileProtectionType.complete`.
@objc(MessageRecord)
final class MessageRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var threadKind: String           // "peer" | "group"
    @NSManaged var threadKey: Int64             // peer UIN or group ID
    @NSManaged var senderUIN: Int64
    @NSManaged var isFromMe: Bool
    @NSManaged var kind: String
    @NSManaged var text: String
    @NSManaged var mediaID: String?
    @NSManaged var sentAt: Date
    @NSManaged var deliveryState: String
    @NSManaged var receivedWhileAway: Bool
    @NSManaged var deletedForEveryone: Bool
    /// JSON `{ "<uin>": "<asset>" }`. Empty = `{}`.
    @NSManaged var reactionsJSON: String
    @NSManaged var thumbnailB64: String?
    @NSManaged var durationSec: Double
    /// `0` = no expiry (model layer converts to nil).
    @NSManaged var ttlSeconds: Int64
    /// Empty string for first-hand messages ("" → nil on read).
    @NSManaged var forwardedFromName: String?
    @NSManaged var replyToID: UUID?
    @NSManaged var replyToSnippet: String?
    @NSManaged var replyToAuthorName: String?
    /// Last `.edit` timestamp. Nil = never edited.
    @NSManaged var editedAt: Date?
    /// `0` for non-premium rows (normalized to nil on read).
    @NSManaged var premiumPriceTokens: Int64
    /// True once local user has a usable media key (sender always true,
    /// recipients flip after paid unlock).
    @NSManaged var premiumUnlocked: Bool
    /// Same id on every photo/video shipped together so the renderer
    /// can group them into a Telegram-style album cluster. Nil for
    /// stand-alone messages and any media coming from an older client
    /// that didn't know about albumID.
    @NSManaged var albumID: UUID?
    /// File attachment metadata — only populated for `.file` kind.
    @NSManaged var fileName: String?
    @NSManaged var fileMime: String?
    /// `0` = unknown / not-a-file. Stored as Int64 so the CoreData
    /// schema doesn't need an optional-numeric wrapper; the model
    /// layer normalises back to `Int?`.
    @NSManaged var fileSizeBytes: Int64
    /// Lat/lng for `.location` rows. Optional because every other
    /// kind has them as nil. Doubles map cleanly to CoreData.
    @NSManaged var latitude: NSNumber?
    @NSManaged var longitude: NSNumber?
}

@MainActor
final class MessageDB {
    static let shared = MessageDB()

    private let container: NSPersistentContainer
    private var ctx: NSManagedObjectContext { container.viewContext }

    private init() {
        let model = MessageDB.buildModel()
        let container = NSPersistentContainer(name: "RCQHistoryV2", managedObjectModel: model)

        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let storeURL = baseURL.appendingPathComponent("rcq-history-v8.sqlite")
        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.setOption(FileProtectionType.complete as NSObject, forKey: NSPersistentStoreFileProtectionKey)
        desc.shouldAddStoreAsynchronously = false
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]

        var loadFailed = false
        container.loadPersistentStores { _, err in
            if let err {
                print("[MessageDB] load failed: \(err)")
                loadFailed = true
            }
        }
        // If lightweight migration choked (mismatched model vs. on-disk
        // schema after a recent attribute add), every subsequent save
        // would crash — the store is wedged but the container thinks
        // it's loaded. Nuke the SQLite + retry once so the user lands
        // in a working empty-history state instead of a hard crash loop.
        // History loss is the price; the alternative is "uninstall the
        // app" which is strictly worse for testers.
        if loadFailed {
            let dir = storeURL.deletingLastPathComponent()
            let base = storeURL.lastPathComponent
            // SQLite also writes -shm and -wal sidecars; ditch all three
            // so the next attempt doesn't try to re-attach a half-broken
            // journal.
            for name in [base, base + "-shm", base + "-wal"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            container.loadPersistentStores { _, err in
                if let err { print("[MessageDB] reset still failed: \(err)") }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        self.container = container
    }

    // MARK: - schema

    private static func buildModel() -> NSManagedObjectModel {
        func attr(
            _ name: String,
            _ type: NSAttributeType,
            optional: Bool = false,
            defaultValue: Any? = nil,
        ) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            // CoreData lightweight migration REQUIRES either `optional`
            // or a default value when adding a new non-optional
            // attribute to an existing store. Pre-v8 attributes get
            // away without one because they were created with the store
            // — anything appended later must declare a default or the
            // migration fails on first load and every save() crashes.
            if let defaultValue { a.defaultValue = defaultValue }
            return a
        }

        let entity = NSEntityDescription()
        entity.name = "MessageRecord"
        entity.managedObjectClassName = NSStringFromClass(MessageRecord.self)
        entity.properties = [
            attr("id",                 .UUIDAttributeType),
            attr("threadKind",         .stringAttributeType),
            attr("threadKey",          .integer64AttributeType),
            attr("senderUIN",          .integer64AttributeType),
            attr("isFromMe",           .booleanAttributeType),
            attr("kind",               .stringAttributeType),
            attr("text",               .stringAttributeType),
            attr("mediaID",            .stringAttributeType, optional: true),
            attr("sentAt",             .dateAttributeType),
            attr("deliveryState",      .stringAttributeType),
            attr("receivedWhileAway",  .booleanAttributeType),
            attr("deletedForEveryone", .booleanAttributeType),
            attr("reactionsJSON",      .stringAttributeType),
            attr("thumbnailB64",       .stringAttributeType, optional: true),
            attr("durationSec",        .doubleAttributeType),
            attr("ttlSeconds",         .integer64AttributeType),
            attr("forwardedFromName",  .stringAttributeType, optional: true),
            attr("replyToID",          .UUIDAttributeType, optional: true),
            attr("replyToSnippet",     .stringAttributeType, optional: true),
            attr("replyToAuthorName",  .stringAttributeType, optional: true),
            attr("editedAt",           .dateAttributeType, optional: true),
            attr("premiumPriceTokens", .integer64AttributeType),
            attr("premiumUnlocked",    .booleanAttributeType),
            attr("albumID",            .UUIDAttributeType, optional: true),
            attr("fileName",           .stringAttributeType, optional: true),
            attr("fileMime",           .stringAttributeType, optional: true),
            attr("fileSizeBytes",      .integer64AttributeType, defaultValue: 0),
            attr("latitude",           .doubleAttributeType, optional: true),
            attr("longitude",          .doubleAttributeType, optional: true),
        ]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    // MARK: - CRUD

    func fetchAll() -> [Message] {
        let req = NSFetchRequest<MessageRecord>(entityName: "MessageRecord")
        req.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: true)]
        let rows = (try? ctx.fetch(req)) ?? []
        return rows.map(Self.toModel)
    }

    func insert(_ msg: Message) {
        // Idempotent — CoreData has no implicit unique constraint on `id`.
        if find(id: msg.id) != nil { return }
        let row = MessageRecord(context: ctx)
        Self.apply(msg, to: row)
        save()
    }

    func updateState(id: UUID, state: DeliveryState) {
        guard let row = find(id: id) else { return }
        row.deliveryState = state.rawValue
        save()
    }

    func updateMediaID(id: UUID, mediaID: String) {
        guard let row = find(id: id) else { return }
        row.mediaID = mediaID
        save()
    }

    /// Splices the recovered mediaKey into `mediaID` (was `<id>|`) and
    /// flips `premiumUnlocked` so re-launches render without re-charging.
    func updatePremiumUnlocked(id: UUID, mediaID: String) {
        guard let row = find(id: id) else { return }
        row.mediaID = mediaID
        row.premiumUnlocked = true
        save()
    }

    func updateVideoMeta(id: UUID, thumbnailB64: String, durationSec: Double) {
        guard let row = find(id: id) else { return }
        row.thumbnailB64 = thumbnailB64
        row.durationSec = durationSec
        save()
    }

    func updateText(id: UUID, text: String, editedAt: Date) {
        guard let row = find(id: id) else { return }
        row.text = text
        row.editedAt = editedAt
        save()
    }

    func updateReactions(id: UUID, reactions: [Int: String]) {
        guard let row = find(id: id) else { return }
        row.reactionsJSON = Self.encodeReactions(reactions)
        save()
    }

    func markDeletedForEveryone(id: UUID) {
        guard let row = find(id: id) else { return }
        row.deletedForEveryone = true
        row.text = ""
        row.mediaID = nil
        save()
    }

    func deleteRow(id: UUID) {
        guard let row = find(id: id) else { return }
        ctx.delete(row)
        save()
    }

    func deleteThread(_ thread: ThreadID) {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "MessageRecord")
        req.predicate = NSPredicate(
            format: "threadKind == %@ AND threadKey == %lld",
            thread.kindString, Int64(thread.rawKey)
        )
        let delete = NSBatchDeleteRequest(fetchRequest: req)
        _ = try? ctx.execute(delete)
        save()
    }

    func deleteAll() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "MessageRecord")
        let delete = NSBatchDeleteRequest(fetchRequest: req)
        _ = try? ctx.execute(delete)
        save()
    }

    // MARK: - helpers

    private func find(id: UUID) -> MessageRecord? {
        let req = NSFetchRequest<MessageRecord>(entityName: "MessageRecord")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    private func save() {
        guard ctx.hasChanges else { return }
        do { try ctx.save() } catch { print("[MessageDB] save failed: \(error)") }
    }

    private static func apply(_ msg: Message, to row: MessageRecord) {
        row.id = msg.id
        row.threadKind = msg.thread.kindString
        row.threadKey = Int64(msg.thread.rawKey)
        row.senderUIN = Int64(msg.senderUIN)
        row.isFromMe = msg.isFromMe
        row.kind = msg.kind.rawValue
        row.text = msg.text
        row.mediaID = msg.mediaID
        row.sentAt = msg.sentAt
        row.deliveryState = msg.deliveryState.rawValue
        row.receivedWhileAway = msg.receivedWhileAway
        row.deletedForEveryone = msg.deletedForEveryone
        row.reactionsJSON = encodeReactions(msg.reactions)
        row.thumbnailB64 = msg.thumbnailB64
        row.durationSec = msg.durationSec
        row.ttlSeconds = Int64(msg.ttlSeconds ?? 0)
        row.forwardedFromName = msg.forwardedFromName
        row.replyToID = msg.replyToID
        row.replyToSnippet = msg.replyToSnippet
        row.replyToAuthorName = msg.replyToAuthorName
        row.editedAt = msg.editedAt
        row.premiumPriceTokens = Int64(msg.premiumPriceTokens ?? 0)
        row.premiumUnlocked = msg.premiumUnlocked
        row.albumID = msg.albumID
        row.fileName = msg.fileName
        row.fileMime = msg.fileMime
        row.fileSizeBytes = Int64(msg.fileSizeBytes ?? 0)
        row.latitude = msg.latitude.map { NSNumber(value: $0) }
        row.longitude = msg.longitude.map { NSNumber(value: $0) }
    }

    private static func toModel(_ row: MessageRecord) -> Message {
        Message(
            id: row.id,
            thread: ThreadID.decode(kindString: row.threadKind, rawKey: Int(row.threadKey)),
            senderUIN: Int(row.senderUIN),
            isFromMe: row.isFromMe,
            kind: MessageKind(rawValue: row.kind) ?? .text,
            text: row.text,
            mediaID: row.mediaID,
            sentAt: row.sentAt,
            deliveryState: DeliveryState(rawValue: row.deliveryState) ?? .delivered,
            receivedWhileAway: row.receivedWhileAway,
            deletedForEveryone: row.deletedForEveryone,
            reactions: decodeReactions(row.reactionsJSON),
            thumbnailB64: row.thumbnailB64,
            durationSec: row.durationSec,
            ttlSeconds: row.ttlSeconds > 0 ? Int(row.ttlSeconds) : nil,
            forwardedFromName: (row.forwardedFromName?.isEmpty == false) ? row.forwardedFromName : nil,
            replyToID: row.replyToID,
            replyToSnippet: (row.replyToSnippet?.isEmpty == false) ? row.replyToSnippet : nil,
            replyToAuthorName: (row.replyToAuthorName?.isEmpty == false) ? row.replyToAuthorName : nil,
            editedAt: row.editedAt,
            premiumPriceTokens: row.premiumPriceTokens > 0 ? Int(row.premiumPriceTokens) : nil,
            premiumUnlocked: row.premiumUnlocked,
            albumID: row.albumID,
            fileName: (row.fileName?.isEmpty == false) ? row.fileName : nil,
            fileMime: (row.fileMime?.isEmpty == false) ? row.fileMime : nil,
            fileSizeBytes: row.fileSizeBytes > 0 ? Int(row.fileSizeBytes) : nil,
            latitude: row.latitude?.doubleValue,
            longitude: row.longitude?.doubleValue
        )
    }

    static func encodeReactions(_ reactions: [Int: String]) -> String {
        let stringKeyed = Dictionary(uniqueKeysWithValues: reactions.map { (String($0.key), $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: stringKeyed) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeReactions(_ s: String) -> [Int: String] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        var out: [Int: String] = [:]
        for (k, v) in obj {
            if let uin = Int(k) { out[uin] = v }
        }
        return out
    }
}
