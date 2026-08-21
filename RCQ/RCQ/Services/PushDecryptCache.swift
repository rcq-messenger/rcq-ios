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
/// Storage: one JSON file per envelope under `<app-group>/push-cache/<sha256-hex>.json`.
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

    private static func key(for ciphertextB64: String) -> String {
        let digest = SHA256.hash(data: Data(ciphertextB64.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(for ciphertextB64: String) -> URL {
        cacheDir.appendingPathComponent("\(key(for: ciphertextB64)).json")
    }

    /// Idempotent — overwrites any existing entry for the same ciphertext.
    ///
    /// Store the WHOLE `DecryptedEnvelope`, not just uin + plaintext: the
    /// sender's island and signing key are as much a part of "who sent this"
    /// as the uin, and every cross-island control branch in `ingest` is gated
    /// on them.
    static func store(ciphertextB64: String, decrypted: DecryptedEnvelope) {
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
        try? box.write(to: fileURL(for: ciphertextB64), options: .atomic)
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

    /// Returns cached plaintext + sender if the NSE got here first.
    /// Deletes the entry on read so WS re-delivery decrypts normally.
    static func consume(ciphertextB64: String) -> DecryptedEnvelope? {
        let url = fileURL(for: ciphertextB64)
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        // Sealed first, plain second: an entry written by a build older than
        // this one is the only decoder its envelope has left.
        let json = open(data) ?? data
        guard let entry = try? JSONDecoder().decode(CacheEntry.self, from: json) else {
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

    /// Burn-account hook — fresh identity must not inherit prior decrypts.
    static func wipe() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func sweepIfNeeded() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAgeSec)
        for url in urls {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
