import CoreData
import CryptoKit
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
    /// Deleted by the user on this device: hidden from every read, id kept so a
    /// re-delivered copy is still recognised. See the model note in `buildModel`.
    @NSManaged var deletedLocally: Bool
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
    /// Server-side poll id for `.poll` messages. `0` for non-poll
    /// rows; the model layer normalises back to `Int?`. Without
    /// this, polls restored from CoreData lost their server id and
    /// the bubble couldn't close / refetch tallies — the Close
    /// button rendered but the tap silently no-op'd because
    /// `message.pollID` was nil.
    @NSManaged var pollID: Int64
    /// Sender-flagged spoiler media (blur until tapped). `false`
    /// default keeps lightweight migration happy on existing stores.
    @NSManaged var isSpoiler: Bool
}

@MainActor
final class MessageDB {
    static let shared = MessageDB()

    private static let sentinel = "\u{1}\u{1}RCQE"

    private var dataKey: SymmetricKey?
    private var decoyMode: Bool = false

    private var container: NSPersistentContainer
    private var ctx: NSManagedObjectContext { container.viewContext }

    private init() {
        container = MessageDB.makeContainer(decoy: false)
    }

    func configure(decoy: Bool, dataKey: SymmetricKey?) {
        self.dataKey = dataKey
        if decoy != decoyMode {
            decoyMode = decoy
            container = MessageDB.makeContainer(decoy: decoy)
        }
    }

    /// Reopen the persistent container at whatever per-account
    /// SQLite path the AppGroup file currently points at. Called by
    /// AppState during a soft account switch — AccountManager has
    /// already flipped the active ID + App Group file, so
    /// `makeContainer` resolves to the new account's file. The old
    /// container is dropped; its file stays on disk untouched
    /// because per-account files are isolated.
    func reload() {
        container = MessageDB.makeContainer(decoy: decoyMode)
    }

    // MARK: - store files

    private static func storeURL(decoy: Bool) -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        // Decoy mode stays a single global store regardless of how
        // many real accounts the device has. The panic-PIN escape
        // is an app-lock concept, not a per-account one — switching
        // accounts doesn't expose a different decoy.
        if decoy {
            return baseURL.appendingPathComponent("rcq-history-decoy-v8.sqlite")
        }

        // Real mode: file is per-account. AccountManager mints
        // Account[0] before any MessageDB access in RCQApp.init's
        // eager-touch order, so this should always find a non-nil
        // ID once the user is past first-launch.
        guard let accountID = AppGroup.readActiveAccountID() else {
            // Pre-onboarding state on a truly fresh install. Fall
            // through to the legacy filename so a brand-new device
            // gets a working SQLite to write into; the first
            // post-onboarding launch will then carry it across
            // via the migration block below once Account[0] exists.
            return baseURL.appendingPathComponent("rcq-history-v8.sqlite")
        }

        let perAccountName = "rcq-history-\(accountID.uuidString)-v8.sqlite"
        let perAccountURL = baseURL.appendingPathComponent(perAccountName)

