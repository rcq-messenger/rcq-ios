import CryptoKit
import Foundation
import LibSignalClient

/// End-to-end encryption layer for RCQ.
///
/// Three coexisting stages, all live in production simultaneously:
///
/// **Stage 1 (1:1, shipped):** ECIES sealed-sender on CryptoKit alone —
/// no Rust toolchain, no libsignal. X25519 ECDH + HKDF + ChaCha20-
/// Poly1305 + Ed25519. Wire `v=1`. Confidentiality + sender
/// authentication + sealed sender, no forward secrecy beyond the
/// per-message ephemeral.
///
/// **Stage 2 (groups, shipped):** same v=1 envelope, fanned out
/// per-recipient by `MessageService.sendGroupEnvelope`. Server sees
/// N opaque blobs, never the plaintext. O(N) sender CPU.
///
/// **Stage 3 (current — both shipped):** real libsignal session inside
/// our existing outer ECIES tunnel. The outer wrapper still hides
/// the sender from the network (server only sees a recipient and
/// opaque bytes); the inner libsignal session adds X3DH + PQXDH
/// session establishment, Double Ratchet forward secrecy, and post-
/// compromise security. Wire `v=2`. Group fan-out moves to libsignal
/// Sender Keys (single ciphertext for all members) once 3c lands —
/// until then groups stay on the v=1 fan-out path.
///
/// Why a hybrid (outer Stage-2 + inner libsignal) instead of pure
/// libsignal sealed-sender: libsignal's `SealedSenderEncrypt` requires
/// a `SenderCertificate` issued by the server, which in turn requires
/// the server to participate in libsignal's two-level cert proto
/// (Curve25519 + VXEdDSA) — heavy server-side machinery. Wrapping
/// libsignal in our existing ChaCha tunnel keeps the same network-
/// level anonymity guarantee with no added server crypto.
///
/// **Coexistence.** A v=2 sender checks the recipient's
/// `signal_identity_key` (surfaced by the backend on every contact /
/// user / group-member response). If non-null the sender rides v=2;
/// if null the recipient is still Stage 2-only and the sender falls
/// back to v=1. The recipient `decrypt(envelopeB64:)` dispatches on
/// the wire `v` field so both formats keep working through the
/// migration window.
///
/// **Wire format v=1** (Stage 1 + Stage 2):
/// ```json
/// {"v":1,"ek":"<ephemeral_x25519_pub_b64>","ct":"<chacha_combined_b64>"}
/// ```
/// inner plaintext (after outer ChaCha decrypt):
/// ```json
/// {"from":<uin>,"spub":"<ed25519_pub_b64>","sig":"<sig_b64>","env":"<envelope_json_bytes_b64>"}
/// ```
/// Ed25519 signature covers `ephemeral_pub || envelope_json_bytes`.
///
/// **Wire format v=2** (Stage 3):
/// ```json
/// {"v":2,"ek":"<ephemeral_x25519_pub_b64>","ct":"<chacha_combined_b64>"}
/// ```
/// inner plaintext:
/// ```json
/// {"from":<uin>,"kind":"prekey"|"signal","msg":"<libsignal_ciphertext_b64>"}
/// ```
/// `msg` is whatever `signalEncrypt` produced — a `PreKeySignalMessage`
/// (when no session exists yet, X3DH initiation embedded inside) or a
/// `SignalMessage` (Double Ratchet, post-X3DH). The outer ChaCha key
/// derivation differs from v=1 by the HKDF info string ("RCQ-1to1-v2"
/// vs "RCQ-1to1-v1") so a buggy implementation can't accidentally use
/// a v=2 plaintext as v=1 or vice versa.
///
/// **TOFU caveat.** `IdentityKeyStore.isTrustedIdentity` is trust-on-
/// first-use: the first remote identity ever observed for a peer is
/// trusted, later attempts to swap it succeed silently. A malicious
/// server can substitute identity keys at first contact and read
/// future messages. Out-of-band verification (safety numbers / QR
/// scans) is the standard mitigation; not yet implemented.
protocol CryptoService {
    func bootstrapIdentity() throws -> RegistrationBundle
    func encrypt(envelope: Envelope, for recipient: PeerBundle) throws -> String
    /// Stage 3 send: outer ECIES tunnel + inner libsignal session.
    /// Caller must have already established the libsignal session
    /// via `ensureStage3Session(forPeerUIN:)` — this method is sync
    /// and won't fetch a PreKeyBundle from the server itself.
    func encryptStage3(envelope: Envelope, for recipient: PeerBundle) throws -> String
    /// Dispatches on the outer `v` field. Handles both v=1 and v=2.
    func decrypt(envelopeB64: String) throws -> DecryptedEnvelope

