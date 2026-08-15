import CoreData
import CryptoKit
import Foundation

/// A person as the DECOY account knows them: a synthetic UIN plus the display
/// name carried over from the real conversation the rows were copied from.
///
/// The uin here is invented on the spot and exists nowhere on any server. It
/// has to be: `senderUIN` and `threadKey` are the two columns MessageDB never
/// encrypts, so a decoy store holding the real uins of real people would sit on
/// disk in plaintext next to the real store holding the same numbers. Anyone
/// given the duress PIN who then imaged the phone would join the two on those
/// columns and see the whole arrangement.
struct DecoyContactRecord: Codable, Hashable {
    let uin: Int
    let nickname: String
}

/// The decoy session's contact roster, encrypted with the decoy `dataKey`.
///
/// It cannot live where the real roster lives: `ContactService.refresh()` is a
/// server call, and the decoy identity does not exist on any server. It cannot
/// live in UserDefaults either — that is readable without a PIN. So it is one
/// AES-GCM sealed file next to the decoy history, openable only by whoever
/// entered the decoy PIN.
enum DecoySeedStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Sits beside `rcq-history-decoy-v8.sqlite`, which already exists on
        // any device with a decoy PIN — this adds no new signal about whether
        // the feature is in use.
        return base.appendingPathComponent("rcq-history-decoy-v8.roster")
    }

    static func save(_ rows: [DecoyContactRecord], key: SymmetricKey) {
        guard let json = try? JSONEncoder().encode(rows),
              let box = try? AES.GCM.seal(json, using: key),
              let combined = box.combined else { return }
        try? combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    static func load(key: SymmetricKey) -> [DecoyContactRecord] {
        guard let raw = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: raw),
              let json = try? AES.GCM.open(box, using: key),
              let rows = try? JSONDecoder().decode([DecoyContactRecord].self, from: json) else {
            return []
        }
        return rows
    }

    static func destroy() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Copies conversations the user picked out of their real history into the
/// decoy store, rewriting identity as it goes. An empty decoy is the exact tell
/// the decoy PIN exists to avoid.
///
/// ⚠ Two rules this type exists to enforce:
///
/// 1. It owns its OWN persistent container. `MessageDB.shared.configure(decoy:)`
///    flips a singleton's container globally, so seeding through it would open
///    a window in which any inbound WebSocket write lands in the decoy store.
///    This never touches `MessageDB.shared`'s container or its `dataKey`.
/// 2. It REWRITES every identifier that MessageDB stores in the clear —
///    `senderUIN`, `threadKey`, the row `id`, `albumID` — and shifts
///    timestamps, so no plaintext column of a copied row equals the plaintext
///    column of the row it came from. Copying verbatim would leave the real
///    uins of real people in the decoy store, and `isFromMe` rows would carry
///    the real account's uin, which does not even match the decoy identity.
@MainActor
enum DecoySeeder {
    /// One conversation offered to the picker. `peerUIN` is the REAL uin and is
    /// used only to read the source thread — it is never written anywhere.
    struct Selection: Identifiable, Hashable {
        let peerUIN: Int
        let displayName: String
        let messageCount: Int
        var id: Int { peerUIN }
    }

    /// How many messages are copied per conversation. A tail, not the whole
    /// history: enough to read as lived-in, small enough to stay quick.
    static let messagesPerThread = 120

    /// Rebuild the decoy store from `selections`. Replaces whatever was seeded
    /// before, so re-picking is idempotent rather than cumulative. Returns the
    /// number of messages written.
    ///
    /// - Parameters:
    ///   - decoyUIN: the identity the decoy session presents as. Every copied
    ///     `isFromMe` row is attributed to it.
    ///   - decoyKey: the decoy slot's OWN dataKey. The real `dataKey` is never
    ///     passed here and the real store is never opened for writing.
    ///   - realOwnUIN: the real account's uin, needed ONLY to recognise the
    ///     user's own reaction keys so they can be rewritten. Never stored.
    @discardableResult
    static func seed(
        _ selections: [Selection],
        decoyUIN: Int,
        decoyKey: SymmetricKey,
        realOwnUIN: Int?
    ) -> Int {
        let container = makeDecoyContainer()
        let ctx = container.viewContext

        // Replace, don't append: the picker is "these conversations are the
        // decoy", not "add these too".
        let purge = NSBatchDeleteRequest(
            fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: "MessageRecord")
        )
        _ = try? ctx.execute(purge)

        var roster: [DecoyContactRecord] = []
        var usedUINs: Set<Int> = [decoyUIN]
        var written = 0

