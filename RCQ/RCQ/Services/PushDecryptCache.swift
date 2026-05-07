import CryptoKit
import Foundation

/// Hand-off between the NSE and the main app for v=2 push payloads.
///
/// The dual-decrypt hazard: a v=2 envelope's inner libsignal
/// decrypt advances the Double Ratchet on the App Group SQLite
/// session store. If both the NSE (running to render the push
/// preview) AND the main app (running on launch / WS reconnect to
/// drain `/messages/queue`) decrypt the SAME ciphertext, the
/// second one fails because the ratchet has already moved past
/// the message's chain key. Symptom: push notifications show
/// real text, but the chat opens empty.
///
/// Fix: NSE decrypts ONCE, writes the resulting plaintext +
/// senderUIN into this cache (keyed by sha256 of the wire
/// envelope), then the main app's `MessageService.ingest` checks
/// the cache before calling `crypto.decrypt`. Cache hit ⇒ skip
/// the libsignal call entirely; cache miss ⇒ decrypt as normal.
/// `consume` deletes the entry on read so a third path (e.g. WS
/// re-delivery on reconnect) can't double-spend it.
///
/// Storage layout: one JSON file per envelope under
/// `<app-group>/push-cache/<sha256-hex>.json`. Files are tiny
/// (a few hundred bytes each), and the cache self-prunes by
/// dropping entries older than `maxAgeSec` on every write — no
/// background task needed.
enum PushDecryptCache {
    /// One hour. Anything older than this is either already
    /// consumed or never going to be (push dismissed without app
    /// launch, app launched but failed to fetch queue, etc.).
    /// Server-side queue rows live longer than this for proper
    /// retry, so a sweep here doesn't lose user data — at worst
    /// the main app re-decrypts and the ratchet advance happens
    /// in main app rather than NSE, which is fine because the
    /// NSE's advance was the only one with an unmatched second
    /// decrypt to break.
    private static let maxAgeSec: TimeInterval = 60 * 60

    private struct CacheEntry: Codable {
        let senderUIN: Int
        let envelope: Envelope
        let writtenAt: Date
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

    /// Called from the NSE after a successful decrypt. Idempotent —
    /// overwrites any existing entry for the same ciphertext (rare,
    /// but possible if a push lands twice and the NSE runs twice).
    static func store(ciphertextB64: String, senderUIN: Int, envelope: Envelope) {
        sweepIfNeeded()
        let entry = CacheEntry(senderUIN: senderUIN, envelope: envelope, writtenAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: ciphertextB64), options: .atomic)
    }

    /// Called from `MessageService.ingest` before any `crypto.decrypt`
    /// call. Returns the cached plaintext + sender if the NSE got
    /// here first, nil otherwise. Deletes the entry on read so the
    /// same payload arriving via a second path (e.g. server WS
    /// re-delivery) decrypts normally rather than reusing stale
    /// state.
    static func consume(ciphertextB64: String) -> DecryptedEnvelope? {
        let url = fileURL(for: ciphertextB64)
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else {
            return nil
        }
        return DecryptedEnvelope(senderUIN: entry.senderUIN, envelope: entry.envelope)
    }

    /// Drop every cached entry. Used by the burn-account flow so a
    /// fresh identity doesn't inherit decrypt results from the
    /// account that just got nuked.
    static func wipe() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Cheap O(n) sweep — runs on every store() so the cache stays
    /// bounded without a separate timer. n is tiny in practice
    /// (push notifications arrive at low rates and entries delete
    /// on consume), so a full directory scan per write is fine.
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
