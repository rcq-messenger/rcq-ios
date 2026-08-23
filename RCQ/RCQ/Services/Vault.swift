import CryptoKit
import Foundation

/// The vault, crypto half: opaque, versioned, client-sealed slots on the
/// island (spec §4.9). Byte-identical to the web's `src/lib/vault.ts` and
/// Android's `crypto/Vault.kt`, pinned by `Tools/VaultCheck` with a vector the
/// web produced.
///
/// Slot name and key both come from the account's long-term X25519 identity
/// private key, not from the recovery seed: a browser linked from a phone, a
/// legacy raw-key account and anyone who chose "forget the phrase" have no
/// seed, while every device of an account holds identity_priv. Same HKDF
/// shape as `RecoveryPhrase.hkdf` (HKDF-SHA256, no salt == 32 zero bytes, a
/// fixed info string), already proven identical across the three clients.
///
///     slot = hex( HKDF(identity_priv, zeros, "rcq.vault.slot.v1|" + name, 16) )
///     key  =      HKDF(identity_priv, zeros, "rcq.vault.key.v1|"  + slot, 32)
///     blob = 0x01 || nonce(12) || ChaCha20-Poly1305(key, nonce, padded,
///                                  aad = "rcq.vault.v1|" + slot + "|" + version)
///
/// The island sees a random-looking slot name rather than "contacts". The
/// version is in the AAD so the island cannot relabel one version as
/// another. `padded` is a 4-byte big-endian length, the plaintext, and zero
/// fill to the next 512-byte boundary: the island learns a size class.
enum Vault {
    static let contacts = "contacts"

    enum SealError: Error { case format, seal }

    private static let formatV1: UInt8 = 0x01
    private static let nonceLen = 12
    private static let block = 512

    static func slotId(identityPriv: Data, name: String) -> String {
        hkdf(identityPriv, "rcq.vault.slot.v1|\(name)", 16).map { String(format: "%02x", $0) }.joined()
    }

    static func slotKey(identityPriv: Data, slot: String) -> Data {
        hkdf(identityPriv, "rcq.vault.key.v1|\(slot)", 32)
    }

    private static func aad(_ slot: String, _ version: Int) -> Data {
        Data("rcq.vault.v1|\(slot)|\(version)".utf8)
    }

    /// Seal `plaintext` for `slot` as `version`. Raw blob bytes; the caller
    /// base64s them for the wire.
    static func seal(identityPriv: Data, slot: String, version: Int, plaintext: Data) throws -> Data {
        try seal(identityPriv: identityPriv, slot: slot, version: version, plaintext: plaintext, nonce: ChaChaPoly.Nonce())
    }

    static func seal(identityPriv: Data, slot: String, version: Int, plaintext: Data, nonce: ChaChaPoly.Nonce) throws -> Data {
        let key = SymmetricKey(data: slotKey(identityPriv: identityPriv, slot: slot))
        let box = try ChaChaPoly.seal(pad(plaintext), using: key, nonce: nonce, authenticating: aad(slot, version))
        var out = Data([formatV1])
        out.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// Open a blob the island served as `version`. Throws on any mismatch:
    /// wrong identity, wrong slot, wrong version, tampering.
    static func open(identityPriv: Data, slot: String, version: Int, blob: Data) throws -> Data {
        guard blob.count >= 1 + nonceLen + 16, blob[blob.startIndex] == formatV1 else { throw SealError.format }
        let nonce = try ChaChaPoly.Nonce(data: blob.subdata(in: 1..<(1 + nonceLen)))
        let body = blob.subdata(in: (1 + nonceLen)..<blob.count)
        let ct = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        let key = SymmetricKey(data: slotKey(identityPriv: identityPriv, slot: slot))
        let padded: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            padded = try ChaChaPoly.open(box, using: key, authenticating: aad(slot, version))
        } catch {
            throw SealError.seal
        }
        return try unpad(padded)
    }

    private static func pad(_ p: Data) -> Data {
        let total = max(block, ((4 + p.count + block - 1) / block) * block)
        var out = Data(count: total)
        let n = UInt32(p.count).bigEndian
        withUnsafeBytes(of: n) { out.replaceSubrange(0..<4, with: $0) }
        out.replaceSubrange(4..<(4 + p.count), with: p)
        return out
    }

    private static func unpad(_ b: Data) throws -> Data {
        guard b.count >= 4 else { throw SealError.format }
        let n = Int(UInt32(bigEndian: b.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard 4 + n <= b.count else { throw SealError.format }
        return b.subdata(in: 4..<(4 + n))
    }

    private static func hkdf(_ ikm: Data, _ info: String, _ len: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            info: Data(info.utf8),
            outputByteCount: len
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
