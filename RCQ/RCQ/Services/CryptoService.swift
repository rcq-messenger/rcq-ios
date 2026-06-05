import CryptoKit
import Foundation
import LibSignalClient

/// E2EE layer. v=1 is ECIES sealed-sender on CryptoKit (1:1 + group fan-out).
/// v=2 wraps a libsignal Double Ratchet session inside the same outer ECIES
/// tunnel. `decrypt(envelopeB64:)` dispatches on the wire `v` field.
protocol CryptoService {
    func bootstrapIdentity() throws -> RegistrationBundle
    func encrypt(envelope: Envelope, for recipient: PeerBundle) throws -> String
    /// Caller must establish the libsignal session via `ensureStage3Session(forPeerUIN:)` first.
    func encryptStage3(envelope: Envelope, for recipient: PeerBundle) throws -> String
    func decrypt(envelopeB64: String) throws -> DecryptedEnvelope

    /// ECIES-wraps a symmetric key for `recipient` so the server can hold
    /// the wrapped form. Used by the premium-content paywall flow.
    func wrapKey(_ keyB64: String, for recipient: PeerBundle) throws -> String
    func unwrapKey(_ wrappedB64: String) throws -> String
}

struct RegistrationBundle {
    let identityKey: String
    let signingKey: String
}

struct PeerBundle {
    let uin: Int
    let identityKey: String
    let signingKey: String
}

