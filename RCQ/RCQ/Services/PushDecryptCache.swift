import CryptoKit
import Foundation

/// NSE → main-app hand-off for v=2 push payloads.
///
/// Dual-decrypt hazard: a v=2 envelope's inner libsignal decrypt
/// advances the Double Ratchet on the App Group SQLite store. If
/// both NSE (push preview) and main app (queue drain) decrypt the
/// same ciphertext, the second one fails — ratchet has moved past
/// the message's chain key. Symptom: push shows real text, chat
/// opens empty.
///
/// Fix: NSE decrypts once, stashes plaintext + senderUIN here
/// (keyed by sha256 of the wire envelope). `MessageService.ingest`
/// checks the cache before calling `crypto.decrypt`. `consume`
/// deletes on read so WS re-delivery can't double-spend.
///
/// Storage: one JSON file per envelope under
/// `<app-group>/push-cache/<account-uuid>/<sha256-hex>.json` (see `accountDir`).
enum PushDecryptCache {
    // 30 days. Entries here are the ONLY decoder for v=2 envelopes the
    // NSE already stepped the ratchet on, so a TTL shorter than the
    // worst-case "user closed the app for a while" window loses
    // messages permanently (the offline-queue row is still there, but
    // the second crypto.decrypt fails because ratchet has moved past).
    // Disk cost is bounded by sweep-on-store; entries are a few hundred
    // bytes each, so even thousands of stale entries cost low-MB.
    private static let maxAgeSec: TimeInterval = 60 * 60 * 24 * 30

    private struct CacheEntry: Codable {
        let senderUIN: Int
        let envelope: Envelope
        let writtenAt: Date
        /// ⚠ The sender's ISLAND (v=1 `from_host`). Until 2026-08-15 this entry
        /// held only the uin, so `consume` handed back a `DecryptedEnvelope`
        /// with `senderHost == nil` — and `MessageService.ingest` PREFERS the
        /// cache over a fresh decrypt. Every §5d call signal, §5e profile
        /// refresh and §5f contact request that arrived via a push therefore
        /// reached a branch that requires a known host, and was dropped.
        /// Optional so entries written by an older build still decode (a
        /// synthesised `init(from:)` uses `decodeIfPresent` for Optionals).
        var senderHost: String? = nil
        /// Base64 `spub` that signed the envelope — what binds a `homerec`
        /// self-push to its real sender. Dropped for the same reason.
        var senderSigningKey: String? = nil
        /// The sender's v=2 device id. Same trap as `senderHost` above:
        /// `ingest` prefers this cache over a fresh decrypt, so an entry that
        /// forgets the device would keep the silence probe armed for exactly
        /// the envelopes that arrive by push — the ones proving the device is
        /// alive. Optional so older entries still decode.
        var senderDeviceID: Int? = nil
    }

