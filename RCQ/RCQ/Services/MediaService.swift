import CryptoKit
import Foundation
import UIKit

/// Handles encrypted media upload/download. Server stores opaque blobs only; the
/// per-blob key is generated locally and shipped inside the encrypted Envelope so
/// only the recipient can decrypt the bytes.
@MainActor
final class MediaService {
    static let shared = MediaService()

    /// Hard cap on a single uploaded blob (post-encryption, so it
    /// matches what the server actually receives). Mirrors backend
    /// `MAX_BLOB_SIZE`. AES-GCM adds 16 bytes of tag overhead which
    /// is negligible at this scale; we don't bother subtracting.
    nonisolated static let maxBlobBytes: Int = 25 * 1024 * 1024

    /// `decryptedCache` keys blob bytes by (mediaID, key) so we don't redownload
    /// when the user scrolls past the same photo twice. Bounded loosely.
    private var decryptedCache: [String: UIImage] = [:]
    private let cacheLimit = 60

    /// Encrypted-blob cache keyed by mediaID alone (no key). Used by
    /// the premium-content prefetch path: while a recipient stares
    /// at the locked / blurred bubble, we silently pull the encrypted
    /// bytes into memory so the moment they pay (and the AES key is
    /// unwrapped client-side), the decrypt is essentially free and
    /// the blur dissolves straight into the image — no fresh network
    /// hit, no spinner. Mirrors Telegram's premium-media UX where
    /// payment removes only the visual gate, not the loading.
    /// Bounded loosely by the same `cacheLimit` policy as the
    /// decrypted cache.
    private var encryptedBlobCache: [String: Data] = [:]

    private init() {}

    enum Failure: Error, LocalizedError {
        case compressionFailed
        case encryptionFailed
        /// Blob exceeds `maxBlobBytes`. Surfaced to the user as a
        /// friendly "your video is too large" alert before we bother
        /// hitting the network.
        case tooLarge(actualBytes: Int)

        var errorDescription: String? {
            switch self {
            case .compressionFailed: return "media.error.compression".localized
            case .encryptionFailed:  return "media.error.encryption".localized
            case .tooLarge(let n):
                let mb = Double(n) / (1024 * 1024)
                return String(
                    format: "media.error.too_large".localized,
                    String(format: "%.1f", mb),
                    String(format: "%.0f", Double(MediaService.maxBlobBytes) / (1024 * 1024))
                )
            }
        }
    }

    struct UploadResult {
        let mediaID: String
        let keyBase64: String
    }

    /// Compress, encrypt, and upload an image. Returns the server media id and the
    /// AES key (caller embeds both in the encrypted message envelope).
    /// `onProgress` (0…1) ticks during the network upload — the caller's
    /// bubble UI binds it to a progress overlay.
    func uploadImage(_ image: UIImage, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        guard let jpeg = ImageCompressor.compress(image, maxSide: 1200, quality: 0.8) else {
            throw Failure.compressionFailed
        }
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try? AES.GCM.seal(jpeg, using: key),
              let combined = sealed.combined else {
            throw Failure.encryptionFailed
        }
        if combined.count > Self.maxBlobBytes {
            throw Failure.tooLarge(actualBytes: combined.count)
        }

        struct UploadOut: Decodable { let media_id: String; let size: Int }
        let out: UploadOut = try await APIClient.shared.uploadBlob(
            "/media/upload",
            field: "blob",
            filename: "photo.bin",
            contentType: "application/octet-stream",
            data: combined,
            onProgress: onProgress
        )

        let keyB64 = key.withUnsafeBytes { Data($0).base64EncodedString() }

        // Cache the COMPRESSED-and-decoded UIImage (NOT the raw `image`
        // input) so the sender's bubble renders at the same dimensions
        // the receiver will see. The original PHPicker UIImage commonly
        // has scale=3 + native phone pixel dims, while the JPEG round-
        // tripped through ImageCompressor + UIImage(data:) lands at
        // scale=1 and the canonical 1200-px-longest-side dims. Using
        // `?? image` as a fallback (the previous behavior) made the
        // sender's locally-rendered bubble show at one size and the
        // receiver's downloaded-then-decoded version at another — the
        // size-mismatch bug the user reported.
        let cacheKey = out.media_id + ":" + keyB64
        if decryptedCache.count >= cacheLimit { decryptedCache.removeAll() }
        if let decoded = UIImage(data: jpeg) {
            decryptedCache[cacheKey] = decoded
        }

        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
    }