        for selection in selections {
            let source = MessageDB.shared
                .fetchRecent(thread: .peer(uin: selection.peerUIN), limit: messagesPerThread)
                .filter(isCopyable)
            guard !source.isEmpty else { continue }

            let fakeUIN = mintUIN(avoiding: &usedUINs)
            let shift = timeShift(lastSentAt: source.last?.sentAt ?? Date())

            // Two passes: ids are regenerated, so a reply can only be relinked
            // once every new id is known. A reply whose target was filtered out
            // loses the link rather than pointing at a row that isn't there.
            var idMap: [UUID: UUID] = [:]
            for msg in source { idMap[msg.id] = UUID() }

            for msg in source {
                let copy = Message(
                    id: idMap[msg.id] ?? UUID(),
                    thread: .peer(uin: fakeUIN),
                    senderUIN: msg.isFromMe ? decoyUIN : fakeUIN,
                    isFromMe: msg.isFromMe,
                    kind: .text,
                    text: msg.text,
                    mediaID: nil,
                    sentAt: msg.sentAt.addingTimeInterval(shift),
                    // Everything in a seeded thread has been sat with already.
                    deliveryState: .read,
                    receivedWhileAway: false,
                    deletedForEveryone: false,
                    reactions: remap(
                        msg.reactions,
                        realPeerUIN: selection.peerUIN, fakePeerUIN: fakeUIN,
                        realOwnUIN: realOwnUIN, decoyUIN: decoyUIN
                    ),
                    thumbnailB64: nil,
                    durationSec: 0,
                    // A copied disappearing message would evaporate out of the
                    // decoy and leave a gap exactly where one is least wanted.
                    ttlSeconds: nil,
                    forwardedFromName: msg.forwardedFromName,
                    replyToID: msg.replyToID.flatMap { idMap[$0] },
                    replyToSnippet: msg.replyToSnippet,
                    replyToAuthorName: msg.replyToAuthorName,
                    editedAt: msg.editedAt.map { $0.addingTimeInterval(shift) },
                    // Album grouping only means anything with media attached.
                    albumID: nil,
                    fileName: nil,
                    fileMime: nil,
                    fileSizeBytes: nil,
                    latitude: nil,
                    longitude: nil,
                    pollID: nil,
                    isSpoiler: false
                )
                let row = MessageRecord(context: ctx)
                MessageDB.apply(copy, to: row, key: decoyKey)
                written += 1
            }

            roster.append(DecoyContactRecord(uin: fakeUIN, nickname: selection.displayName))
        }

        if ctx.hasChanges {
            do { try ctx.save() } catch { print("[DecoySeeder] save failed: \(error)") }
        }
        DecoySeedStore.save(roster, key: decoyKey)
        return written
    }

    /// Conversations the picker can offer: peer threads that actually hold
    /// copyable messages, newest first.
    static func availableThreads() -> [Selection] {
        var out: [Selection] = []
        for thread in MessageDB.shared.fetchThreadIDs() {
            guard case .peer(let uin) = thread else { continue }
            let msgs = MessageDB.shared
                .fetchRecent(thread: thread, limit: messagesPerThread)
                .filter(isCopyable)
            guard !msgs.isEmpty else { continue }
            let name = ContactService.shared.contacts.first(where: { $0.uin == uin })?.nickname
                ?? NicknameCache.nickname(for: uin)
                ?? String(uin)
            out.append(Selection(peerUIN: uin, displayName: name, messageCount: msgs.count))
        }
        return out.sorted { $0.messageCount > $1.messageCount }
    }

    // MARK: - internals

    /// Text only. Every other kind either needs a server blob the decoy
    /// identity cannot fetch (photo, video, voice, file, poll) — which renders
    /// as a broken bubble, itself a tell — or carries data that has no business
    /// being handed to whoever holds the duress PIN (a `.relay` token, a pinned
    /// location).
    private static func isCopyable(_ msg: Message) -> Bool {
        msg.kind == .text && !msg.deletedForEveryone && !msg.text.isEmpty
    }

    private static func makeDecoyContainer() -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "RCQHistoryV2", managedObjectModel: MessageDB.sharedModel
        )
        let desc = NSPersistentStoreDescription(url: MessageDB.decoyStoreURL())
        desc.setOption(FileProtectionType.complete as NSObject,
                       forKey: NSPersistentStoreFileProtectionKey)
        desc.shouldAddStoreAsynchronously = false
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]
        container.loadPersistentStores { _, err in
            if let err { print("[DecoySeeder] load failed: \(err)") }
        }
        return container
    }

    private static func mintUIN(avoiding used: inout Set<Int>) -> Int {
        var candidate = Int.random(in: 100_000_000...999_999_999)
        while used.contains(candidate) {
            candidate = Int.random(in: 100_000_000...999_999_999)
        }
        used.insert(candidate)
        return candidate
    }

    /// Slide the thread so its last message lands somewhere in the past two
    /// days. `sentAt` is another column stored in the clear: leaving the copied
    /// timestamps identical to the originals would let the two stores be joined
    /// on them without opening either. Shifting the whole thread by one offset
    /// keeps the rhythm of the conversation intact, and landing it recently is
    /// what a live account looks like.
    private static func timeShift(lastSentAt: Date) -> TimeInterval {
        let target = Date().addingTimeInterval(-Double.random(in: 600...172_800))
        return target.timeIntervalSince(lastSentAt)
    }

    private static func remap(
        _ reactions: [Int: String],
        realPeerUIN: Int, fakePeerUIN: Int,
        realOwnUIN: Int?, decoyUIN: Int
    ) -> [Int: String] {
        var out: [Int: String] = [:]
        for (uin, asset) in reactions {
            if uin == realPeerUIN {
                out[fakePeerUIN] = asset
            } else if let realOwnUIN, uin == realOwnUIN {
                out[decoyUIN] = asset
            }
            // A uin belonging to nobody in this decoy thread is dropped. The
            // reactions JSON is sealed with the decoy key, so it is not on disk
            // in the clear — but whoever was handed the decoy PIN can read it,
            // and a real person's number attached to nobody in the roster is
            // both a leak and something the decoy cannot explain.
        }
        return out
    }
}