    private static var cacheDir: URL {
        let dir = AppGroup.containerURL.appendingPathComponent("push-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ⚠ One folder PER ACCOUNT (#1045 review, round 4). The extension opens
    /// pushes for accounts that are not the active one too (it swaps in the
    /// owner of `to_uin`), and the entry it leaves is that account's only
    /// decoder until the account is next drained. With every entry in one
    /// folder, the wipe an account switch ran deleted them just before the
    /// switched-to account's first drain: every v=2 message it had been
    /// pushed failed as a duplicate and was acked away, while its banner had
    /// shown the text. Entries written before this sit in the folder itself;
    /// they are still read, and age out with the sweep.
    private static func accountDir(_ accountID: UUID?) -> URL {
        guard let accountID else { return cacheDir }
        let dir = cacheDir.appendingPathComponent(accountID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func key(for ciphertextB64: String) -> String {
        let digest = SHA256.hash(data: Data(ciphertextB64.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(for ciphertextB64: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(key(for: ciphertextB64)).json")
    }

    /// Where an entry for this ciphertext may be: the account's folder, then
    /// the folder itself for one written before folders were per account.
    private static func candidates(for ciphertextB64: String, accountID: UUID?) -> [URL] {
        var urls = [fileURL(for: ciphertextB64, in: accountDir(accountID))]
        if accountID != nil { urls.append(fileURL(for: ciphertextB64, in: cacheDir)) }
        return urls
    }

    /// Idempotent — overwrites any existing entry for the same ciphertext.
    ///
    /// Store the WHOLE `DecryptedEnvelope`, not just uin + plaintext: the
    /// sender's island and signing key are as much a part of "who sent this"
    /// as the uin, and every cross-island control branch in `ingest` is gated
    /// on them.
    /// `accountID`: the account whose keys opened it (nil only where no
    /// account can be named, which files it in the shared folder).
    static func store(ciphertextB64: String, decrypted: DecryptedEnvelope, accountID: UUID?) {
        sweepIfNeeded()
        let entry = CacheEntry(
            senderUIN: decrypted.senderUIN,
            envelope: decrypted.envelope,
            writtenAt: Date(),
            senderHost: decrypted.senderHost,
            senderSigningKey: decrypted.senderSigningKey,
            senderDeviceID: decrypted.senderDeviceID
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        // Sealed before it touches the disk. See `seal` below for why.
        guard let box = seal(data) else { return }
        try? box.write(to: fileURL(for: ciphertextB64, in: accountDir(accountID)), options: .atomic)
    }

    // MARK: - At-rest sealing
    //
    // ⚠⚠ These files carry the DECRYPTED text of a pushed message — that is
    // their whole purpose, since the NSE must not let the main app decrypt the
    // same v=2 envelope twice. They were written as plain JSON and kept for
    // thirty days in the App Group container.
    //
    // Everything else the app remembers about a conversation lives in a
    // database encrypted under the PIN. This did not: a file dump, a backup, or
    // simply somebody with the phone in their hands read the last month of
    // pushed messages, sender and text, without the PIN entering into it.
    //
    // AES-GCM under a key in the shared Keychain fixes it. The Keychain is
    // exactly where the material this cache is derived from already lives, and
    // both processes reach it through the access group they already share.
    private static func seal(_ plaintext: Data) -> Data? {
        guard let sealed = try? AES.GCM.seal(
            plaintext, using: SymmetricKey(data: KeychainStore.pushCacheKey())
        ) else { return nil }
        return sealed.combined
    }

    /// Nil when the box is not ours to open. Callers fall back to reading the
    /// file as plain JSON, which is what entries written before this change are
    /// — dropping them instead would lose every push already decrypted by the
    /// NSE, and those are exactly the envelopes whose ratchet has moved on and
    /// which nothing else can decode.
    private static func open(_ box: Data) -> Data? {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: box),
              let plain = try? AES.GCM.open(
                  sealedBox, using: SymmetricKey(data: KeychainStore.pushCacheKey())
              )
        else { return nil }
        return plain
    }

    /// Whether an entry exists for this ciphertext, without consuming it.
    static func contains(ciphertextB64: String, accountID: UUID?) -> Bool {
        candidates(for: ciphertextB64, accountID: accountID)
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Returns cached plaintext + sender if the NSE got here first, and
    /// deletes the entry.
    static func consume(ciphertextB64: String, accountID: UUID?) -> DecryptedEnvelope? {
        let found = read(ciphertextB64: ciphertextB64, accountID: accountID)
        remove(ciphertextB64: ciphertextB64, accountID: accountID)
        return found
    }

    /// Delete one entry. For a drain that read it with `read` and has now got
    /// the row on disk.
    static func remove(ciphertextB64: String, accountID: UUID?) {
        for url in candidates(for: ciphertextB64, accountID: accountID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Returns cached plaintext + sender WITHOUT deleting the entry.
    ///
    /// ⚠ The drains read with this and delete only once the row is on disk
    /// (MessageDB.whenPersisted). Deleting on read lost the message whenever
    /// the save after it failed (the phone locked mid-drain): the ratchet had
    /// moved on, so the island's copy, served again, no longer opened, and
    /// this entry was its only decoder (#1045 review).
    static func read(ciphertextB64: String, accountID: UUID?) -> DecryptedEnvelope? {
        guard let found = candidates(for: ciphertextB64, accountID: accountID).lazy
            .compactMap({ url in (try? Data(contentsOf: url)).map { (url, $0) } }).first
        else { return nil }
        let (url, data) = found
        // Sealed first, plain second: an entry written by a build older than
        // this one is the only decoder its envelope has left.
        let json = open(data) ?? data
        guard let entry = try? JSONDecoder().decode(CacheEntry.self, from: json) else {
            // Nothing can ever read it: out of the way of the decrypt.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return DecryptedEnvelope(
            senderUIN: entry.senderUIN,
            senderHost: entry.senderHost,
            senderSigningKey: entry.senderSigningKey,
            senderDeviceID: entry.senderDeviceID,
            envelope: entry.envelope
        )
    }

    /// Burn-account hook: the burned identity's decrypts, and nobody else's.
    /// A switch and a number move wipe nothing any more (see `accountDir`).
    /// `includingUnfiled`: also the entries written before folders were per
    /// account, which cannot be told apart; for a device with no other
    /// account, where they can only be this one's.
    static func wipe(accountID: UUID?, includingUnfiled: Bool) {
        if let accountID {
            try? FileManager.default.removeItem(
                at: cacheDir.appendingPathComponent(accountID.uuidString, isDirectory: true)
            )
        }
        guard includingUnfiled || accountID == nil else { return }
        for url in files(in: cacheDir) { try? FileManager.default.removeItem(at: url) }
    }

    /// The entry files directly in `dir`, not the account folders.
    private static func files(in dir: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
    }

    private static func sweepIfNeeded() {
        let cutoff = Date().addingTimeInterval(-maxAgeSec)
        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for dir in [cacheDir] + folders {
            for url in files(in: dir) {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if mtime < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
