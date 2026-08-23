import CryptoKit
import Foundation

/// RCQM1, the chunked media container: the large-file twin of the single
/// AES-256-GCM seal (`nonce(12) || ciphertext || tag(16)`) every other blob in
/// this app uses.
///
/// ## Why it exists at all
///
/// A monolithic GCM seal puts its tag at the END, so no honest implementation
/// may hand out a byte of plaintext before it has read the last byte and
/// checked the tag. That is what "authenticated" means, and it puts a floor
/// under what a download costs in memory: the blob, the provider's copy of it,
/// and the plaintext, all live at once. Somewhere past a 40 s clip that floor
/// is above what a phone will give a single app, and the failure is silent on
/// every client: an allocation that does not come back reads as "the video
/// never loaded".
///
/// Android ships the way out (`crypto/MediaStream.kt`): the plaintext is cut
/// into chunks and each chunk gets its own seal under the same per-blob key, so
/// an open costs one chunk of memory whatever the file weighs. THIS FILE IS THE
/// READER FOR THAT FORMAT. Without it a video sent from a recent Android build
/// is a dead bubble here: the first 12 bytes of the magic get read as a GCM
/// nonce, the tag check fails, and nothing on screen says why.
///
/// ## The container
///
/// ```
///   offset  0 : magic       "RCQM1"                     5
///   offset  5 : version     0x01                        1
///   offset  6 : chunkSize   uint32 BE, plaintext bytes  4
///   offset 10 : chunkCount  uint32 BE                   4
///   offset 14 : plainLen    uint64 BE                   8
///   offset 22 : noncePrefix random                      8
///                                                      -- 30 bytes
///   then chunkCount records, record i = ciphertext(len_i) || tag(16)
///   len_i = chunkSize, except the last = plainLen - chunkSize*(chunkCount-1)
/// ```
///
/// * nonce for chunk i = `noncePrefix || uint32BE(i)`. The prefix is fresh
///   random per blob and the KEY is fresh random per blob, so no nonce repeats
///   under a key even if two blobs draw the same prefix.
/// * AAD for chunk i = `header(30) || uint32BE(i)`.
///
/// Every structural fact lives in the header and the header is in the AAD of
/// every chunk, so one tag failure is the answer to a chunk moved, duplicated,
/// dropped or swapped in, and to the file being truncated, extended or edited.
///
/// ## What this side does NOT do
///
/// It does not WRITE containers. iOS still seals every outgoing blob
/// monolithically, which every shipped client on every platform reads. Sending
/// this format is a separate decision with a compatibility cost; reading it is
/// the part that has to exist the moment anything can send it.
enum MediaChunkedBlob {

    enum Failure: Error {
        /// Not an RCQM1 container. The caller should treat the blob as the
        /// ordinary monolithic seal.
        case notChunked
        /// The header does not describe this file, or the bytes ran out.
        case malformed
        /// A chunk did not authenticate: reordered, truncated or edited.
        case authentication
        /// Bigger than the caller said it was willing to hold.
        case tooLarge
    }

    /// The fixed header, and the only part of the container read before
    /// anything has been authenticated.
    static let headerLength = 30

    private static let magic: [UInt8] = Array("RCQM1".utf8)
    private static let version: UInt8 = 1
    private static let tagLength = 16
    private static let noncePrefixLength = 8

    /// Sanity bounds on a header that arrived off the network. A blob claiming
    /// a 2 GB chunk size must not make us allocate one, and a blob claiming
    /// 2^63 plaintext bytes must not be multiplied by anything.
    private static let minChunkSize = 64 * 1024
    private static let maxChunkSize = 16 * 1024 * 1024
    private static let maxPlainLength: Int64 = 64 * 1024 * 1024 * 1024

    struct Header {
        /// The 30 header bytes exactly as they arrived: they are the AAD.
        let bytes: [UInt8]
        let chunkSize: Int
        let chunkCount: Int
        let plainLength: Int64
    }

    // MARK: - Sniffing

    /// Are these leading bytes an RCQM1 container rather than a monolithic
    /// seal? A monolithic blob starts with a 12-byte GCM nonce we generated
    /// ourselves, so it can collide with this magic only by chance, at 1 in
    /// 2^48 per blob.
    static func looksChunked(_ head: Data) -> Bool {
        guard head.count >= magic.count + 1 else { return false }
        let start = head.startIndex
        for (i, b) in magic.enumerated() where head[start + i] != b { return false }
        return head[start + magic.count] == version
    }