    /// ECIES-wraps a small symmetric key (typically the 32-byte AES-256
    /// media key) for `recipient` so the server can hold the wrapped form
    /// without ever seeing K. Used by the premium-content flow:
    ///   • Sender wraps K with each recipient's identity public key
    ///     and uploads the wrapped forms to `/premium`.
    ///   • Server gates delivery of the wrapped K behind payment.
    ///   • Recipient receives the wrapped K on unlock, decrypts with
    ///     own identity private key (`unwrapKey`), then uses K to
    ///     decrypt the media blob fetched via the existing /media flow.
    /// HKDF info string differs from the regular envelope tunnels
    /// ("RCQ-keywrap-v1") so a wrapped key can't be replayed as an
    /// envelope ciphertext (or vice versa).
    func wrapKey(_ keyB64: String, for recipient: PeerBundle) throws -> String

    /// Inverse of `wrapKey`. Decrypts a wrapped key with our own
    /// identity private key and returns the recovered key as base64.
    func unwrapKey(_ wrappedB64: String) throws -> String
}

/// Material returned by a fresh identity bootstrap. Public halves go to the
/// server (`/auth/register`); the matching private keys are stashed in
/// `KeychainStore` and never leave the device.
struct RegistrationBundle {
    /// Base64 raw 32-byte X25519 ECDH public key.
    let identityKey: String
    /// Base64 raw 32-byte Ed25519 signing public key.
    let signingKey: String
}

/// Everything we need to send a message to one user. Pulled from a Contact
/// or freshly fetched via `/users/{uin}/info`.
struct PeerBundle {
    let uin: Int
    /// X25519 public key (base64).
    let identityKey: String
    /// Ed25519 public key (base64). Pass empty string for legacy / group
    /// fallback paths — those don't actually authenticate.
    let signingKey: String
}

