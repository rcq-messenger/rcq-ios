import Foundation

/// Disk cache for encrypted media blobs (raw `/media/<id>` payloads).
/// Blobs are encrypted at rest with a per-blob key held in the
/// message envelope, not here — leaking the bytes leaks nothing on
/// its own. LRU-swept against a soft cap.
final class EncryptedBlobDiskCache {
    static let shared = EncryptedBlobDiskCache()

    static let maxBytes: Int = 500 * 1024 * 1024

    private let queue = DispatchQueue(label: "rcq.blob-disk-cache", qos: .utility)
    private let rootURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.rootURL = caches.appendingPathComponent("rcq-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Fast nonisolated read — no mtime touch.
    nonisolated func cachedBlob(mediaID: String) -> Data? {
        let path = path(for: mediaID)
        return try? Data(contentsOf: path, options: .mappedIfSafe)
    }

    /// Async read that bumps mtime for LRU.
    func loadBlob(mediaID: String) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            queue.async {
                let path = self.path(for: mediaID)
                guard let data = try? Data(contentsOf: path, options: .mappedIfSafe) else {
                    cont.resume(returning: nil)
                    return
                }
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: path.path,
                )
                cont.resume(returning: data)
            }
        }
    }

    /// Persist an encrypted blob. Atomic-write so a kill mid-write
    /// can't leave a half-truncated row.
    func storeBlob(mediaID: String, data: Data) {
        let path = path(for: mediaID)
        queue.async {
            try? data.write(to: path, options: [.atomic])
        }
    }

    /// LRU sweep — keeps total under `maxBytes`.
    func sweep() {
        queue.async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: self.rootURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
            ) else { return }
            var sized: [(url: URL, size: Int, mtime: Date)] = []
            var total: Int = 0
            for u in entries {
                let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = vals?.fileSize ?? 0
                let mtime = vals?.contentModificationDate ?? Date.distantPast
                sized.append((u, size, mtime))
                total += size
            }
            guard total > Self.maxBytes else { return }
            sized.sort { $0.mtime < $1.mtime }
            for entry in sized {
                if total <= Self.maxBytes { break }
                try? fm.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }

    /// Wipe everything — called from the account-burn path.
    func clear() {
        queue.async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: self.rootURL, includingPropertiesForKeys: nil
            ) else { return }
            for u in entries { try? fm.removeItem(at: u) }
        }
    }

    private nonisolated func path(for mediaID: String) -> URL {
        rootURL.appendingPathComponent("\(mediaID).bin")
    }
}
