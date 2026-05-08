import CryptoKit
import Foundation
import UIKit

/// Encrypted media upload/download. Server stores opaque blobs; per-blob key travels in the encrypted envelope.
@MainActor
final class MediaService {
    static let shared = MediaService()

    /// Mirrors backend `MAX_BLOB_SIZE`.
    nonisolated static let maxBlobBytes: Int = 25 * 1024 * 1024

    private var decryptedCache: [String: UIImage] = [:]
    private let cacheLimit = 60

    private var encryptedBlobCache: [String: Data] = [:]

    private init() {}

    enum Failure: Error, LocalizedError {
        case compressionFailed
        case encryptionFailed
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

    /// Compress, encrypt, and upload an image. Returns server media id + AES key for the envelope.
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

        // Cache the compressed-and-decoded UIImage so sender + receiver render at the same dims.
        let cacheKey = out.media_id + ":" + keyB64
        if decryptedCache.count >= cacheLimit { decryptedCache.removeAll() }
        if let decoded = UIImage(data: jpeg) {
            decryptedCache[cacheKey] = decoded
        }

        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
    }

    /// Encrypt + upload an arbitrary file (used for video).
    func uploadFile(at fileURL: URL, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        // Pre-flight on raw size before encrypting; AES-GCM tag overhead is negligible at the cap.
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

    /// Download + decrypt to a temp file. AVPlayer needs a URL. Caller deletes the file.
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

    /// Fetch + decrypt + cache. Decrypt and JPEG decode run off-main to keep the SwiftUI runloop responsive.
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
            // Off-main: decrypt + decode + force-redraw so UIKit doesn't lazy-decode on first draw on main.
            let image: UIImage? = await Task.detached(priority: .userInitiated) {
                let key = SymmetricKey(data: keyBytes)
                guard let box = try? AES.GCM.SealedBox(combined: blob),
                      let plain = try? AES.GCM.open(box, using: key) else {
                    return nil
                }
                guard let raw = UIImage(data: plain) else { return nil }
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
            encryptedBlobCache.removeValue(forKey: mediaID)
            return image
        } catch {
            return nil
        }
    }

    /// Prefetch encrypted blob without decrypting. Idempotent.
    func prefetchEncrypted(mediaID: String) async {
        if encryptedBlobCache[mediaID] != nil { return }
        if decryptedCache.contains(where: { $0.key.hasPrefix(mediaID + ":") }) { return }
        do {
            let blob = try await APIClient.shared.downloadBlob("/media/\(mediaID)")
            if encryptedBlobCache.count >= cacheLimit { encryptedBlobCache.removeAll() }
            encryptedBlobCache[mediaID] = blob
        } catch {
        }
    }
}
