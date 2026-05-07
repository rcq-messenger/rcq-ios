import CommonCrypto
import CryptoKit
import Foundation

/// Encryption helpers for the radio (Bluetooth + Wi-Fi-Direct)
/// chat surface. All keys are session-scoped — the chat is
/// ephemeral, nothing persists past disconnect.
///
/// Two patterns:
///
///   - **Room key**: derived from the room id. Open rooms use
///     `SHA256(room_id)` so anyone who sees the discovery row can
///     join; password-protected rooms use PBKDF2 with the room id
///     as salt so only callers who know the password can derive
///     the key. Same key encrypts every message in the room — no
///     Sender Keys yet (overkill for v1; revisit when groups grow
///     past 8).
///
///   - **1:1 ephemeral**: each side generates a fresh
///     Curve25519 key pair, exchanges public keys via the MC
///     invitation context (encrypted by Apple's TLS at that
///     hop), runs ECDH, derives a shared 256-bit AES key. No
///     pre-shared identity — same posture as Random Chat.
///
/// On top of the AES key we use AES-GCM with a per-message random
/// 12-byte nonce. CryptoKit's `AES.GCM.SealedBox` packs nonce +
/// ciphertext + tag together, which is exactly what gets sent on
/// the wire.
enum RadioCrypto {
    // MARK: - Room key derivation

    /// 256-bit room key. Open rooms: deterministic from the room
    /// id (anyone who sees the row can join). Password rooms:
    /// PBKDF2-SHA256 over the password with the room id as salt
    /// and 100k iterations — enough to make brute-force on a
    /// 6+ char password expensive without dragging the join
    /// flow past ~200ms on a real iPhone.
    static func roomKey(roomID: String, password: String?) -> SymmetricKey {
        let saltData = Data(roomID.utf8)
        if let pw = password, !pw.isEmpty {
            let derived = pbkdf2(password: pw, salt: saltData, iterations: 100_000, keyLength: 32)
            return SymmetricKey(data: derived)
        }
        let hash = SHA256.hash(data: saltData)
        return SymmetricKey(data: Data(hash))
    }

    // MARK: - 1:1 ephemeral session

    struct EphemeralKeys {
        let priv: Curve25519.KeyAgreement.PrivateKey
        let pub: Data  // raw 32-byte public key
    }

    static func makeEphemeralKeys() -> EphemeralKeys {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return EphemeralKeys(priv: priv, pub: priv.publicKey.rawRepresentation)
    }

    /// Run ECDH with our private key + their public, derive a
    /// 256-bit AES key via HKDF-SHA256 with a fixed RCQ-radio
    /// info string so an unrelated protocol pulling the same
    /// shared secret won't end up using the same AES key.
    static func deriveSessionKey(
        myPriv: Curve25519.KeyAgreement.PrivateKey,
        theirPub: Data,
    ) throws -> SymmetricKey {
        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPub)
        let shared = try myPriv.sharedSecretFromKeyAgreement(with: theirKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("rcq-radio-1to1".utf8),
            outputByteCount: 32,
        )
    }

    // MARK: - Symmetric AES-GCM

    /// Encrypt arbitrary bytes with the given symmetric key. Returns
    /// the AES-GCM combined representation (nonce + ciphertext +
    /// tag) ready to ship over the wire.
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw RadioCryptoError.sealFailed
        }
        return combined
    }

    static func open(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    enum RadioCryptoError: Error {
        case sealFailed
    }

    // MARK: - PBKDF2

    /// CommonCrypto-style PBKDF2-SHA256 wrapped to avoid pulling
    /// in the C header at every call site. Reasonable iteration
    /// count for an interactive join (~200ms on iPhone 12-class
    /// hardware). If the user wants us to move tougher, bump
    /// iterations here.
    private static func pbkdf2(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let pwBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        derived.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwBytes, pwBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                out.bindMemory(to: UInt8.self).baseAddress,
                keyLength,
            )
        }
        return derived
    }
}
