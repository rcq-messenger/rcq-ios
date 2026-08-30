import Foundation
import Compression
import CryptoKit

/// Sealed room identity, the READER half (stage 6 phase 2).
///
/// The island stores an opaque blob per room; a member holding the room
/// state key (RSK) overlays the sealed name/description/avatar/pin over the
/// open columns, everyone else renders the columns as before. Wire format
/// and the key story: rcq-docs/group-state-seal-design.md. The web writes;
/// this client reads, receives the key (inner kinds gskey/gsknack under the
/// outer types skdm/sknack) and answers asks.
///
/// Blob layout `[0x02][key_ver u32 BE][nonce 12][AES-256-GCM ct]` over RAW
/// deflate - the same nowrap framing the web writes and Android inflates.
/// The open key_ver is the one fact a keyless client needs: which key
/// generation to ask for, and what a replacement mint must exceed.
enum GroupStateSeal {

    private static let blobV2: UInt8 = 0x02

    struct Sealed {
        let name: String?
        let description: String?
        let avatarMediaID: String?
        let avatarMediaKey: String?
        let pinnedText: String?
    }

    /// The key generation a blob was sealed under, without the key.
    static func sealedKeyVer(_ blobB64: String) -> Int64? {
        guard let b = Data(base64Encoded: blobB64), b.count >= 18, b[b.startIndex] == blobV2 else { return nil }
        let v = b.subdata(in: b.startIndex + 1..<b.startIndex + 5)
        return v.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
    }

    /// Decrypt + inflate. Nil on any failure; the caller falls back to the
    /// open columns.
    static func open(_ blobB64: String, keyB64: String) -> Sealed? {
        guard let blob = Data(base64Encoded: blobB64), blob.count >= 13,
              let key = Data(base64Encoded: keyB64), key.count == 32 else { return nil }
        let off = (blob[blob.startIndex] == blobV2 && blob.count >= 18) ? 5 : 0
        let nonceData = blob.subdata(in: blob.startIndex + off..<blob.startIndex + off + 12)
        let ctAndTag = blob.subdata(in: blob.startIndex + off + 12..<blob.endIndex)
        guard ctAndTag.count > 16, let nonce = try? AES.GCM.Nonce(data: nonceData) else { return nil }
        let ct = ctAndTag.dropLast(16)
        let tag = ctAndTag.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let deflated = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        guard let plain = inflateRaw(deflated) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              obj["v"] as? Int == 1 else { return nil }
        return Sealed(
            name: obj["name"] as? String,
            description: obj["description"] as? String,
            avatarMediaID: obj["avatar_media_id"] as? String,
            avatarMediaKey: obj["avatar_media_key"] as? String,
            pinnedText: obj["pinned_text"] as? String
        )
    }

    /// Overlay the sealed identity onto `g` when `keyB64` opens its blob.
    static func overlay(_ g: RCQGroup, keyB64: String?) -> RCQGroup {
        guard let blob = g.stateBlob, let key = keyB64, let s = open(blob, keyB64: key) else { return g }
        var out = g
        if let n = s.name, !n.isEmpty { out.name = n }
        if let d = s.description { out.description = d }
        if let id = s.avatarMediaID { out.avatarMediaID = id }
        if let k = s.avatarMediaKey { out.avatarMediaKey = k }
        if let p = s.pinnedText { out.pinnedText = p }
        return out
    }

    /// Raw-deflate inflate (nowrap). COMPRESSION_ZLIB in Apple's framework IS
    /// the raw DEFLATE stream - no zlib header - which is exactly what the
    /// web's CompressionStream('deflate-raw') writes.
    private static func inflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let dstCap = max(64 * 1024, data.count * 8)
        var dst = Data(count: dstCap)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCap,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        dst.removeSubrange(written..<dst.count)
        return dst
    }
}

/// Per-account room-key store, the iOS twin of the web's localStorage map.
/// UserDefaults keyed by the account uuid, decoy-guarded the same way the
/// capabilities cache is: a decoy session neither reads nor writes it.
@MainActor
final class RoomKeyStore {
    static let shared = RoomKeyStore()

    private var cache: [Int: (ver: Int64, key: String)] = [:]
    private var loadedFor: String?

    private func storageKey(_ account: String) -> String { "rcq.gskeys.v1.\(account)" }

    private var accountID: String? {
        guard !PanicPINService.shared.isDecoy else { return nil }
        return AccountManager.shared.activeAccountID?.uuidString
    }

    func hydrate() {
        guard let acct = accountID else { cache = [:]; loadedFor = nil; return }
        guard loadedFor != acct else { return }
        loadedFor = acct
        cache = [:]
        guard let raw = UserDefaults.standard.dictionary(forKey: storageKey(acct)) as? [String: [String: Any]] else { return }
        for (gid, e) in raw {
            if let g = Int(gid), let v = e["v"] as? Int64 ?? (e["v"] as? Int).map(Int64.init), let k = e["k"] as? String {
                cache[g] = (v, k)
            }
        }
    }

    func key(_ gid: Int) -> (ver: Int64, key: String)? {
        hydrate()
        return cache[gid]
    }

    /// Monotonic, with the design doc's equal-version repair rule.
    @discardableResult
    func put(_ gid: Int, ver: Int64, keyB64: String, replaceEqual: Bool = false) -> Bool {
        hydrate()
        guard let acct = accountID else { return false }
        if let cur = cache[gid], cur.ver > ver || (cur.ver == ver && (!replaceEqual || cur.key == keyB64)) { return false }
        cache[gid] = (ver, keyB64)
        let raw = cache.mapValues { ["v": $0.ver, "k": $0.key] as [String: Any] }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: raw.map { (String($0.key), $0.value) }), forKey: storageKey(acct))
        return true
    }
}
