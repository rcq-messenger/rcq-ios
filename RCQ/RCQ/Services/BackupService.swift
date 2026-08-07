import CryptoKit
import Foundation

/// Export and restore a `.rcqbak` archive.
///
/// What goes in:
///
///  * `manifest.json`   — what this file is and how much is in it
///  * `messages.ndjson` — one message per line
///  * `local.json`      — the settings that exist NOWHERE else: the names I
///                        gave contacts, favourites, archived threads. The
///                        contact graph itself is not here, the island hands
///                        that back on sign-in.
///  * `media/<id>`      — the decrypted bytes of an attachment, when the person
///                        asked for attachments to be included
///
/// Restore only ever ADDS: a message already present by id is skipped, and
/// nothing local is deleted or overwritten. An old archive can therefore never
/// eat newer history, which is the failure that makes people distrust backups.
@MainActor
enum BackupService {

    struct Progress {
        let stage: String
        let done: Int
        let total: Int
    }

    /// What an export actually managed to put in the file.
    ///
    /// `mediaMissed` exists because attachments are fetched from the island at
    /// export time: a blob that has aged off leaves the file short, and the
    /// only moment the person can act on that is while they are still looking
    /// at the screen.
    struct ExportResult {
        let messages: Int
        let media: Int
        let mediaMissed: Int
    }

    /// `unreadable` is counted apart from `skipped` on purpose: a line this
    /// build cannot turn into a message is neither added nor already here, and
    /// folding it into either number is how a restore reports success while
    /// quietly handing back a shorter history.
    struct RestoreResult {
        let added: Int
        let skipped: Int
        let media: Int
        let unreadable: Int
    }

    struct Refused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    // MARK: - thread keys

    /// The key format `local.json` uses for a thread, shared with Android.
    private static func threadKey(_ t: ThreadID) -> String { "\(t.kindString):\(t.rawKey)" }