    /// Encrypt + upload an arbitrary file (used for video). Returns the same
    /// envelope-friendly tuple as `uploadImage`.
    func uploadFile(at fileURL: URL, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        // Pre-flight on the raw file size BEFORE we waste seconds
        // reading + AES-encrypting a 100 MB blob just to throw it
        // away. AES-GCM adds 16 bytes of tag overhead which is
        // negligible at the cap, so a file already over the cap
        // cannot fit after sealing either.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let rawSize = attrs[.size] as? Int,
           rawSize > Self.maxBlobBytes {
            throw Failure.tooLarge(actualBytes: rawSize)
        }
        let plain = try Data(contentsOf: fileURL)
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try? AES.GCM.seal(plain, using: key),
              let combined = sealed.combined else {
            throw Failure.encryptionFailed
        }
        if combined.count > Self.maxBlobBytes {
            throw Failure.tooLarge(actualBytes: combined.count)
        }
        struct UploadOut: Decodable { let media_id: String; let size: Int }
        let out: UploadOut = try await APIClient.shared.uploadBlob(
            "/media/upload",
            field: "blob",
            filename: fileURL.lastPathComponent,
            contentType: "application/octet-stream",
            data: combined,
            onProgress: onProgress
        )
        let keyB64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
    }

    /// Download + decrypt to a temp file. Used for video playback through AVPlayer,
    /// which needs a file URL and won't read encrypted bytes inline. Caller deletes
    /// the temp file after the player is done.
    func decryptToFile(mediaID: String, keyBase64: String) async -> URL? {
        do {
            let blob = try await APIClient.shared.downloadBlob("/media/\(mediaID)")
            guard let keyBytes = Data(base64Encoded: keyBase64) else { return nil }
            let key = SymmetricKey(data: keyBytes)
            let box = try AES.GCM.SealedBox(combined: blob)
            let plain = try AES.GCM.open(box, using: key)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rcq-play-\(mediaID).mp4")
            try plain.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Fetch + decrypt + cache. Returns nil on any failure. UI shows a placeholder.
    ///
    /// AES-GCM unsealing + JPEG decode of a multi-MB blob runs in
    /// the tens-to-hundreds of milliseconds; doing it on the main
    /// actor (which this class is) blocks the SwiftUI runloop. With
    /// several photos in a chat that all start loading on chat
    /// open, the cumulative block can freeze the app for seconds —
    /// what the user reported as "захожу в чат и он зависает".
    /// Push the heavy bytes work onto a detached cooperative task
    /// so the main runloop stays responsive.
    func loadImage(mediaID: String, keyBase64: String) async -> UIImage? {
        let cacheKey = mediaID + ":" + keyBase64
        if let hit = decryptedCache[cacheKey] { return hit }
        do {
            let blob: Data
            if let prefetched = encryptedBlobCache[mediaID] {
                blob = prefetched
            } else {
                blob = try await APIClient.shared.downloadBlob("/media/\(mediaID)")
            }
            guard let keyBytes = Data(base64Encoded: keyBase64) else { return nil }
            // Off-main: decrypt + JPEG decode + force a redraw so
            // the resulting UIImage's bitmap is decoded eagerly
            // (otherwise UIKit lazily decodes on first draw, which
            // *also* hits main thread).
            let image: UIImage? = await Task.detached(priority: .userInitiated) {
                let key = SymmetricKey(data: keyBytes)
                guard let box = try? AES.GCM.SealedBox(combined: blob),
                      let plain = try? AES.GCM.open(box, using: key) else {
                    return nil
                }
                guard let raw = UIImage(data: plain) else { return nil }
                // Force-decode the bitmap on this background thread
                // so SwiftUI's first paint of the image doesn't have
                // to do it on main.
                let format = UIGraphicsImageRendererFormat.preferred()
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: raw.size, format: format)
                let decoded = renderer.image { _ in
                    raw.draw(in: CGRect(origin: .zero, size: raw.size))
                }
                return decoded
            }.value
            guard let image else { return nil }
            if decryptedCache.count >= cacheLimit { decryptedCache.removeAll() }
            decryptedCache[cacheKey] = image
            // Drop the encrypted copy now that we have the decrypted
            // one cached — keeping both wastes RAM and the encrypted
            // form is only useful as a "pre-unlock" placeholder.
            encryptedBlobCache.removeValue(forKey: mediaID)
            return image
        } catch {
            return nil
        }
    }

    /// Pull the encrypted media blob into memory ahead of time, with
    /// no key + no decrypt. Used by the premium-content locked bubble:
    /// while the recipient looks at the blur, we silently fetch the
    /// bytes so the moment they pay, the AES key arrives and decrypt
    /// finds the blob already local — the blur dissolves into the
    /// image with no spinner. Idempotent: a hit in either cache
    /// short-circuits without touching the network.
    func prefetchEncrypted(mediaID: String) async {
        if encryptedBlobCache[mediaID] != nil { return }
        // Already-decrypted form (i.e. unlocked-and-rendered) makes
        // a prefetch redundant.
        if decryptedCache.contains(where: { $0.key.hasPrefix(mediaID + ":") }) { return }
        do {
            let blob = try await APIClient.shared.downloadBlob("/media/\(mediaID)")
            if encryptedBlobCache.count >= cacheLimit { encryptedBlobCache.removeAll() }
            encryptedBlobCache[mediaID] = blob
        } catch {
            // Silent — prefetch is opportunistic. The unlock path will
            // retry the download if it doesn't find a cache hit.
        }
    }
}
