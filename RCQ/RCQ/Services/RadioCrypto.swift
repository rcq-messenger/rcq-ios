import CommonCrypto
import CryptoKit
import Foundation

/// Encryption for radio (Bluetooth + Wi-Fi-Direct) chat. Session-scoped
/// keys; nothing persists past disconnect.
///
/// Two patterns: room key (deterministic SHA256 of room id, or PBKDF2
/// over password salted with room id) and 1:1 ephemeral (Curve25519
/// ECDH after public-key exchange via MC invitation context). Both feed
/// AES-GCM with a per-message 12-byte nonce.
enum RadioCrypto {
    // MARK: - Room key derivation

    /// Open rooms: SHA256 of room id (anyone who sees the row joins).
    /// Password rooms: PBKDF2-SHA256, 100k iterations — ~200ms on iPhone 12.
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

    /// ECDH + HKDF-SHA256 with `rcq-radio-1to1` info string for domain
    /// separation against any other protocol using the same secret.
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

    /// Returns the AES-GCM combined representation (nonce + ciphertext + tag).
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