    private static func thread(fromKey key: String) -> ThreadID? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "peer": return .peer(uin: n)
        case "group": return .group(id: n)
        default: return nil
        }
    }

    // MARK: - export

    static func export(
        to url: URL,
        includeMedia: Bool,
        onProgress: @escaping (Progress) -> Void = { _ in },
    ) async throws -> ExportResult {
        guard let words = AuthService.shared.recoveryPhrase() ?? AuthService.shared.legacyExportPhrase() else {
            throw Refused("no recovery phrase on this device")
        }
        guard let uin = AuthService.shared.ownUIN else { throw Refused("not signed in") }

        // ⚠ Disappearing messages are left out, and that is the point of them.
        // Someone who sets a one-day timer is saying this should not exist
        // tomorrow; writing it into a file that survives on a drive for years,
        // in the clear, would quietly undo the one guarantee they asked for.
        // Decided by the founder on 2026-08-07 and written into the format doc.
        let messages = MessageDB.shared.fetchAll().filter { $0.ttlSeconds == nil }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw Refused("cannot write there")
        }
        defer { try? handle.close() }

        let writer = BackupFormat.Writer(
            handle: handle,
            phrase: words.joined(separator: " "),
            uin: uin,
            createdAt: Date(),
        )

        let manifest: [String: Any] = [
            "app": "rcq-ios",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "uin": uin,
            "messages": messages.count,
            "includes_media": includeMedia,
        ]
        try writer.entry(name: "manifest.json", bytes: try JSONSerialization.data(withJSONObject: manifest))

        var ndjson = Data()
        let encoder = JSONEncoder()
        for m in messages {
            ndjson += try encoder.encode(BackupRecordMapping.toRecord(m))
            ndjson.append(0x0A)
        }
        try writer.entry(name: "messages.ndjson", bytes: ndjson)

        // Mute is NOT written from this client: here it belongs to the island
        // (`NotificationPrefsService` PUTs it and reads it back), so it is not
        // a device-only setting and would come home on sign-in anyway.
        let local: [String: Any] = [
            "aliases": Dictionary(
                uniqueKeysWithValues: ContactAliasStore.shared.aliases.map { (String($0.key), $0.value) },
            ),
            "favorites": FavoritesStore.shared.entries.map(\.key).sorted(),
            "archived": ArchiveStore.shared.entries.map(\.key).sorted(),
        ]
        try writer.entry(name: "local.json", bytes: try JSONSerialization.data(withJSONObject: local))

        var saved = 0
        var missed = 0
        if includeMedia {
            // Fetched and decrypted one at a time, so a multi-gigabyte account
            // never has to fit in memory. distinctBy the BLOB and not the
            // message: one video forwarded into six chats is six rows pointing
            // at one id. A blob that has already aged off the island is skipped
            // rather than failing the whole export, and counted rather than
            // swallowed: some history is better than none, but a silent gap is
            // worse than a named one.
            var seen = Set<String>()
            var pairs: [(String, String)] = []
            for m in messages {
                guard let raw = m.mediaID else { continue }
                let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, !seen.contains(parts[0]) else { continue }
                seen.insert(parts[0])
                pairs.append((parts[0], parts[1]))
            }
            for (i, pair) in pairs.enumerated() {
                onProgress(Progress(stage: "media", done: i + 1, total: pairs.count))
                if let bytes = await MediaService.shared.fetchDecrypted(mediaID: pair.0, keyBase64: pair.1) {
                    try writer.entry(name: "media/\(pair.0)", bytes: bytes)
                    saved += 1
                } else {
                    missed += 1
                }
            }
        }

        try writer.finish()
        return ExportResult(messages: messages.count, media: saved, mediaMissed: missed)
    }

    // MARK: - restore

    static func restore(
        from url: URL,
        onProgress: @escaping (Progress) -> Void = { _ in },
    ) async throws -> RestoreResult {
        guard let words = AuthService.shared.recoveryPhrase() ?? AuthService.shared.legacyExportPhrase() else {
            throw Refused("no recovery phrase on this device")
        }
        guard let me = AuthService.shared.ownUIN else { throw Refused("not signed in") }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let reader = BackupFormat.Reader(data: data, phrase: words.joined(separator: " "))
        try reader.open()
        // Refused on purpose: a history belonging to another number would show
        // up in this account's chat list as if it were its own, and the person
        // reading it is not the person it was written to.
        guard reader.uin == me else {
            throw Refused("this archive belongs to #\(reader.uin), and you are signed in as #\(me)")
        }

        var added = 0
        var skipped = 0
        var mediaCount = 0
        var unreadable = 0
        // media/<id> entries carry the decrypted bytes but not the key that
        // seals them on disk; the key rides in the records, which the writer
        // always puts in the file before the blobs.
        var mediaKeys: [String: String] = [:]
        let decoder = JSONDecoder()

        try reader.forEachEntry { name, bytes in
            switch true {
            case name == "messages.ndjson":
                let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
                for (i, line) in lines.enumerated() {
                    if i % 200 == 0 { onProgress(Progress(stage: "messages", done: i, total: lines.count)) }
                    guard let record = try? decoder.decode(BackupRecordMapping.Record.self, from: Data(line)),
                          let msg = BackupRecordMapping.toMessage(record, ownUIN: me)
                    else {
                        unreadable += 1
                        continue
                    }
                    // An archive written before disappearing messages were
                    // excluded can still carry one. Its timer did not pause
                    // because it sat in a file, so anything already past its
                    // moment stays gone.
                    if let ttl = msg.ttlSeconds,
                       msg.sentAt.addingTimeInterval(TimeInterval(ttl)) <= Date() {
                        continue
                    }
                    if MessageDB.shared.insertIfAbsent(msg) { added += 1 } else { skipped += 1 }
                    if let raw = msg.mediaID {
                        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                        if parts.count == 2 { mediaKeys[parts[0]] = parts[1] }
                    }
                }

            case name == "local.json":
                guard let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
                // Never overwrite something chosen on THIS device: the restore
                // adds, it does not correct.
                for (key, value) in (obj["aliases"] as? [String: String] ?? [:]) {
                    guard let uin = Int(key), ContactAliasStore.shared.alias(for: uin) == nil else { continue }
                    ContactAliasStore.shared.setAlias(value, for: uin)
                }
                for key in (obj["favorites"] as? [String] ?? []) {
                    guard let t = thread(fromKey: key) else { continue }
                    switch t {
                    case .peer(let uin):
                        if !FavoritesStore.shared.contains(peer: uin) { FavoritesStore.shared.toggle(peer: uin) }
                    case .group(let id):
                        if !FavoritesStore.shared.contains(group: id) { FavoritesStore.shared.toggle(group: id) }
                    }
                }
                for key in (obj["archived"] as? [String] ?? []) {
                    guard let t = thread(fromKey: key) else { continue }
                    switch t {
                    case .peer(let uin):
                        if !ArchiveStore.shared.contains(peer: uin) { ArchiveStore.shared.toggle(peer: uin) }
                    case .group(let id):
                        if !ArchiveStore.shared.contains(group: id) { ArchiveStore.shared.toggle(group: id) }
                    }
                }
                // `muted` and `mentions_only` are deliberately not applied: on
                // this client the island owns them, and writing them locally
                // would be undone by the next preferences sync anyway.

            case name.hasPrefix("media/"):
                let mediaID = String(name.dropFirst("media/".count))
                // The archive holds the DECRYPTED bytes and the disk cache
                // holds the sealed blob, so it is re-sealed with the key that
                // travelled in the record. Without the key there is nowhere to
                // put it that survives the next launch.
                guard let keyB64 = mediaKeys[mediaID],
                      let keyData = Data(base64Encoded: keyB64),
                      let sealed = try? AES.GCM.seal(bytes, using: SymmetricKey(data: keyData)),
                      let combined = sealed.combined
                else { return }
                EncryptedBlobDiskCache.shared.storeBlob(mediaID: mediaID, data: combined)
                mediaCount += 1

            default:
                // Unknown entry names are skipped on purpose: that is how the
                // format grows.
                break
            }
        }

        MessageStore.shared.reloadFromDB()
        return RestoreResult(added: added, skipped: skipped, media: mediaCount, unreadable: unreadable)
    }
}
