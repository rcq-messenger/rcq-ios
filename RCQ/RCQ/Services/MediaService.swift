import CryptoKit
import Foundation
import UIKit

/// Encrypted media upload/download. Server stores opaque blobs; per-blob key travels in the encrypted envelope.
@MainActor
final class MediaService {
    static let shared = MediaService()

    /// Matches backend `MAX_BLOB_SIZE`. Upper bound for media uploads.
    nonisolated static let maxBlobBytes: Int = 2 * 1024 * 1024 * 1024

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
    nonisolated(unsafe) private let decryptedDataCache: NSCache<NSString, NSData> = {
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

    private init() {
        EncryptedBlobDiskCache.shared.sweep()
    }

    enum Failure: Error, LocalizedError {
        case compressionFailed
        case encryptionFailed
        case crossIslandDepositFailed
        case tooLarge(actualBytes: Int)

        var errorDescription: String? {
            switch self {
            case .compressionFailed: return "media.error.compression".localized
            case .encryptionFailed:  return "media.error.encryption".localized
            case .crossIslandDepositFailed: return "media.error.deposit".localized
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

    private struct UploadOut: Decodable { let media_id: String; let size: Int }

    /// Client-chosen media id (uuid4 hex) for the cross-island deposit — the
    /// same id must resolve on every island the blob is PUT to.
    private nonisolated static func newMediaID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Download an encrypted blob, own island first. §5c: cross-island GROUP
    /// media lives on the GROUP's island (the sender deposits it there, not
    /// ours), so on an own-island miss fall back to each VISITED island's open
    /// `GET /media/{id}`. Zero view changes — every fetcher routes through here.
    nonisolated static func fetchBlob(mediaID: String, host: String? = nil) async throws -> Data {
        // When the caller knows the blob's island (a cross-island GROUP avatar
        // lives on the GROUP's host), try it FIRST — relying on the visited-island
        // fallback was flaky because the group's island isn't always visited (the
        // "group avatar sometimes shows" report).
        if let host, let url = URL(string: "https://\(host)/media/\(mediaID)"),
           let (data, resp) = try? await URLSession.shared.data(from: url),
           let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            return data
        }
        do {
            return try await APIClient.shared.downloadBlob("/media/\(mediaID)")
        } catch {
            for v in VisitedIslandsStore.shared.list() {
                if let url = URL(string: "https://\(v.host)/media/\(mediaID)"),
                   let (data, resp) = try? await URLSession.shared.data(from: url),
                   let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return data
                }
            }
            throw error
        }
    }

    /// Deposit an already-encrypted blob under a client-chosen id
    /// (`PUT /media/{id}`, idempotent, no auth — same trust model as the
    /// envelope deposit). Plain URLSession to the peer's island, the same
    /// accepted simplification as `CrossIslandSender`.
    private nonisolated static func putBlob(host: String, mediaID: String, data: Data) async -> Bool {
        guard let url = URL(string: "https://\(host)/media/\(mediaID)") else { return false }
        let boundary = "----RCQBoundary\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"blob\"; filename=\"photo.bin\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Upload an encrypted blob. Same-island sends POST /media/upload (the
    /// server mints the id). For a CROSS-ISLAND peer (`peerHost` set) the
    /// recipient fetches media from their OWN island, so the blob is
    /// DEPOSITED there under a client-chosen id (deposit-the-blob — islands
    /// never talk; the message survives our island dying), plus a copy on our
    /// island for carbons + own re-fetch. Mirrors web-chat media.ts / Android.
    private func uploadCombined(
        _ combined: Data,
        filename: String,
        peerHost: String?,
        onProgress: ((Double) -> Void)?
    ) async throws -> UploadOut {
        guard let peerHost else {
            return try await APIClient.shared.uploadBlob(
                "/media/upload",
                field: "blob",
                filename: filename,
                contentType: "application/octet-stream",
                data: combined,
                onProgress: onProgress
            )
        }
        let mediaID = Self.newMediaID()
        // The peer-island copy is REQUIRED — that's the one they read.
        guard await Self.putBlob(host: peerHost, mediaID: mediaID, data: combined) else {
            throw Failure.crossIslandDepositFailed
        }
        // Own-island copy (carbons + re-fetch), via APIClient so it rides the
        // same transport as every own-island call. Best-effort.
        let _: UploadOut? = try? await APIClient.shared.uploadBlob(
            "/media/\(mediaID)",
            field: "blob",
            filename: filename,
            contentType: "application/octet-stream",
            data: combined,
            method: "PUT",
            onProgress: onProgress
        )
        return UploadOut(media_id: mediaID, size: combined.count)
    }

    /// Compress, encrypt, and upload an image. Returns server media id + AES key for the envelope.
    func uploadImage(_ image: UIImage, peerHost: String? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
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

        let out: UploadOut = try await uploadCombined(combined, filename: "photo.bin", peerHost: peerHost, onProgress: onProgress)

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
    func uploadGIF(data: Data, peerHost: String? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
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
        let out: UploadOut = try await uploadCombined(combined, filename: "photo.bin", peerHost: peerHost, onProgress: onProgress)
        let keyB64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        // Seed the data cache so the sender's own bubble doesn't have
        // to re-download + re-decrypt the bytes we already have.
        let cacheKey = (out.media_id + ":" + keyB64) as NSString
        decryptedDataCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
    }

    /// Encrypt + upload an arbitrary file (used for video + documents).
    func uploadFile(
        at fileURL: URL,
        peerHost: String? = nil,
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
        let out: UploadOut = try await uploadCombined(combined, filename: fileURL.lastPathComponent, peerHost: peerHost, onProgress: onProgress)
        let keyB64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return UploadResult(mediaID: out.media_id, keyBase64: keyB64)
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
            let blob = try await Self.fetchBlob(mediaID: mediaID)
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
            let blob = try await Self.fetchBlob(mediaID: mediaID)
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

    /// Cached raw decrypted bytes — paired with `cachedImage` so the
    /// caller can magic-byte detect GIFs.
    nonisolated func cachedData(mediaID: String, keyBase64: String) -> Data? {
        let cacheKey = (mediaID + ":" + keyBase64) as NSString
        return decryptedDataCache.object(forKey: cacheKey) as Data?
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
            } else if let onDisk = await EncryptedBlobDiskCache.shared.loadBlob(mediaID: mediaID) {
                blob = onDisk
            } else {
                blob = try await Self.fetchBlob(mediaID: mediaID)
                EncryptedBlobDiskCache.shared.storeBlob(mediaID: mediaID, data: blob)
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
    func loadImageWithData(mediaID: String, keyBase64: String, host: String? = nil) async -> (UIImage, Data)? {
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
            } else if let onDisk = await EncryptedBlobDiskCache.shared.loadBlob(mediaID: mediaID) {
                blob = onDisk
            } else {
                blob = try await Self.fetchBlob(mediaID: mediaID, host: host)
                EncryptedBlobDiskCache.shared.storeBlob(mediaID: mediaID, data: blob)
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
        // Disk-cache hit is enough; loader paths also check disk.
        if EncryptedBlobDiskCache.shared.cachedBlob(mediaID: mediaID) != nil {
            return
        }
        do {
            let blob = try await Self.fetchBlob(mediaID: mediaID)
            encryptedBlobCache.setObject(blob as NSData, forKey: mediaKey, cost: blob.count)
            EncryptedBlobDiskCache.shared.storeBlob(mediaID: mediaID, data: blob)
        } catch {
        }
    }
}
