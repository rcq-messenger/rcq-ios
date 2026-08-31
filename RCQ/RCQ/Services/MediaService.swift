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
           let (data, resp) = try? await IslandHTTP.data(from: url),
           let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            return data
        }
        do {
            return try await APIClient.shared.downloadBlob("/media/\(mediaID)")
        } catch {
            for v in VisitedIslandsStore.shared.list() {
                if let url = URL(string: "https://\(v.host)/media/\(mediaID)"),
                   let (data, resp) = try? await IslandHTTP.data(from: url),
                   let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return data
                }
            }
            throw error
        }
    }

    /// The most plaintext this app will materialise from ONE monolithic blob.
    ///
    /// ⚠⚠ A receive-side ceiling, and it exists because the send side stopped
    /// being one. A single-seal blob has to be held whole, copied into the
    /// sealed box and allocated again as plaintext before its tag can be
    /// checked, so a 400 MB video is roughly a gigabyte of live allocation for
    /// one tap on a bubble: jetsam takes the app out before anything can be
    /// shown, and to the person that is "RCQ crashes when I open a video".
    /// Refusing reads as a failed download, which is honest and survivable.
    /// Chunked containers are NOT subject to this: they cost one chunk.
    nonisolated static let inMemoryPlaintextCeiling: Int = 96 * 1024 * 1024

    /// `fetchBlob` for a blob nobody should hold: the same island ladder, with
    /// the bytes written straight to `destination`.
    nonisolated static func fetchBlob(mediaID: String, host: String? = nil, to destination: URL) async throws {
        if let host, let url = URL(string: "https://\(host)/media/\(mediaID)"),
           await downloadIsland(url, to: destination) {
            return
        }
        do {
            try await APIClient.shared.downloadBlob("/media/\(mediaID)", to: destination)
        } catch {
            for v in VisitedIslandsStore.shared.list() {
                if let url = URL(string: "https://\(v.host)/media/\(mediaID)"),
                   await downloadIsland(url, to: destination) {
                    return
                }
            }
            throw error
        }
    }

    private nonisolated static func downloadIsland(_ url: URL, to destination: URL) async -> Bool {
        guard let (tmp, resp) = try? await IslandHTTP.download(for: URLRequest(url: url)) else { return false }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        try? FileManager.default.removeItem(at: destination)
        return (try? FileManager.default.moveItem(at: tmp, to: destination)) != nil
    }

    /// Deposit an already-encrypted blob under a client-chosen id
    /// (`PUT /media/{id}`, idempotent, no auth — same trust model as the
    /// envelope deposit). Plain URLSession to the peer's island, the same
    /// accepted simplification as `CrossIslandSender`.
    ///
    /// Not private: §5e deposits the OWNER'S AVATAR blob to a cross-island
    /// contact's island through this, so the picture renders from the island
    /// they already read from and keeps rendering while ours is down.
    nonisolated static func putBlob(host: String, mediaID: String, data: Data) async -> Bool {
        // Belt and braces next to the chokepoint above: this one is a plain
        // URLSession PUT to an ARBITRARY island, so it is exactly the shape
        // that walks around the gate. Reached from the §5e avatar deposit as
        // well as from a send.
        if await PanicPINService.shared.isDecoy { return false }
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
            let (_, resp) = try await IslandHTTP.upload(for: req, from: body)
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
        // ⚠⚠ A duress session uploads nothing, to any island. This is the
        // single chokepoint every media send funnels through (photo, GIF,
        // file, voice), which is why the check is here and not in four places.
        //
        // Without it a photo picked in the decoy took the same path as a real
        // one: the own-island branch is `APIClient`, so `DuressGate` threw and
        // the caller painted a FAILED bubble — the same tell as the red cross
        // we just took out of the text path — and the cross-island branch is
        // `putBlob`, a plain URLSession PUT that the gate never saw at all.
        //
        // A client-minted id and no network: the callers seed their caches off
        // the id we return, so the picture renders in the decoy exactly as a
        // sent one, and the send path marks the row sent.
        if PanicPINService.shared.isDecoy {
            return UploadOut(media_id: Self.newMediaID(), size: combined.count)
        }
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
    /// `under` seals the blob with a key the CALLER owns instead of a fresh
    /// one. Only the avatar path passes it (docs/profile-key-design.md): a
    /// profile picture has to stay readable by every contact who already holds
    /// the key, so changing the picture must NOT change the key - otherwise
    /// each change costs a fan-out and blanks every contact's tile until it
    /// lands. Everything else keeps minting per blob, which is right for
    /// message media: those keys travel with the message.
    func uploadImage(_ image: UIImage, peerHost: String? = nil, under: String? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        guard let jpeg = ImageCompressor.compress(image, maxSide: 1200, quality: 0.8) else {
            throw Failure.compressionFailed
        }
        let key: SymmetricKey
        if let under, let raw = Data(base64Encoded: under), raw.count == 32 {
            key = SymmetricKey(data: raw)
        } else {
            key = SymmetricKey(size: .bits256)
        }
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
    /// `under`: see [uploadImage]. An animated avatar needs the same treatment.
    func uploadGIF(data: Data, peerHost: String? = nil, under: String? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        if data.count > Self.maxBlobBytes {
            throw Failure.tooLarge(actualBytes: data.count)
        }
        let key: SymmetricKey
        if let under, let raw = Data(base64Encoded: under), raw.count == 32 {
            key = SymmetricKey(data: raw)
        } else {
            key = SymmetricKey(size: .bits256)
        }
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
            let ceiling = Self.inMemoryPlaintextCeiling
            let plain: Data? = await Task.detached(priority: .userInitiated) {
                let key = SymmetricKey(data: keyBytes)
                // A chunked container arrives here whenever a client that seals
                // large files that way sent something this path fetches. It is
                // opened chunk by chunk; the ceiling is on the plaintext this
                // function has promised to return whole, not on the download.
                if MediaChunkedBlob.looksChunked(blob) {
                    return try? MediaChunkedBlob.decryptToData(blob: blob, key: key, ceiling: ceiling)
                }
                guard blob.count <= ceiling + 12 + 16 else { return nil }
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
    ///
    /// ⚠⚠ Nothing on this path holds the whole file, and that is not an
    /// optimisation. This is where the heaviest blobs in the app land, and the
    /// old shape (fetch to `Data`, copy into a sealed box, allocate the
    /// plaintext, write it out) was three full-size copies of a video: for a
    /// long clip that is a jetsam kill, which the person reads as the app
    /// quitting when they tap play. The download streams to disk, and a chunked
    /// container is opened one chunk at a time.
    ///
    /// A monolithic blob still has to be held whole (its one tag covers all of
    /// it), so it is refused past `inMemoryPlaintextCeiling` instead of being
    /// attempted. A failed decrypt is a bubble that says so; an OOM is not.
    func decryptToFile(mediaID: String, keyBase64: String) async -> URL? {
        guard let keyBytes = Data(base64Encoded: keyBase64) else { return nil }
        let key = SymmetricKey(data: keyBytes)
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent("rcq-blob-\(mediaID).bin")
        let out = fm.temporaryDirectory.appendingPathComponent("rcq-play-\(mediaID).mp4")
        // The scratch path is the one the decrypt writes to, so a container
        // that fails half way through never leaves a truncated clip behind
        // under the name a player is about to be handed.
        let scratch = fm.temporaryDirectory.appendingPathComponent("rcq-play-\(mediaID).part")
        defer {
            try? fm.removeItem(at: container)
            try? fm.removeItem(at: scratch)
        }
        do {
            try await Self.fetchBlob(mediaID: mediaID, to: container)
            let ceiling = Self.inMemoryPlaintextCeiling
            let chunked = MediaChunkedBlob.looksChunked(fileAt: container)
            try await Task.detached(priority: .userInitiated) {
                if chunked {
                    try MediaChunkedBlob.decrypt(fileAt: container, key: key, to: scratch)
                    return
                }
                let size = (try FileManager.default.attributesOfItem(atPath: container.path)[.size] as? Int) ?? 0
                guard size <= ceiling + 12 + 16 else { throw MediaChunkedBlob.Failure.tooLarge }
                let blob = try Data(contentsOf: container, options: .mappedIfSafe)
                let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: key)
                try plain.write(to: scratch, options: .atomic)
            }.value
            try? fm.removeItem(at: out)
            try fm.moveItem(at: scratch, to: out)
            return out
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