    static func looksChunked(fileAt url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: magic.count + 1) else { return false }
        return looksChunked(head)
    }

    // MARK: - Geometry

    static func chunkCount(plainLength: Int64, chunkSize: Int) -> Int {
        if plainLength <= 0 { return 1 }
        let n = (plainLength + Int64(chunkSize) - 1) / Int64(chunkSize)
        return n > Int64(Int.max) ? Int.max : Int(n)
    }

    /// Exact encoded length of a container holding this much plaintext.
    static func blobLength(plainLength: Int64, chunkSize: Int) -> Int64 {
        Int64(headerLength) + plainLength + Int64(tagLength) * Int64(chunkCount(plainLength: plainLength, chunkSize: chunkSize))
    }

    // MARK: - Header

    /// Parse and sanity-check the header of a container whose encoded length is
    /// `blobLength`.
    ///
    /// ⚠ Order matters: the bounds are checked BEFORE any arithmetic runs on
    /// the numbers they bound, so a header claiming 2^63 bytes is rejected here
    /// rather than inside a multiplication.
    static func header(_ data: Data, blobLength: Int64) throws -> Header {
        guard data.count >= headerLength else { throw Failure.malformed }
        let bytes = [UInt8](data.prefix(headerLength))
        guard looksChunked(Data(bytes)) else { throw Failure.notChunked }
        let chunkSize = Int(u32(bytes, 6))
        let chunkCount = Int(u32(bytes, 10))
        let declared = u64(bytes, 14)
        guard declared <= UInt64(maxPlainLength) else { throw Failure.malformed }
        let plainLength = Int64(declared)
        guard chunkSize >= minChunkSize, chunkSize <= maxChunkSize,
              chunkCount > 0,
              chunkCount == self.chunkCount(plainLength: plainLength, chunkSize: chunkSize),
              blobLength == self.blobLength(plainLength: plainLength, chunkSize: chunkSize)
        else { throw Failure.malformed }
        return Header(bytes: bytes, chunkSize: chunkSize, chunkCount: chunkCount, plainLength: plainLength)
    }

    /// The plaintext length this container holds, without decrypting anything.
    /// Authenticated in the sense that every chunk's tag covers it, so a lie
    /// here is caught by the first chunk that is opened.
    static func plainLength(fileAt url: URL) throws -> Int64 {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let head = try fh.read(upToCount: headerLength) else { throw Failure.malformed }
        return try header(head, blobLength: fileLength(url)).plainLength
    }

    /// The encoded length on disk. Zero for a file that is not there, which
    /// every caller below turns into `malformed` rather than a crash.
    private static func fileLength(_ url: URL) -> Int64 {
        let n = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        return n.flatMap { $0 } ?? 0
    }

    // MARK: - Decrypt

    /// Decrypt a container on disk to `destination`, verifying EVERY chunk on
    /// the way and never holding more than one chunk of plaintext.
    ///
    /// ⚠ Throws part-way through on a bad tag, leaving a partial file behind on
    /// purpose: the caller writes to a scratch path and only publishes it when
    /// this returns. Handing back a truncated video as if it were the whole one
    /// is exactly the failure this container was built to make impossible.
    static func decrypt(fileAt url: URL, key: SymmetricKey, to destination: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let head = try fh.read(upToCount: headerLength) else { throw Failure.malformed }
        let h = try header(head, blobLength: fileLength(url))

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw Failure.malformed }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        for index in 0..<h.chunkCount {
            let plain = try openChunk(reading: fh, index: index, header: h, key: key)
            try out.write(contentsOf: plain)
        }
        try out.synchronize()
    }

    /// The whole plaintext in memory, for a caller that genuinely needs bytes
    /// rather than a file. `ceiling` is the most the caller is willing to hold:
    /// past it this refuses instead of being killed for the allocation.
    static func decryptToData(fileAt url: URL, key: SymmetricKey, ceiling: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let head = try fh.read(upToCount: headerLength) else { throw Failure.malformed }
        let h = try header(head, blobLength: fileLength(url))
        guard h.plainLength <= Int64(ceiling) else { throw Failure.tooLarge }
        var out = Data(capacity: Int(h.plainLength))
        for index in 0..<h.chunkCount {
            out.append(try openChunk(reading: fh, index: index, header: h, key: key))
        }
        return out
    }

    /// The same, for a container that is already in memory (a blob small enough
    /// that the caller had it as `Data` before it knew which shape it was).
    static func decryptToData(blob: Data, key: SymmetricKey, ceiling: Int) throws -> Data {
        let h = try header(blob, blobLength: Int64(blob.count))
        guard h.plainLength <= Int64(ceiling) else { throw Failure.tooLarge }
        var out = Data(capacity: Int(h.plainLength))
        var offset = blob.startIndex + headerLength
        for index in 0..<h.chunkCount {
            let want = chunkPlainLength(index: index, header: h) + tagLength
            guard blob.endIndex - offset >= want else { throw Failure.malformed }
            let record = blob.subdata(in: offset..<(offset + want))
            offset += want
            out.append(try open(record: record, index: index, header: h, key: key))
        }
        return out
    }

    // MARK: - Internals

    private static func chunkPlainLength(index: Int, header h: Header) -> Int {
        let remaining = h.plainLength - Int64(index) * Int64(h.chunkSize)
        return Int(max(0, min(Int64(h.chunkSize), remaining)))
    }

    private static func openChunk(reading fh: FileHandle, index: Int, header h: Header, key: SymmetricKey) throws -> Data {
        let want = chunkPlainLength(index: index, header: h) + tagLength
        guard let record = try fh.read(upToCount: want), record.count == want else { throw Failure.malformed }
        return try open(record: record, index: index, header: h, key: key)
    }

    private static func open(record: Data, index: Int, header h: Header, key: SymmetricKey) throws -> Data {
        guard record.count >= tagLength else { throw Failure.malformed }
        let split = record.endIndex - tagLength
        let ciphertext = record.subdata(in: record.startIndex..<split)
        let tag = record.subdata(in: split..<record.endIndex)
        var nonceBytes = Data(h.bytes[22..<(22 + noncePrefixLength)])
        nonceBytes.append(contentsOf: u32be(index))
        var aad = Data(h.bytes)
        aad.append(contentsOf: u32be(index))
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceBytes), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw Failure.authentication
        }
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(b[at]) << 24) | (UInt32(b[at + 1]) << 16) | (UInt32(b[at + 2]) << 8) | UInt32(b[at + 3])
    }

    private static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[at + i]) }
        return v
    }

    private static func u32be(_ v: Int) -> [UInt8] {
        let n = UInt32(truncatingIfNeeded: v)
        return [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
    }
}
