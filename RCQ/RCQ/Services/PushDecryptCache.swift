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
    static func store(ciphertextB64: String, senderUIN: Int, envelope: Envelope) {
        sweepIfNeeded()
        let entry = CacheEntry(senderUIN: senderUIN, envelope: envelope, writtenAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: ciphertextB64), options: .atomic)
    }

    /// Returns cached plaintext + sender if the NSE got here first.
    /// Deletes the entry on read so WS re-delivery decrypts normally.
    static func consume(ciphertextB64: String) -> DecryptedEnvelope? {
        let url = fileURL(for: ciphertextB64)
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else {
            return nil
        }
        return DecryptedEnvelope(senderUIN: entry.senderUIN, envelope: entry.envelope)
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