/// Plaintext we want to ship inside the encrypted envelope. Whatever's in here is
/// the recipient's responsibility to interpret. The server never sees it.
///
/// Every content envelope (text/nudge/photo/system) carries its own message id —
/// the recipient persists the message under that same id, so a later
/// `deleteForEveryone(targetID:)` from the sender finds the row on both sides.
enum Envelope: Codable, Hashable {
    case text(id: UUID, text: String, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case photo(id: UUID, mediaID: String, mediaKey: String, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case video(id: UUID, mediaID: String, mediaKey: String, thumbnailB64: String, durationSec: Double, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case voice(id: UUID, mediaID: String, mediaKey: String, durationSec: Double, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case deleteForEveryone(targetID: UUID)
    case systemNotice(id: UUID, text: String)
    /// Recipient → sender: "I've seen these". Sender's bubble flips to read state.
    case readReceipt(targetIDs: [UUID])
    /// Either side: set or clear the local user's reaction on a message. `asset` nil
    /// means "remove my reaction".
    case reaction(targetID: UUID, asset: String?)
    /// Recipient → blocked-sender. The blocked person's outbound message arrived,
    /// we silently dropped it, and we tell their client to flip the bubble to
    /// `.failed`. Lets the sender see *something* failed without revealing why.
    case bounce(targetID: UUID)
    /// Viewer → target. Fired when somebody opens our profile. Carries only a
    /// sender-supplied timestamp; the recipient device tallies these locally
    /// to show the classic "Profile views: N" stat. Server stays oblivious —
    /// the visit lives inside the sealed-sender envelope like any other event.
    case visit(at: Date)
    /// Sender → recipient. Replace the body text of an already-delivered
    /// message (matched by `targetID`) with `text`. Recipient flips the
    /// row's text + marks it as edited so the UI can show the
    /// "(edited)" affordance. Edits are only allowed on text bubbles
    /// the sender authored — UI gates that, but ingest is permissive
    /// so an out-of-spec sender can't desync state by sending edits
    /// for media bubbles (recipient just no-ops if the row isn't text).
    case edit(targetID: UUID, text: String)
    /// Paywalled photo. Wire-format twin of `.photo` minus the
    /// `mediaKey` (the AES key for the media blob is escrowed
    /// per-recipient via `/premium/contents` and only handed back
    /// to the recipient after a paid `/premium/contents/{id}/unlock`).
    /// `blurThumbnailB64` is a small preview the receiver renders
    /// SwiftUI-blurred as the locked-state placeholder.
    case premiumPhoto(id: UUID, mediaID: String, price: Int, blurThumbnailB64: String, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    /// Paywalled video. Same model as `.premiumPhoto`; reuses the
    /// regular `.video` poster as the blur source.
    case premiumVideo(id: UUID, mediaID: String, price: Int, blurThumbnailB64: String, durationSec: Double, caption: String?, ttl: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)

    private enum K: String, CodingKey {
        case kind, id, text, mediaID, mediaKey, caption, targetID, targetIDs, asset, thumbnailB64, durationSec, at, ttl, price
        case forwardedFromName = "fwdName"
        case replyTo = "reply"
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
        case .photo(let id, let mediaID, let key, let caption, let ttl, let fwd, let reply):
            try c.encode("photo", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .video(let id, let mediaID, let key, let thumb, let dur, let caption, let ttl, let fwd, let reply):
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
        case .voice(let id, let mediaID, let key, let dur, let ttl, let fwd, let reply):
            try c.encode("voice", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encode(dur, forKey: .durationSec)
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
        case .premiumPhoto(let id, let mediaID, let price, let thumb, let caption, let ttl, let fwd, let reply):
            try c.encode("premium_photo", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(price, forKey: .price)
            try c.encode(thumb, forKey: .thumbnailB64)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .premiumVideo(let id, let mediaID, let price, let thumb, let dur, let caption, let ttl, let fwd, let reply):
            try c.encode("premium_video", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(price, forKey: .price)
            try c.encode(thumb, forKey: .thumbnailB64)
            try c.encode(dur, forKey: .durationSec)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
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
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
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
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
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
        case "premium_photo":
            self = .premiumPhoto(
                id: try c.decode(UUID.self, forKey: .id),
                mediaID: try c.decode(String.self, forKey: .mediaID),
                price: try c.decode(Int.self, forKey: .price),
                blurThumbnailB64: try c.decode(String.self, forKey: .thumbnailB64),
                caption: try c.decodeIfPresent(String.self, forKey: .caption),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
            )
        case "premium_video":
            self = .premiumVideo(
                id: try c.decode(UUID.self, forKey: .id),
                mediaID: try c.decode(String.self, forKey: .mediaID),
                price: try c.decode(Int.self, forKey: .price),
                blurThumbnailB64: try c.decode(String.self, forKey: .thumbnailB64),
                durationSec: try c.decode(Double.self, forKey: .durationSec),
                caption: try c.decodeIfPresent(String.self, forKey: .caption),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(kind)")
        }
    }
}

/// What a sender attaches to a reply so the recipient can render the
/// quote-block above the new bubble. We carry author + snippet
/// inline rather than just the targetID so the quote still displays
/// even if the original was deleted, the recipient never had it
/// (joined-mid-thread group), or both. Tap on the rendered quote
/// uses the id to scroll to the original when it's locally present.
/// Author is nickname-only for the same reason as forwarded —
/// nickname is enough to ground the reply in context, no UIN
/// propagation.
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

/// Production crypto. Uses CryptoKit's X25519 + ChaCha20-Poly1305 + Ed25519
/// directly. See the comment block on `CryptoService` for the protocol
/// diagram. The class is `@unchecked Sendable` because all keys are loaded
/// at init time and never mutated; CryptoKit primitives are themselves
/// thread-safe.
final class SignalCryptoService: CryptoService, @unchecked Sendable {
    private let ownUIN: Int
    private let identityPriv: Curve25519.KeyAgreement.PrivateKey
    private let signingPriv: Curve25519.Signing.PrivateKey
    private let signingPubB64: String

    /// Wire format versions. v=0 was the pre-libsignal base64 stub
    /// (refused outright now); v=1 is Stage 1+2 ECIES sealed-sender;
    /// v=2 is Stage 3 hybrid (outer ECIES + inner libsignal session).
    /// `decrypt(envelopeB64:)` dispatches on this field — anything
    /// outside {1, 2} throws `unsupportedVersion`.
    private static let WIRE_VERSION_V1 = 1
    private static let WIRE_VERSION_V2 = 2

    /// Domain-separation labels for the outer ECIES HKDF. Different
    /// info strings per wire version so a buggy implementation can't
    /// confuse a v=2 plaintext for a v=1 (or vice versa) at key
    /// derivation time.
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

    /// First-launch identity bootstrap. Generates the long-term X25519
    /// (ECDH) and Ed25519 (signing) keypairs, stashes both private halves
    /// in the Keychain, and returns the public halves so the caller can
    /// register them with the server.
    static func bootstrap() throws -> (RegistrationBundle, SignalCryptoService) {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        KeychainStore.set(KeychainStore.Keys.identityPriv, identity.rawRepresentation)
        KeychainStore.set(KeychainStore.Keys.signingPriv,  signing.rawRepresentation)
        let bundle = RegistrationBundle(
            identityKey: identity.publicKey.rawRepresentation.base64EncodedString(),
            signingKey:  signing.publicKey.rawRepresentation.base64EncodedString()
        )
        // `ownUIN: 0` is intentional — we don't have a UIN yet at bootstrap
        // time. The proper service is rebuilt after `/auth/register` returns.
        let svc = SignalCryptoService(ownUIN: 0, identityPriv: identity, signingPriv: signing)
        return (bundle, svc)
    }

    /// Load an existing identity from the Keychain. Used on every launch
    /// after the first registration. Returns nil if the keys aren't there
    /// (caller should re-bootstrap).
    static func loadFromKeychain(ownUIN: Int) -> SignalCryptoService? {
        guard let idBytes = KeychainStore.data(KeychainStore.Keys.identityPriv),
              let sigBytes = KeychainStore.data(KeychainStore.Keys.signingPriv),
              let identity = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: idBytes),
              let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigBytes)
        else { return nil }
        return SignalCryptoService(ownUIN: ownUIN, identityPriv: identity, signingPriv: signing)
    }

    func bootstrapIdentity() throws -> RegistrationBundle {
        // Bootstrap should be called via the static `bootstrap()` factory so
        // the keys persist to the Keychain. This method on the protocol is
        // a no-op fallback that just re-emits our public halves.
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

        // Per-message ephemeral keypair. Forward-secret at the message level:
        // each ciphertext binds to a fresh DH share that the sender doesn't
        // retain after dispatch.
        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPubBytes = ephemeralPriv.publicKey.rawRepresentation

        // ECDH → 32-byte shared secret → HKDF → AEAD key.
        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPub)
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPubBytes + recipientPubBytes,
            sharedInfo: Self.HKDF_INFO_V1,
            outputByteCount: 32
        )

        // Sign (ephemeral_pub || envelope_bytes). The signature lives inside
        // the ciphertext, not on the wire — keeps server-side anonymity.
        let envelopeJSON = try JSONEncoder().encode(envelope)
        let toSign = ephemeralPubBytes + envelopeJSON
        let signature = try signingPriv.signature(for: toSign)

        // Inner sealed plaintext: who I am, my signing pubkey (so the
        // recipient can verify without an extra server round-trip), the
        // signature, and the raw envelope bytes (base64). We DON'T parse
        // and re-serialise the envelope — Codable's JSONEncoder and
        // Foundation's JSONSerialization produce different byte layouts
        // for the same logical dict, and the signature is over those bytes.
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

        // Outer wire blob: version + ephemeral pub + sealed-box-combined.
        let wire: [String: Any] = [
            "v":  Self.WIRE_VERSION_V1,
            "ek": ephemeralPubBytes.base64EncodedString(),
            "ct": sealed.combined.base64EncodedString(),
        ]
        let wireJSON = try JSONSerialization.data(withJSONObject: wire)
        return wireJSON.base64EncodedString()
    }

    // MARK: - encrypt (Stage 3, v=2)

    /// Stage 3 hybrid send: outer ECIES tunnel hides the sender from the
    /// network, inner libsignal `signalEncrypt` provides Double Ratchet.
    /// Caller (`MessageService`) must have already established the
    /// libsignal session for `recipient.uin` via
    /// `ensureStage3Session(forPeerUIN:)` — we do NOT fetch a
    /// PreKeyBundle inline because this method is sync.
    func encryptStage3(envelope: Envelope, for recipient: PeerBundle) throws -> String {
        guard let recipientPubBytes = Data(base64Encoded: recipient.identityKey),
              let recipientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPubBytes)
        else { throw CryptoError.malformedWire }

        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared
        let recipientAddr = try ProtocolAddress(name: String(recipient.uin), deviceId: 1)
        let localAddr = try stores.localAddress()

        // Inner: serialise the envelope, hand to libsignal.
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
            // `signalEncrypt` should only ever return preKey or whisper
            // messageTypes for a 1:1 session. If we somehow get a
            // sender-key or plaintext type back, refuse rather than ship
            // an envelope the recipient can't decrypt.
            throw CryptoError.malformedWire
        }
        let libsignalBytes = cipher.serialize()

        // Outer: same ChaCha tunnel as v=1, just with v=2 HKDF info
        // and a different inner JSON schema.
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

    /// Domain-separation label for the premium-key-wrap HKDF — kept
    /// distinct from the v=1 / v=2 envelope tunnels so a wrapped key
    /// can't be replayed as an envelope ciphertext (or vice versa).
    private static let HKDF_INFO_KEYWRAP = Data("RCQ-keywrap-v1".utf8)

    func wrapKey(_ keyB64: String, for recipient: PeerBundle) throws -> String {
        guard let keyBytes = Data(base64Encoded: keyB64), !keyBytes.isEmpty else {
            throw CryptoError.malformedWire
        }
        guard let recipientPubBytes = Data(base64Encoded: recipient.identityKey),
              let recipientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPubBytes)
        else { throw CryptoError.malformedWire }
        // Per-wrap ephemeral keypair — same forward-secrecy property
        // as the regular envelope encrypt: each wrapped key binds to
        // a fresh DH share that the sender doesn't retain.
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
            // Permanent session damage — recipient lost a prekey or
            // a session row the sender's chain still references.
            // Drop our local session so the next inbound
            // PreKeySignalMessage from this peer can establish a
            // fresh chain instead of looping on the dead session
            // forever. The current message is unrecoverable.
            if case .missingSignedPreKey = error {
                stores.deleteSession(for: senderAddr)
            }
            throw error
        }
        let env = try JSONDecoder().decode(Envelope.self, from: plainEnvelope)
        return DecryptedEnvelope(senderUIN: from, envelope: env)
    }
}