        // First-launch-after-v0.3 migration: if a legacy unprefixed
        // file exists and the per-account file doesn't, rename the
        // legacy file to belong to the active account. SQLite writes
        // -shm and -wal sidecars alongside the main file — move all
        // three so the journal stays consistent with the data. Each
        // FileManager.moveItem call is atomic per-file (POSIX
        // rename); a half-completed migration where only the main
        // file moved still works because SQLite recreates missing
        // sidecars on next open.
        let legacyURL = baseURL.appendingPathComponent("rcq-history-v8.sqlite")
        if !FileManager.default.fileExists(atPath: perAccountURL.path),
           FileManager.default.fileExists(atPath: legacyURL.path) {
            for suffix in ["", "-shm", "-wal"] {
                let from = baseURL.appendingPathComponent("rcq-history-v8.sqlite" + suffix)
                let to = baseURL.appendingPathComponent(perAccountName + suffix)
                try? FileManager.default.moveItem(at: from, to: to)
            }
        }
        return perAccountURL
    }

    static func destroyDecoyStore() {
        let url = storeURL(decoy: true)
        let dir = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        for name in [base, base + "-shm", base + "-wal"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Delete the per-account history file for a given account ID.
    /// Used by the burn-account flow (S3+) so removing one account
    /// from the roster wipes its chat history without touching any
    /// other account. SQLite writes -shm and -wal sidecars, all
    /// three get removed.
    static func wipe(accountID: UUID) {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = "rcq-history-\(accountID.uuidString)-v8.sqlite"
        for name in [base, base + "-shm", base + "-wal"] {
            try? FileManager.default.removeItem(at: baseURL.appendingPathComponent(name))
        }
    }

    private static let model: NSManagedObjectModel = buildModel()

    /// The ONE model instance. A second `NSManagedObjectModel` built from the
    /// same description would make CoreData complain that two entities claim
    /// `MessageRecord`, so any other container (the decoy seeder) reuses this.
    static var sharedModel: NSManagedObjectModel { model }

    /// File the decoy history lives in. Exposed so the seeder can open its OWN
    /// container on it: `MessageDB.shared` is a singleton whose
    /// `configure(decoy:)` flips the container globally, and any inbound
    /// WebSocket write during that window would land in the decoy store.
    static func decoyStoreURL() -> URL { storeURL(decoy: true) }

    private static func makeContainer(decoy: Bool) -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "RCQHistoryV2", managedObjectModel: model)

        let storeURL = MessageDB.storeURL(decoy: decoy)
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
            // ⚠⚠ THE DECOY ROSTER GOES WITH IT. The decoy's contact list lives
            // in a SEPARATE file that this reset never touched, so clearing the
            // history alone left a decoy session showing the seeded names with
            // every conversation empty — and it stayed that way, because
            // nothing reseeds on its own. A decoy that lies about having been
            // used is worse than one that is plainly empty: no real account
            // looks like a roster of people you have never exchanged a word
            // with. Losing the seed asks the user to pick again; keeping half
            // of it hands the coercer the tell.
            if decoy {
                DecoySeedStore.destroy()
            }
            container.loadPersistentStores { _, err in
                if let err { print("[MessageDB] reset still failed: \(err)") }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }

    // MARK: - field encryption

    private func encField(_ s: String?) -> String? {
        Self.sealField(s, key: dataKey)
    }

    /// Field sealing with an EXPLICIT key, so a writer that is not the
    /// singleton (the decoy seeder) encrypts rows exactly the way the singleton
    /// would, under the key it was handed. Nil key = plaintext passthrough,
    /// matching the no-PIN case.
    static func sealField(_ s: String?, key: SymmetricKey?) -> String? {
        guard let s else { return nil }
        guard let key else { return s }
        if s.hasPrefix(sentinel) { return s }
        guard let pt = s.data(using: .utf8),
              let box = try? AES.GCM.seal(pt, using: key),
              let combined = box.combined else { return s }
        return sentinel + combined.base64EncodedString()
    }

    private func decField(_ s: String?) -> String? {
        guard let s else { return nil }
        guard s.hasPrefix(Self.sentinel) else { return s }
        return unseal(s)
    }

    private func unseal(_ stored: String) -> String {
        guard let dataKey else { return "" }
        let b64 = String(stored.dropFirst(Self.sentinel.count))
        guard let combined = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let pt = try? AES.GCM.open(box, using: dataKey),
              let s = String(data: pt, encoding: .utf8) else { return "" }
        return s
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
            // Deleted by the user on THIS device. The row stays, hidden from
            // every read, because the id in the database IS the dedup:
            // `insert` skips an id it already has. Removing the row threw
            // that away, and every envelope is offered to the client at
            // least twice by design (a carbon of your own send, plus the
            // at-least-once queue drain), so a deleted message had a
            // delivery path waiting for it. That was report #415: it came
            // back after a restart, unread, and in its pre-edit wording
            // because edits are never carboned. Additive with a default so
            // lightweight migration keeps existing history.
            attr("deletedLocally",     .booleanAttributeType, defaultValue: false),
            attr("reactionsJSON",      .stringAttributeType),
            attr("thumbnailB64",       .stringAttributeType, optional: true),
            attr("durationSec",        .doubleAttributeType),
            attr("ttlSeconds",         .integer64AttributeType),
            attr("forwardedFromName",  .stringAttributeType, optional: true),
            attr("replyToID",          .UUIDAttributeType, optional: true),
            attr("replyToSnippet",     .stringAttributeType, optional: true),
            attr("replyToAuthorName",  .stringAttributeType, optional: true),
            attr("editedAt",           .dateAttributeType, optional: true),
            attr("albumID",            .UUIDAttributeType, optional: true),
            attr("fileName",           .stringAttributeType, optional: true),
            attr("fileMime",           .stringAttributeType, optional: true),
            attr("fileSizeBytes",      .integer64AttributeType, defaultValue: 0),
            attr("latitude",           .doubleAttributeType, optional: true),
            attr("longitude",          .doubleAttributeType, optional: true),
            // `0` default keeps lightweight migration happy on
            // existing stores — non-poll rows just hold 0, the
            // model layer surfaces it as nil.
            attr("pollID",             .integer64AttributeType, defaultValue: 0),
            attr("isSpoiler",          .booleanAttributeType, defaultValue: false),
        ]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    // MARK: - CRUD

    func fetchAll() -> [Message] {
        let req = NSFetchRequest<MessageRecord>(entityName: "MessageRecord")
        // Tombstoned rows are excluded here as well: this feeds the backup
        // export, and a message the user deleted must not reappear because they
        // exported and restored their own history.
        req.predicate = NSPredicate(format: "deletedLocally == NO")
        req.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: true)]
        let rows = (try? ctx.fetch(req)) ?? []
        return rows.map(toModel)
    }

    /// All distinct (kind, key) thread identifiers present in storage.
    /// Used by `MessageStore.rehydrate` to know which threads need a
    /// tail window loaded.
    func fetchThreadIDs() -> [ThreadID] {
        let req = NSFetchRequest<NSDictionary>(entityName: "MessageRecord")
        req.resultType = .dictionaryResultType
        req.returnsDistinctResults = true
        req.propertiesToFetch = ["threadKind", "threadKey"]
        guard let rows = try? ctx.fetch(req) else { return [] }
        var out: [ThreadID] = []
        for row in rows {
            guard
                let kind = row["threadKind"] as? String,
                let key = (row["threadKey"] as? NSNumber)?.int64Value
            else { continue }
            if kind == "peer" {
                out.append(.peer(uin: Int(key)))
            } else if kind == "group" {
                out.append(.group(id: Int(key)))
            }
        }
        return out
    }

    /// Last `limit` messages for a thread, ordered oldest → newest so
    /// the caller can append directly to a chat-style list. Pagination
    /// anchor for older fetches.
    func fetchRecent(thread: ThreadID, limit: Int) -> [Message] {
        let req = NSFetchRequest<MessageRecord>(entityName: "MessageRecord")
        req.predicate = threadPredicate(thread)
        // Sort DESC then reverse so SQLite uses an index and we still
        // get the most-recent rows truncated by fetchLimit.
        req.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: false)]
        req.fetchLimit = limit
        let rows = (try? ctx.fetch(req)) ?? []
        return rows.reversed().map(toModel)
    }

    /// Older messages strictly before `before`. Used by the chat's
    /// scroll-up "load earlier" path.
    func fetchOlder(thread: ThreadID, before: Date, limit: Int) -> [Message] {
        let req = NSFetchRequest<MessageRecord>(entityName: "MessageRecord")
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            threadPredicate(thread),
            NSPredicate(format: "sentAt < %@", before as NSDate),
        ])
        req.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: false)]
        req.fetchLimit = limit
        let rows = (try? ctx.fetch(req)) ?? []
        return rows.reversed().map(toModel)
    }

    /// Whether at least one row exists for the thread older than `before`.
    /// Drives the "show load-more hint at the top" affordance.
    func hasOlder(thread: ThreadID, before: Date) -> Bool {
        let req = NSFetchRequest<MessageRecord>(entityName: "MessageRecord")
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            threadPredicate(thread),
            NSPredicate(format: "sentAt < %@", before as NSDate),
        ])
        req.fetchLimit = 1
        return ((try? ctx.count(for: req)) ?? 0) > 0
    }

    /// Every thread read goes through here, which is why the locally-deleted
    /// filter lives here too: a tombstoned row must be invisible to the chat,
    /// to "load earlier" and to the load-more hint, and adding the clause at
    /// each call site is how one of them ends up forgotten.
    private func threadPredicate(_ thread: ThreadID) -> NSPredicate {
        let notDeleted = NSPredicate(format: "deletedLocally == NO")
        switch thread {
        case .peer(let uin):
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "threadKind == %@ AND threadKey == %d", "peer", Int64(uin)),
                notDeleted,
            ])
        case .group(let id):
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "threadKind == %@ AND threadKey == %d", "group", Int64(id)),
                notDeleted,
            ])
        }
    }

    func insert(_ msg: Message) {
        // Idempotent — CoreData has no implicit unique constraint on `id`.
        if find(id: msg.id) != nil { return }
        let row = MessageRecord(context: ctx)
        apply(msg, to: row)
        save()
    }

    /// Same insert, but says whether the row was new. A restore has to tell
    /// "added" from "already here" against the WHOLE store rather than against
    /// the in-memory window `MessageStore` keeps, which is only the last
    /// hundred rows per thread and would call an old message new.
    @discardableResult
    func insertIfAbsent(_ msg: Message) -> Bool {
        if find(id: msg.id) != nil { return false }
        let row = MessageRecord(context: ctx)
        apply(msg, to: row)
        save()
        return true
    }

    func updateState(id: UUID, state: DeliveryState) {
        guard let row = find(id: id) else { return }
        row.deliveryState = state.rawValue
        save()
    }

    func updateMediaID(id: UUID, mediaID: String) {
        guard let row = find(id: id) else { return }
        row.mediaID = encField(mediaID)
        save()
    }

    func updateVideoMeta(id: UUID, thumbnailB64: String, durationSec: Double) {
        guard let row = find(id: id) else { return }
        row.thumbnailB64 = encField(thumbnailB64)
        row.durationSec = durationSec
        save()
    }

    func updateText(id: UUID, text: String, editedAt: Date) {
        guard let row = find(id: id) else { return }
        row.text = encField(text) ?? ""
        row.editedAt = editedAt
        save()
    }

    func updateReactions(id: UUID, reactions: [Int: String]) {
        guard let row = find(id: id) else { return }
        row.reactionsJSON = encField(Self.encodeReactions(reactions)) ?? "{}"
        save()
    }

    /// Apply one person's reaction straight to the stored row, for a message
    /// that is not in memory.
    ///
    /// Only the most recent `MessageStore.initialWindowSize` messages of a
    /// thread are held in memory, so a reaction to anything older than that
    /// found nothing to apply itself to and was dropped on the floor — not
    /// shown, and not written down either, so scrolling up never revealed it.
    /// The row is still in the database, which is where this puts it.
    /// Returns false when there is no such row or the value is unchanged.
    @discardableResult
    func mergeReaction(id: UUID, uin: Int, asset: String?) -> Bool {
        guard let row = find(id: id) else { return false }
        var reactions = Self.decodeReactions(decField(row.reactionsJSON) ?? "{}")
        guard reactions[uin] != asset else { return false }
        if let asset {
            reactions[uin] = asset
        } else {
            reactions.removeValue(forKey: uin)
        }
        row.reactionsJSON = encField(Self.encodeReactions(reactions)) ?? "{}"
        save()
        return true
    }

    func markDeletedForEveryone(id: UUID) {
        guard let row = find(id: id) else { return }
        row.deletedForEveryone = true
        row.text = ""
        row.mediaID = nil
        save()
    }

    /// Hide a message the user deleted, keeping its id so a re-delivered copy
    /// is still recognised as known. See the `deletedLocally` note in the model.
    func markDeletedLocally(id: UUID) {
        guard let row = find(id: id) else { return }
        row.deletedLocally = true
        row.text = ""
        row.mediaID = nil
        save()
    }

    /// Hard delete. Only for rows whose own lifetime ended: a disappearing
    /// message that reached its TTL, or a whole thread being cleared. Those are
    /// not user deletions of a single message, and tombstoning them would grow
    /// the table by every disappearing message the account ever received.
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

    // MARK: - encrypt / decrypt migration

    func reencryptAllRows(toPlaintext: Bool = false) async {
        guard dataKey != nil else { return }
        let req = NSFetchRequest<MessageRecord>(entityName: "MessageRecord")
        let rows = (try? ctx.fetch(req)) ?? []
        for row in rows {
            let transform: (String?) -> String? = toPlaintext ? decField : encField
            row.text             = transform(row.text) ?? ""
            row.mediaID          = transform(row.mediaID)
            row.thumbnailB64     = transform(row.thumbnailB64)
            row.reactionsJSON    = transform(row.reactionsJSON) ?? "{}"
            row.forwardedFromName = transform(row.forwardedFromName)
            row.replyToSnippet   = transform(row.replyToSnippet)
            row.replyToAuthorName = transform(row.replyToAuthorName)
            row.fileName         = transform(row.fileName)
        }
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

    private func apply(_ msg: Message, to row: MessageRecord) {
        Self.apply(msg, to: row, key: dataKey)
    }

    /// Row population with an EXPLICIT key. Same reason as `sealField`: the
    /// decoy seeder must write rows byte-identical in shape to the ones the
    /// singleton writes, without the singleton's key or its container.
    static func apply(_ msg: Message, to row: MessageRecord, key: SymmetricKey?) {
        row.id = msg.id
        row.threadKind = msg.thread.kindString
        row.threadKey = Int64(msg.thread.rawKey)
        row.senderUIN = Int64(msg.senderUIN)
        row.isFromMe = msg.isFromMe
        row.kind = msg.kind.rawValue
        row.text = sealField(msg.text, key: key) ?? ""
        row.mediaID = sealField(msg.mediaID, key: key)
        row.sentAt = msg.sentAt
        row.deliveryState = msg.deliveryState.rawValue
        row.receivedWhileAway = msg.receivedWhileAway
        row.deletedForEveryone = msg.deletedForEveryone
        row.reactionsJSON = sealField(encodeReactions(msg.reactions), key: key) ?? "{}"
        row.thumbnailB64 = sealField(msg.thumbnailB64, key: key)
        row.durationSec = msg.durationSec
        row.ttlSeconds = Int64(msg.ttlSeconds ?? 0)
        row.forwardedFromName = sealField(msg.forwardedFromName, key: key)
        row.replyToID = msg.replyToID
        row.replyToSnippet = sealField(msg.replyToSnippet, key: key)
        row.replyToAuthorName = sealField(msg.replyToAuthorName, key: key)
        row.editedAt = msg.editedAt
        row.albumID = msg.albumID
        row.fileName = sealField(msg.fileName, key: key)
        row.fileMime = msg.fileMime
        row.fileSizeBytes = Int64(msg.fileSizeBytes ?? 0)
        row.latitude = msg.latitude.map { NSNumber(value: $0) }
        row.longitude = msg.longitude.map { NSNumber(value: $0) }
        row.pollID = Int64(msg.pollID ?? 0)
        row.isSpoiler = msg.isSpoiler
    }

    private func toModel(_ row: MessageRecord) -> Message {
        let fwd = decField(row.forwardedFromName)
        let replySnippet = decField(row.replyToSnippet)
        let replyAuthor = decField(row.replyToAuthorName)
        let fileName = decField(row.fileName)
        return Message(
            id: row.id,
            thread: ThreadID.decode(kindString: row.threadKind, rawKey: Int(row.threadKey)),
            senderUIN: Int(row.senderUIN),
            isFromMe: row.isFromMe,
            kind: MessageKind(rawValue: row.kind) ?? .text,
            text: decField(row.text) ?? "",
            mediaID: decField(row.mediaID),
            sentAt: row.sentAt,
            deliveryState: DeliveryState(rawValue: row.deliveryState) ?? .delivered,
            receivedWhileAway: row.receivedWhileAway,
            deletedForEveryone: row.deletedForEveryone,
            reactions: Self.decodeReactions(decField(row.reactionsJSON) ?? "{}"),
            thumbnailB64: decField(row.thumbnailB64),
            durationSec: row.durationSec,
            ttlSeconds: row.ttlSeconds > 0 ? Int(row.ttlSeconds) : nil,
            forwardedFromName: (fwd?.isEmpty == false) ? fwd : nil,
            replyToID: row.replyToID,
            replyToSnippet: (replySnippet?.isEmpty == false) ? replySnippet : nil,
            replyToAuthorName: (replyAuthor?.isEmpty == false) ? replyAuthor : nil,
            editedAt: row.editedAt,
            albumID: row.albumID,
            fileName: (fileName?.isEmpty == false) ? fileName : nil,
            fileMime: (row.fileMime?.isEmpty == false) ? row.fileMime : nil,
            fileSizeBytes: row.fileSizeBytes > 0 ? Int(row.fileSizeBytes) : nil,
            latitude: row.latitude?.doubleValue,
            longitude: row.longitude?.doubleValue,
            pollID: row.pollID > 0 ? Int(row.pollID) : nil,
            isSpoiler: row.isSpoiler
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