/// Plaintext shipped inside the encrypted envelope. Server never sees it.
enum Envelope: Codable, Hashable {
    case text(id: UUID, text: String, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case photo(id: UUID, mediaID: String, mediaKey: String, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil)
    case video(id: UUID, mediaID: String, mediaKey: String, thumbnailB64: String, durationSec: Double, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil)
    case voice(id: UUID, mediaID: String, mediaKey: String, durationSec: Double, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case file(id: UUID, mediaID: String, mediaKey: String, fileName: String, mime: String, sizeBytes: Int, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case location(id: UUID, lat: Double, lng: Double, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case deleteForEveryone(targetID: UUID)
    case systemNotice(id: UUID, text: String)
    case readReceipt(targetIDs: [UUID])
    case reaction(targetID: UUID, asset: String?)
    /// Recipient → blocked-sender; flips the sender's bubble to `.failed` without revealing the block.
    case bounce(targetID: UUID)
    /// Viewer → profile owner; tallied locally for the "Profile views: N" stat.
    case visit(at: Date)
    case edit(targetID: UUID, text: String)
    /// Paywalled photo. `mediaKey` is escrowed per-recipient via `/premium/contents`
    /// and only released after a paid unlock. `blurThumbnailB64` is the locked preview.
    /// Group poll announcement. The server-side `pollID` lets every
    /// recipient hit `/polls/{id}/vote` directly; the question +
    /// option labels travel here (encrypted lane), invisible to the
    /// server. `singleChoice` and `anonymous` are also surfaced so a
    /// client that loses connection to /polls can still render the
    /// bubble correctly.
    case poll(id: UUID, pollID: Int, question: String, options: [String], singleChoice: Bool, anonymous: Bool)
    /// Per-conversation screen-privacy toggle, propagated to the peer so BOTH
    /// clients blank THIS chat's screenshots/recording (Telegram-secret-chat
    /// style — you can't blank a screenshot on the peer's phone except by
    /// having their client enforce it). Latest value wins. Control only:
    /// renders no bubble. iOS-only for now; clients that don't know the kind
    /// ignore it.
    case secureScreen(on: Bool)
    /// Sent when the sender took a screenshot in a secure chat. The receiver
    /// renders "<sender> took a screenshot" (resolving the name + locale on
    /// their side). Control only.
    case screenshotTaken(id: UUID)

    private enum K: String, CodingKey {
        case kind, id, text, mediaID, mediaKey, caption, targetID, targetIDs, asset, thumbnailB64, durationSec, at, ttl, price
        case on
        case forwardedFromName = "fwdName"
        case replyTo = "reply"
        case albumID = "album"
        case fileName = "fname"
        case mime
        case sizeBytes = "size"
        case lat
        case lng
        case pollID = "poll"
        case question = "q"
        case options = "opts"
        case singleChoice = "sc"
        case anonymous = "anon"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .text(let id, let s, let ttl, let fwd, let reply):
            try c.encode("text", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(s, forKey: .text)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .photo(let id, let mediaID, let key, let caption, let ttl, let fwd, let reply, let album):
            try c.encode("photo", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
            try c.encodeIfPresent(album, forKey: .albumID)
        case .video(let id, let mediaID, let key, let thumb, let dur, let caption, let ttl, let fwd, let reply, let album):
            try c.encode("video", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encode(thumb, forKey: .thumbnailB64)
            try c.encode(dur, forKey: .durationSec)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
            try c.encodeIfPresent(album, forKey: .albumID)
        case .voice(let id, let mediaID, let key, let dur, let ttl, let fwd, let reply):
            try c.encode("voice", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encode(dur, forKey: .durationSec)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .file(let id, let mediaID, let key, let fname, let mime, let size, let caption, let ttl, let fwd, let reply):
            try c.encode("file", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encode(fname, forKey: .fileName)
            try c.encode(mime, forKey: .mime)
            try c.encode(size, forKey: .sizeBytes)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .location(let id, let lat, let lng, let caption, let ttl, let fwd, let reply):
            try c.encode("location", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(lat, forKey: .lat)
            try c.encode(lng, forKey: .lng)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .deleteForEveryone(let target):
            try c.encode("delete", forKey: .kind)
            try c.encode(target, forKey: .targetID)
        case .systemNotice(let id, let s):
            try c.encode("system", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(s, forKey: .text)
        case .readReceipt(let ids):
            try c.encode("read", forKey: .kind)
            try c.encode(ids, forKey: .targetIDs)
        case .reaction(let target, let asset):
            try c.encode("reaction", forKey: .kind)
            try c.encode(target, forKey: .targetID)
            try c.encodeIfPresent(asset, forKey: .asset)
        case .bounce(let target):
            try c.encode("bounce", forKey: .kind)
            try c.encode(target, forKey: .targetID)
        case .visit(let at):
            try c.encode("visit", forKey: .kind)
            try c.encode(at, forKey: .at)
        case .edit(let target, let s):
            try c.encode("edit", forKey: .kind)
            try c.encode(target, forKey: .targetID)
            try c.encode(s, forKey: .text)
        case .poll(let id, let pollID, let question, let options, let singleChoice, let anonymous):
            try c.encode("poll", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(pollID, forKey: .pollID)
            try c.encode(question, forKey: .question)
            try c.encode(options, forKey: .options)
            try c.encode(singleChoice, forKey: .singleChoice)
            try c.encode(anonymous, forKey: .anonymous)
        case .secureScreen(let on):
            try c.encode("secscreen", forKey: .kind)
            try c.encode(on, forKey: .on)
        case .screenshotTaken(let id):
            try c.encode("shot", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = .text(
                id: try c.decode(UUID.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
            )
        case "photo":
            self = .photo(
                id: try c.decode(UUID.self, forKey: .id),
                mediaID: try c.decode(String.self, forKey: .mediaID),
                mediaKey: try c.decode(String.self, forKey: .mediaKey),
                caption: try c.decodeIfPresent(String.self, forKey: .caption),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo),
                albumID: try c.decodeIfPresent(UUID.self, forKey: .albumID)
            )
        case "video":
            self = .video(
                id: try c.decode(UUID.self, forKey: .id),
                mediaID: try c.decode(String.self, forKey: .mediaID),
                mediaKey: try c.decode(String.self, forKey: .mediaKey),
                thumbnailB64: try c.decode(String.self, forKey: .thumbnailB64),
                durationSec: try c.decode(Double.self, forKey: .durationSec),
                caption: try c.decodeIfPresent(String.self, forKey: .caption),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo),
                albumID: try c.decodeIfPresent(UUID.self, forKey: .albumID)
            )
        case "voice":
            self = .voice(
                id: try c.decode(UUID.self, forKey: .id),
                mediaID: try c.decode(String.self, forKey: .mediaID),
                mediaKey: try c.decode(String.self, forKey: .mediaKey),
                durationSec: try c.decode(Double.self, forKey: .durationSec),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
            )
        case "file":
            self = .file(
                id: try c.decode(UUID.self, forKey: .id),
                mediaID: try c.decode(String.self, forKey: .mediaID),
                mediaKey: try c.decode(String.self, forKey: .mediaKey),
                fileName: try c.decode(String.self, forKey: .fileName),
                mime: try c.decode(String.self, forKey: .mime),
                sizeBytes: try c.decode(Int.self, forKey: .sizeBytes),
                caption: try c.decodeIfPresent(String.self, forKey: .caption),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
            )
        case "location":
            self = .location(
                id: try c.decode(UUID.self, forKey: .id),
                lat: try c.decode(Double.self, forKey: .lat),
                lng: try c.decode(Double.self, forKey: .lng),
                caption: try c.decodeIfPresent(String.self, forKey: .caption),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
            )
        case "delete":
            self = .deleteForEveryone(targetID: try c.decode(UUID.self, forKey: .targetID))
        case "system":
            self = .systemNotice(
                id: try c.decode(UUID.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text)
            )
        case "read":
            self = .readReceipt(targetIDs: try c.decode([UUID].self, forKey: .targetIDs))
        case "reaction":
            self = .reaction(
                targetID: try c.decode(UUID.self, forKey: .targetID),
                asset: try c.decodeIfPresent(String.self, forKey: .asset)
            )
        case "bounce":
            self = .bounce(targetID: try c.decode(UUID.self, forKey: .targetID))
        case "visit":
            self = .visit(at: try c.decode(Date.self, forKey: .at))
        case "edit":
            self = .edit(
                targetID: try c.decode(UUID.self, forKey: .targetID),
                text: try c.decode(String.self, forKey: .text)
            )
        case "poll":
            self = .poll(
                id: try c.decode(UUID.self, forKey: .id),
                pollID: try c.decode(Int.self, forKey: .pollID),
                question: try c.decode(String.self, forKey: .question),
                options: try c.decode([String].self, forKey: .options),
                singleChoice: try c.decode(Bool.self, forKey: .singleChoice),
                anonymous: try c.decode(Bool.self, forKey: .anonymous)
            )
        case "secscreen":
            self = .secureScreen(on: try c.decode(Bool.self, forKey: .on))
        case "shot":
            self = .screenshotTaken(id: try c.decode(UUID.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(kind)")
        }
    }
}

/// Reply quote shipped inline (id + snippet + nickname) so it renders even when
/// the original is missing from the recipient's history.
struct ReplyContext: Codable, Hashable {
    let id: UUID
    let snippet: String
    let authorName: String
}

struct DecryptedEnvelope {
    let senderUIN: Int
    let envelope: Envelope
}

enum CryptoError: Error, LocalizedError {
    case missingPrivateKey
    case unsupportedVersion(Int)
    case malformedWire
    case decryptFailed
    case signatureVerifyFailed
    case missingSenderInfo

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey:        return "no local identity key"
        case .unsupportedVersion(let v): return "unsupported envelope version v=\(v)"
        case .malformedWire:            return "malformed envelope"
        case .decryptFailed:            return "AEAD decrypt failed"
        case .signatureVerifyFailed:    return "sender signature did not verify"
        case .missingSenderInfo:        return "envelope missing sender info"
        }
    }
}

final class SignalCryptoService: CryptoService, @unchecked Sendable {
    private let ownUIN: Int
    private let identityPriv: Curve25519.KeyAgreement.PrivateKey
    private let signingPriv: Curve25519.Signing.PrivateKey
    private let signingPubB64: String

    private static let WIRE_VERSION_V1 = 1
    private static let WIRE_VERSION_V2 = 2

    private static let HKDF_INFO_V1 = Data("RCQ-1to1-v1".utf8)
    private static let HKDF_INFO_V2 = Data("RCQ-1to1-v2".utf8)

    init(ownUIN: Int,
         identityPriv: Curve25519.KeyAgreement.PrivateKey,
         signingPriv: Curve25519.Signing.PrivateKey) {
        self.ownUIN = ownUIN
        self.identityPriv = identityPriv
        self.signingPriv = signingPriv
        self.signingPubB64 = signingPriv.publicKey.rawRepresentation.base64EncodedString()
    }

    static func bootstrap() throws -> (RegistrationBundle, SignalCryptoService) {
        // Derive the identity from a fresh 32-byte recovery seed so the account
        // is restorable from its BIP39 phrase (Android parity). The seed is
        // persisted per-account below; `RecoveryPhrase` exports it as 24 words.
        return try bootstrap(fromSeed: RecoveryPhrase.newSeed())
    }

    /// Seed-derived identity bootstrap. Used by both fresh registration (random
    /// seed) and account recovery (seed decoded from the user's phrase). The
    /// seed + both private halves are written to the Keychain; the public
    /// halves go to `/auth/register` (or are matched by `/auth/recover`).
    static func bootstrap(fromSeed seed: Data) throws -> (RegistrationBundle, SignalCryptoService) {
        let keys = try RecoveryPhrase.deriveKeys(seed: seed)
        KeychainStore.set(KeychainStore.Keys.identityPriv, keys.identityPriv.rawRepresentation)
        KeychainStore.set(KeychainStore.Keys.signingPriv,  keys.signingPriv.rawRepresentation)
        KeychainStore.set(KeychainStore.Keys.recoverySeed, seed)
        let bundle = RegistrationBundle(
            identityKey: keys.identityPubB64,
            signingKey:  keys.signingPubB64
        )
        // ownUIN=0 placeholder; the service is rebuilt after `/auth/register`
        let svc = SignalCryptoService(ownUIN: 0, identityPriv: keys.identityPriv, signingPriv: keys.signingPriv)
        return (bundle, svc)
    }

    static func loadFromKeychain(ownUIN: Int) -> SignalCryptoService? {
        guard let idBytes = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let identity = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: idBytes),
              let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes)
        else { return nil }
        return SignalCryptoService(ownUIN: ownUIN, identityPriv: identity, signingPriv: signing)
    }

    func bootstrapIdentity() throws -> RegistrationBundle {
        // protocol-level fallback; real bootstrap goes through the static `bootstrap()`
        return RegistrationBundle(
            identityKey: identityPriv.publicKey.rawRepresentation.base64EncodedString(),
            signingKey:  signingPubB64
        )
    }

    // MARK: - encrypt

    func encrypt(envelope: Envelope, for recipient: PeerBundle) throws -> String {
        guard let recipientPubBytes = Data(base64Encoded: recipient.identityKey),
              let recipientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPubBytes)
        else { throw CryptoError.malformedWire }

        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPubBytes = ephemeralPriv.publicKey.rawRepresentation

        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPub)
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPubBytes + recipientPubBytes,
            sharedInfo: Self.HKDF_INFO_V1,
            outputByteCount: 32
        )

        let envelopeJSON = try JSONEncoder().encode(envelope)
        let toSign = ephemeralPubBytes + envelopeJSON
        let signature = try signingPriv.signature(for: toSign)

        // signature is over the JSONEncoder bytes, so ship them as-is (no re-serialisation)
        let plaintext = try JSONSerialization.data(withJSONObject: [
            "from": ownUIN,
            "spub": signingPubB64,
            "sig":  signature.base64EncodedString(),
            "env":  envelopeJSON.base64EncodedString(),
        ])

        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: aeadKey,
            authenticating: ephemeralPubBytes
        )

        let wire: [String: Any] = [
            "v":  Self.WIRE_VERSION_V1,
            "ek": ephemeralPubBytes.base64EncodedString(),
            "ct": sealed.combined.base64EncodedString(),
        ]
        let wireJSON = try JSONSerialization.data(withJSONObject: wire)
        return wireJSON.base64EncodedString()
    }

    // MARK: - encrypt (Stage 3, v=2)

    /// Caller must have established the libsignal session via `ensureStage3Session(forPeerUIN:)` first; sync method.
    func encryptStage3(envelope: Envelope, for recipient: PeerBundle) throws -> String {
        guard let recipientPubBytes = Data(base64Encoded: recipient.identityKey),
              let recipientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPubBytes)
        else { throw CryptoError.malformedWire }

        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        let recipientAddr = try ProtocolAddress(name: String(recipient.uin), deviceId: 1)
        let localAddr = try stores.localAddress()

        let envelopeJSON = try JSONEncoder().encode(envelope)
        let cipher = try signalEncrypt(
            message: envelopeJSON,
            for: recipientAddr,
            localAddress: localAddr,
            sessionStore: stores,
            identityStore: stores,
            context: ctx
        )
        let kindStr: String
        switch cipher.messageType {
        case .preKey: kindStr = "prekey"
        case .whisper: kindStr = "signal"
        default:
            throw CryptoError.malformedWire
        }
        let libsignalBytes = cipher.serialize()

        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPubBytes = ephemeralPriv.publicKey.rawRepresentation
        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPub)
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPubBytes + recipientPubBytes,
            sharedInfo: Self.HKDF_INFO_V2,
            outputByteCount: 32
        )
        let inner = try JSONSerialization.data(withJSONObject: [
            "from": ownUIN,
            "kind": kindStr,
            "msg":  libsignalBytes.base64EncodedString(),
        ])
        let sealed = try ChaChaPoly.seal(
            inner,
            using: aeadKey,
            authenticating: ephemeralPubBytes
        )
        let wire: [String: Any] = [
            "v":  Self.WIRE_VERSION_V2,
            "ek": ephemeralPubBytes.base64EncodedString(),
            "ct": sealed.combined.base64EncodedString(),
        ]
        let wireJSON = try JSONSerialization.data(withJSONObject: wire)
        return wireJSON.base64EncodedString()
    }

    // MARK: - key wrap (premium content)

    private static let HKDF_INFO_KEYWRAP = Data("RCQ-keywrap-v1".utf8)

    func wrapKey(_ keyB64: String, for recipient: PeerBundle) throws -> String {
        guard let keyBytes = Data(base64Encoded: keyB64), !keyBytes.isEmpty else {
            throw CryptoError.malformedWire
        }
        guard let recipientPubBytes = Data(base64Encoded: recipient.identityKey),
              let recipientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPubBytes)
        else { throw CryptoError.malformedWire }
        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPubBytes = ephemeralPriv.publicKey.rawRepresentation
        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPub)
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPubBytes + recipientPubBytes,
            sharedInfo: Self.HKDF_INFO_KEYWRAP,
            outputByteCount: 32
        )
        let sealed = try ChaChaPoly.seal(
            keyBytes,
            using: aeadKey,
            authenticating: ephemeralPubBytes
        )
        let wire: [String: Any] = [
            "v":  1,
            "ek": ephemeralPubBytes.base64EncodedString(),
            "ct": sealed.combined.base64EncodedString(),
        ]
        let wireJSON = try JSONSerialization.data(withJSONObject: wire)
        return wireJSON.base64EncodedString()
    }

    func unwrapKey(_ wrappedB64: String) throws -> String {
        guard let wireData = Data(base64Encoded: wrappedB64),
              let wire = try JSONSerialization.jsonObject(with: wireData) as? [String: Any],
              let ekB64 = wire["ek"] as? String,
              let ctB64 = wire["ct"] as? String,
              let ekBytes = Data(base64Encoded: ekB64),
              let ctBytes = Data(base64Encoded: ctB64),
              let ephemeralPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ekBytes)
        else { throw CryptoError.malformedWire }
        let shared = try identityPriv.sharedSecretFromKeyAgreement(with: ephemeralPub)
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ekBytes + identityPriv.publicKey.rawRepresentation,
            sharedInfo: Self.HKDF_INFO_KEYWRAP,
            outputByteCount: 32
        )
        let sealedBox = try ChaChaPoly.SealedBox(combined: ctBytes)
        let plain = try ChaChaPoly.open(sealedBox, using: aeadKey, authenticating: ekBytes)
        return plain.base64EncodedString()
    }

    // MARK: - decrypt (dispatches on wire version)

    func decrypt(envelopeB64: String) throws -> DecryptedEnvelope {
        guard let wireData = Data(base64Encoded: envelopeB64),
              let wire = try? JSONSerialization.jsonObject(with: wireData) as? [String: Any]
        else { throw CryptoError.malformedWire }
        let v = (wire["v"] as? Int) ?? 0
        switch v {
        case Self.WIRE_VERSION_V1: return try decryptV1(wire: wire)
        case Self.WIRE_VERSION_V2: return try decryptV2(wire: wire)
        default: throw CryptoError.unsupportedVersion(v)
        }
    }


    private func decryptV1(wire: [String: Any]) throws -> DecryptedEnvelope {
        guard let ekB64 = wire["ek"] as? String,
              let ctB64 = wire["ct"] as? String,
              let ekBytes = Data(base64Encoded: ekB64),
              let ctBytes = Data(base64Encoded: ctB64),
              let ephemeralPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ekBytes)
        else { throw CryptoError.malformedWire }
        let shared = try identityPriv.sharedSecretFromKeyAgreement(with: ephemeralPub)
        let recipientPubBytes = identityPriv.publicKey.rawRepresentation
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ekBytes + recipientPubBytes,
            sharedInfo: Self.HKDF_INFO_V1,
            outputByteCount: 32
        )
        let sealedBox: ChaChaPoly.SealedBox
        do { sealedBox = try ChaChaPoly.SealedBox(combined: ctBytes) }
        catch { throw CryptoError.malformedWire }
        let plaintext: Data
        do { plaintext = try ChaChaPoly.open(sealedBox, using: aeadKey, authenticating: ekBytes) }
        catch { throw CryptoError.decryptFailed }

        guard let inner = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let from = inner["from"] as? Int,
              let spubB64 = inner["spub"] as? String,
              let sigB64 = inner["sig"] as? String,
              let envB64 = inner["env"] as? String,
              let envBytes = Data(base64Encoded: envB64)
        else { throw CryptoError.missingSenderInfo }

        guard let spubBytes = Data(base64Encoded: spubB64),
              let spub = try? Curve25519.Signing.PublicKey(rawRepresentation: spubBytes),
              let sigBytes = Data(base64Encoded: sigB64)
        else { throw CryptoError.malformedWire }
        let toVerify = ekBytes + envBytes
        guard spub.isValidSignature(sigBytes, for: toVerify) else {
            throw CryptoError.signatureVerifyFailed
        }
        let env = try JSONDecoder().decode(Envelope.self, from: envBytes)
        return DecryptedEnvelope(senderUIN: from, envelope: env)
    }

    private func decryptV2(wire: [String: Any]) throws -> DecryptedEnvelope {
        guard let ekB64 = wire["ek"] as? String,
              let ctB64 = wire["ct"] as? String,
              let ekBytes = Data(base64Encoded: ekB64),
              let ctBytes = Data(base64Encoded: ctB64),
              let ephemeralPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ekBytes)
        else { throw CryptoError.malformedWire }
        let shared = try identityPriv.sharedSecretFromKeyAgreement(with: ephemeralPub)
        let recipientPubBytes = identityPriv.publicKey.rawRepresentation
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ekBytes + recipientPubBytes,
            sharedInfo: Self.HKDF_INFO_V2,
            outputByteCount: 32
        )
        let sealedBox: ChaChaPoly.SealedBox
        do { sealedBox = try ChaChaPoly.SealedBox(combined: ctBytes) }
        catch { throw CryptoError.malformedWire }
        let plaintext: Data
        do { plaintext = try ChaChaPoly.open(sealedBox, using: aeadKey, authenticating: ekBytes) }
        catch { throw CryptoError.decryptFailed }

        guard let inner = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let from = inner["from"] as? Int,
              let kind = inner["kind"] as? String,
              let msgB64 = inner["msg"] as? String,
              let msgBytes = Data(base64Encoded: msgB64)
        else { throw CryptoError.missingSenderInfo }

        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        let senderAddr = try ProtocolAddress(name: String(from), deviceId: 1)
        let localAddr = try stores.localAddress()

        let plainEnvelope: Data
        do {
            switch kind {
            case "prekey":
                let preMsg = try PreKeySignalMessage(bytes: msgBytes)
                plainEnvelope = try signalDecryptPreKey(
                    message: preMsg,
                    from: senderAddr,
                    localAddress: localAddr,
                    sessionStore: stores,
                    identityStore: stores,
                    preKeyStore: stores,
                    signedPreKeyStore: stores,
                    kyberPreKeyStore: stores,
                    context: ctx
                )
            case "signal":
                let sigMsg = try SignalMessage(bytes: msgBytes)
                plainEnvelope = try signalDecrypt(
                    message: sigMsg,
                    from: senderAddr,
                    to: localAddr,
                    sessionStore: stores,
                    identityStore: stores,
                    context: ctx
                )
            default:
                throw CryptoError.malformedWire
            }
        } catch let error as SignalProtocolStoreError {
            // unrecoverable session damage; drop the session so a fresh prekey can rebuild
            if case .missingSignedPreKey = error {
                stores.deleteSession(for: senderAddr)
            }
            throw error
        }
        let env = try JSONDecoder().decode(Envelope.self, from: plainEnvelope)
        return DecryptedEnvelope(senderUIN: from, envelope: env)
    }
}

