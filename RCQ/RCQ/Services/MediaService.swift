import CryptoKit
import Foundation
import UIKit

/// Encrypted media upload/download. Server stores opaque blobs; per-blob key travels in the encrypted envelope.
@MainActor
final class MediaService {
    static let shared = MediaService()

    /// Matches backend `MAX_BLOB_SIZE`. The user-facing rule is "as
    /// long as you have jetons" — this is just the safety backstop.
    nonisolated static let maxBlobBytes: Int = 2 * 1024 * 1024 * 1024
    /// Free-tier ceiling. Covers most casual shares.
    nonisolated static let freeTierBytes: Int = 50 * 1024 * 1024

    /// Per-file jeton cost above the free tier. 1 jeton per started
    /// 10 MB block above the 50 MB free ceiling. MUST stay in sync
    /// with `_jeton_cost_for` in `backend/app/routers/media.py` —
    /// server re-checks the price and 400s on mismatch.
    nonisolated static func jetonCost(forBytes size: Int) -> Int {
        guard size > freeTierBytes else { return 0 }
        let over = size - freeTierBytes
        let block = 10 * 1024 * 1024
        return Int((over + block - 1) / block)
    }

    /// LRU image cache. Previously a plain `[String: UIImage]` that
    /// nuked the WHOLE thing via `removeAll()` once it hit a 60-entry
    /// limit, which is what the user saw as "media re-downloads every
    /// time I scroll" — 61 unique photos in a busy thread torched
    /// everything, so the next render of the first 60 went straight
    /// back to the network. NSCache evicts one-at-a-time (approximately
    /// LRU) AND drops under memory pressure for free.
    ///
    /// Decryption keys live alongside the message, NOT here, so a
    /// cache wipe never re-charges the user for premium media — we
    /// just re-fetch the encrypted blob and re-decrypt with the same
    /// stored key.
    /// `nonisolated(unsafe)` because NSCache is internally thread-safe
    /// (Apple-documented) but the Foundation overlay doesn't mark it
    /// `Sendable`. We want `cachedImage(...)` peeks from SwiftUI View
    /// inits to avoid an actor hop. The reference is `let`-bound so
    /// there's no race on the reference itself.
    nonisolated(unsafe) private let decryptedCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()
    /// Decrypted-plaintext cache. Photo bubble paths use the UIImage
    /// cache; the data cache exists so GIF-aware renderers can
    /// re-stream the animated bytes without a second AES pass.
    private let decryptedDataCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 300
        c.totalCostLimit = 200 * 1024 * 1024 // 200 MB ceiling on raw bytes
        return c
    }()

    private let encryptedBlobCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 120
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

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
        let cacheKey = (out.media_id + ":" + keyB64) as NSString
        if let decoded = UIImage(data: jpeg) {
            decryptedCache.setObject(decoded, forKey: cacheKey)
        }

        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
    }

    /// Encrypt + upload an animated GIF as raw bytes. Skips
    /// `ImageCompressor.compress` (which JPEG-encodes and kills the
    /// animation). Receiver detects the GIF via magic-byte check on
    /// the decrypted blob and routes through `AnimatedGIFView`.
    func uploadGIF(data: Data, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        if data.count > Self.maxBlobBytes {
            throw Failure.tooLarge(actualBytes: data.count)
        }
        let key = SymmetricKey(size: .bits256)
        guard let sealed = try? AES.GCM.seal(data, using: key),
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
        // Seed the data cache so the sender's own bubble doesn't have
        // to re-download + re-decrypt the bytes we already have.
        let cacheKey = (out.media_id + ":" + keyB64) as NSString
        decryptedDataCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
    }

    /// Encrypt + upload an arbitrary file (used for video + documents).
    /// `payJetons` is the price the caller agreed to for this upload —
    /// 0 for free-tier (≤25 MB) blobs, the per-file cost for paid
    /// uploads. Server re-validates against its own size→price
    /// formula and rejects with `priceMismatch` if they disagree.
    func uploadFile(
        at fileURL: URL,
        payJetons: Int = 0,
        onProgress: ((Double) -> Void)? = nil,
    ) async throws -> UploadResult {
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
        struct UploadOut: Decodable {
            let media_id: String
            let size: Int
            let jetons_charged: Int?
            let wallet_tokens: Int?
        }
        var fields: [String: String] = [:]
        if payJetons > 0 { fields["pay_jetons"] = String(payJetons) }
        let out: UploadOut = try await APIClient.shared.uploadBlob(
            "/media/upload",
            field: "blob",
            filename: fileURL.lastPathComponent,
            contentType: "application/octet-stream",
            data: combined,
            extraFields: fields,
            onProgress: onProgress,
        )
        let keyB64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        // Reflect the server-issued wallet balance immediately so the
        // Settings readout + composer don't have to re-sync.
        if let newBalance = out.wallet_tokens {
            await MainActor.run { ItemsService.shared.setWalletTokens(newBalance) }
        }
        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
    }

    /// Current-month traffic snapshot for the Settings readout.
    func fetchTrafficUsage() async -> TrafficUsage? {
        struct Out: Decodable {
            let year_month: String
            let bytes_used: Int
            let jetons_spent: Int
        }
        do {
            let out: Out = try await APIClient.shared.request("GET", "/media/usage")
            return TrafficUsage(
                yearMonth: out.year_month,
                bytesUsed: out.bytes_used,
                jetonsSpent: out.jetons_spent,
            )
        } catch {
            return nil
        }
    }

    struct TrafficUsage: Equatable {
        let yearMonth: String
        let bytesUsed: Int
        let jetonsSpent: Int
    }

    /// Download + decrypt the blob and return raw plaintext bytes. Used
    /// by the file bubble's QuickLook open: caller writes bytes to a
    /// temp file with the original filename so QL infers the type from
    /// the extension. Hits the in-memory data cache when warm so a
    /// re-tap inside the same chat session is instant.
    func fetchDecrypted(mediaID: String, keyBase64: String) async -> Data? {
        let cacheKey = (mediaID + ":" + keyBase64) as NSString
        if let hit = decryptedDataCache.object(forKey: cacheKey) {
            return hit as Data
        }
        do {
            let blob = try await APIClient.shared.downloadBlob("/media/\(mediaID)")
            guard let keyBytes = Data(base64Encoded: keyBase64) else { return nil }
            let plain: Data? = await Task.detached(priority: .userInitiated) {
                let key = SymmetricKey(data: keyBytes)
                guard let box = try? AES.GCM.SealedBox(combined: blob),
                      let plain = try? AES.GCM.open(box, using: key) else { return nil }
                return plain
            }.value
            guard let plain else { return nil }
            decryptedDataCache.setObject(plain as NSData, forKey: cacheKey, cost: plain.count)
            return plain
        } catch {
            return nil
        }
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

    /// Synchronous cache peek. Used by views that want to render the
    /// first frame already populated when the image is hot in cache —
    /// otherwise the async `.task` path runs and the fallback glyph
    /// flashes through the entrance animation. Returns nil on miss;
    /// caller still kicks off `loadImage` to fill on miss.
    ///
    /// `nonisolated` because NSCache itself is thread-safe and we want
    /// to call this from SwiftUI `init`s without an actor hop.
    nonisolated func cachedImage(mediaID: String, keyBase64: String) -> UIImage? {
        let cacheKey = (mediaID + ":" + keyBase64) as NSString
        return decryptedCache.object(forKey: cacheKey)
    }

    /// Fetch + decrypt + cache. Decrypt and JPEG decode run off-main to keep the SwiftUI runloop responsive.
    func loadImage(mediaID: String, keyBase64: String) async -> UIImage? {
        let cacheKey = (mediaID + ":" + keyBase64) as NSString
        if let hit = decryptedCache.object(forKey: cacheKey) { return hit }
        do {
            let mediaKey = mediaID as NSString
            let blob: Data
            if let prefetched = encryptedBlobCache.object(forKey: mediaKey) {
                blob = prefetched as Data
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
            decryptedCache.setObject(image, forKey: cacheKey)
            // Promote out of the encrypted-blob cache — we have the
            // decoded UIImage now, holding both is wasteful. NSCache
            // would evict it on its own eventually but explicit is
            // clearer.
            encryptedBlobCache.removeObject(forKey: mediaKey)
            return image
        } catch {
            return nil
        }
    }

    /// Like `loadImage` but also returns the raw decrypted bytes so
    /// the caller can decide whether to render as static image or
    /// animated GIF based on magic-byte detection. UIImage path is
    /// shared with `loadImage` cache; the data tuple is independently
    /// cached because UIImage doesn't preserve the source bytes.
    func loadImageWithData(mediaID: String, keyBase64: String) async -> (UIImage, Data)? {
        let cacheKey = (mediaID + ":" + keyBase64) as NSString
        if let img = decryptedCache.object(forKey: cacheKey),
           let nsData = decryptedDataCache.object(forKey: cacheKey) {
            return (img, nsData as Data)
        }
        do {
            let mediaKey = mediaID as NSString
            let blob: Data
            if let prefetched = encryptedBlobCache.object(forKey: mediaKey) {
                blob = prefetched as Data
            } else {
                blob = try await APIClient.shared.downloadBlob("/media/\(mediaID)")
            }
            guard let keyBytes = Data(base64Encoded: keyBase64) else { return nil }
            let result: (UIImage, Data)? = await Task.detached(priority: .userInitiated) {
                let key = SymmetricKey(data: keyBytes)
                guard let box = try? AES.GCM.SealedBox(combined: blob),
                      let plain = try? AES.GCM.open(box, using: key),
                      let raw = UIImage(data: plain) else {
                    return nil
                }
                let format = UIGraphicsImageRendererFormat.preferred()
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: raw.size, format: format)
                let decoded = renderer.image { _ in
                    raw.draw(in: CGRect(origin: .zero, size: raw.size))
                }
                return (decoded, plain)
            }.value
            guard let (image, plain) = result else { return nil }
            decryptedCache.setObject(image, forKey: cacheKey)
            decryptedDataCache.setObject(plain as NSData, forKey: cacheKey, cost: plain.count)
            encryptedBlobCache.removeObject(forKey: mediaKey)
            return (image, plain)
        } catch {
            return nil
        }
    }

    /// Prefetch encrypted blob without decrypting. Idempotent.
    ///
    /// NOTE: previously this checked `decryptedCache` for any entry
    /// whose key started with `mediaID + ":"` and skipped the fetch if
    /// one existed. NSCache exposes no key iteration so that
    /// optimisation is gone — worst case the prefetch fetches a blob
    /// we already have decoded, which is harmless (we just keep the
    /// encrypted bytes around too). The subsequent loadImage hits the
    /// decrypted cache first regardless.
    func prefetchEncrypted(mediaID: String) async {
        let mediaKey = mediaID as NSString
        if encryptedBlobCache.object(forKey: mediaKey) != nil { return }
        do {
            let blob = try await APIClient.shared.downloadBlob("/media/\(mediaID)")
            encryptedBlobCache.setObject(blob as NSData, forKey: mediaKey, cost: blob.count)
        } catch {
        }
    }
}
