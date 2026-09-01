import CryptoKit
import Foundation
import LibSignalClient

// -----------------------------------------------------------
// Size-padding + message class (Stage 2 core-metadata plan).
//
// The one thing a sealed blob still leaks is its LENGTH: the outer wire is
// fixed-width apart from the inner sealed-sender JSON, so the deposited payload
// grows with the message. We hide that by padding the INNER plaintext (the bytes
// fed to the AEAD seal) up to a coarse size bucket before sealing, via a `_pad`
// filler field. The pad lives INSIDE the seal, so a wire observer that parses the
// outer JSON sees only the padded `ct`, and it is transparent to every shipped
// decoder: the v=1 signature is over `ek || env_bytes` (not the inner JSON), and
// every receiver (this app, its NSE, web, Android) reads the inner by named keys
// and ignores an unknown `_pad`. So a new client can pad a message an old client
// still opens byte-for-byte. Padding is a SENDER-ONLY policy: receivers never
// look at buckets, so clients may pad differently (or not at all) with no interop
// risk. The ladder is shared with web/Android only so an identically sized text
// lands on the same rung whatever composed it.
// -----------------------------------------------------------

/// Size buckets (bytes) the inner plaintext is padded up to. Past the last fixed
/// rung the ladder continues in multiples of 65536. Coarse on purpose: an
/// observer learns only which rung a message fell on.
let RCQ_PAD_BUCKETS: [Int] = [256, 1024, 4096, 16384, 65536]

/// The smallest bucket that holds `n` bytes.
func rcqBucketFor(_ n: Int) -> Int {
    for b in RCQ_PAD_BUCKETS where n <= b { return b }
    return ((n + 65535) / 65536) * 65536
}

/// The inner-JSON key the filler rides in. The filler is ASCII 'A', which JSON
/// never escapes, so the padded byte length is exact.
private let RCQ_PAD_KEY = "_pad"
/// Byte cost of an EMPTY pad field: `,"_pad":""` is exactly 10 ASCII bytes.
private let RCQ_PAD_OVERHEAD = 10

/// Kinds whose on-wire size tracks what the user wrote or attached, and so are
/// worth padding. Receipts / reactions / signalling are omitted: they are tiny,
/// frequent, and their size carries no content, so buying them uniformity is not
/// worth the relay bytes. Padding is sender-only, so this set is a local policy
/// choice and never part of the interop contract. Matches web's PAD_KINDS.
private let RCQ_PAD_KINDS: Set<String> = ["text", "photo", "video", "file", "location", "edit", "poll", "carbon"]
func rcqShouldPad(kind: String) -> Bool { RCQ_PAD_KINDS.contains(kind) }

/// Serialize the inner sealed-sender `fields` and, for a content `kind`, pad the
/// plaintext up to its size bucket with a trailing `_pad` filler. `_pad` adds
/// exactly `RCQ_PAD_OVERHEAD + k` bytes (the object already has other keys, so
/// the comma is always there and the ASCII 'A' filler never escapes), so the
/// serialized result lands on the bucket to the byte.
func rcqInnerPlaintext(_ fields: [String: Any], kind: String) throws -> Data {
    let unpadded = try JSONSerialization.data(withJSONObject: fields)
    guard rcqShouldPad(kind: kind) else { return unpadded }
    let target = rcqBucketFor(unpadded.count + RCQ_PAD_OVERHEAD)
    let k = target - unpadded.count - RCQ_PAD_OVERHEAD
    var padded = fields
    padded[RCQ_PAD_KEY] = String(repeating: "A", count: k)
    return try JSONSerialization.data(withJSONObject: padded)
}

/// Mirror of the island's `_cls_for`: the retention / push class the server
/// derives from this `envelope_type`. Sent beside `envelope_type` so a new or
/// opaque type is classified by its sender rather than guessed by the island;
/// for every type shipped today it equals what the island derives, so push and
/// retention behaviour is unchanged. 0 = ephemeral, 1 = content, 2 = critical.
private let RCQ_CLS_EPHEMERAL: Set<String> = ["typing", "read", "visit", "presence", "nudge", "bounce"]
private let RCQ_CLS_CRITICAL: Set<String> = ["skdm", "sknack"]
func rcqMessageClass(_ envelopeType: String) -> Int {
    if RCQ_CLS_EPHEMERAL.contains(envelopeType) { return 0 }
    if RCQ_CLS_CRITICAL.contains(envelopeType) { return 2 }
    return 1
}

/// E2EE layer. v=1 is ECIES sealed-sender on CryptoKit (1:1 + group fan-out).
/// v=2 wraps a libsignal Double Ratchet session inside the same outer ECIES
/// tunnel. `decrypt(envelopeB64:)` dispatches on the wire `v` field.
protocol CryptoService {
    func bootstrapIdentity() throws -> RegistrationBundle
    func encrypt(envelope: Envelope, for recipient: PeerBundle) throws -> String
    /// Cross-island group seal (§5c): override the inner `from` / `from_host`
    /// with the guest identity on the group's island.
    func encrypt(envelope: Envelope, for recipient: PeerBundle, fromUIN: Int, fromHost: String) throws -> String
    /// Seals to ONE device of `recipient`. A libsignal session belongs to a
    /// pair of devices, so a peer running two installs needs one call per
    /// install. Caller must establish that device's session via
    /// `ensureStage3Session(forPeerUIN:deviceId:)` first.
    func encryptStage3(envelope: Envelope, for recipient: PeerBundle, deviceId: UInt32) throws -> String
    func decrypt(envelopeB64: String) throws -> DecryptedEnvelope

    /// ECIES-wraps a symmetric key for `recipient` so the server can hold
    /// the wrapped form. Used by the premium-content paywall flow.
    func wrapKey(_ keyB64: String, for recipient: PeerBundle) throws -> String
    func unwrapKey(_ wrappedB64: String) throws -> String

    /// Sender-keys group encrypt-once: seal `envelope` under message key `mk`
    /// (signing with our long-term key, inside the AEAD) into the `gmsg` wire.
    /// Returns base64(JSON of the gmsg wire). See SenderKeys / sender-keys-design.md.
    func sealGmsg(envelope: Envelope, gid: Int, kid: String, epoch: Int, index: Int, mk: Data) throws -> String
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
///
/// ── `ttl` and `ts` ────────────────────────────────────────────────────────
/// `ttl` is the disappearing-message timer in whole SECONDS. `ts` is the
/// SENDER's clock at the moment the message was composed, in whole epoch
/// SECONDS, and it rides only beside a `ttl`. Same key and same units as the
/// `call` / `contactreq` / `profile` envelopes, and the same pair the web
/// writes (`web-chat/src/lib/crypto.ts`).
///
/// Without it a receiver can only start the countdown when the row lands on
/// its own disk. A phone that drained the queue a week late then kept a
/// "vanishes in 5 minutes" message for five minutes MORE, a week after its
/// author was told it was gone. This client already anchored on the island's
/// deposit time rather than on receipt, which is closer but still not what the
/// sender was promised, and it had nothing at all to hand the clients that
/// anchor on receipt.
///
/// A bare timestamp on every envelope would be new metadata inside the
/// ciphertext that buys nothing, so `ts` exists only where there is a
/// countdown to anchor. Additive on the wire: a decoder that does not know the
/// key ignores it, and an envelope without one falls back to today's anchor.
/// The half of a peer's key card another device needs to hold the same
/// cross-island contact without fetching anything of its own. Sent inside
/// `Envelope.ciAck`; see that case for why it travels rather than being looked
/// up again on each device.
struct CICard: Codable, Hashable {
    let nick: String?
    let ik: String
    let sk: String
    let sik: String?
    let gender: String?
    let status: String?
}

enum Envelope: Codable, Hashable {
    case text(id: UUID, text: String, ttl: Int? = nil, ts: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    /// `spoiler` = sent blurred, receiver taps to reveal (Android parity;
    /// wire key `"spoiler"`, omitted when false so old clients are unaffected).
    case photo(id: UUID, mediaID: String, mediaKey: String, caption: String?, ttl: Int? = nil, ts: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil, spoiler: Bool = false)
    case video(id: UUID, mediaID: String, mediaKey: String, thumbnailB64: String, durationSec: Double, caption: String?, ttl: Int? = nil, ts: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil, albumID: UUID? = nil, spoiler: Bool = false)
    case voice(id: UUID, mediaID: String, mediaKey: String, durationSec: Double, ttl: Int? = nil, ts: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case file(id: UUID, mediaID: String, mediaKey: String, fileName: String, mime: String, sizeBytes: Int, caption: String?, ttl: Int? = nil, ts: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case location(id: UUID, lat: Double, lng: Double, caption: String?, ttl: Int? = nil, ts: Int? = nil, forwardedFromName: String? = nil, replyTo: ReplyContext? = nil)
    case deleteForEveryone(targetID: UUID)
    case systemNotice(id: UUID, text: String)
    case readReceipt(targetIDs: [UUID])
    /// Receiver → sender: "these arrived on my device". Flips the sender's
    /// bubbles from `.sent` to `.delivered`.
    ///
    /// ⚠ The second tick used to be decided ONCE, by the island's answer to the
    /// send ("was a socket of theirs live at this instant"), and never caught
    /// up: everything written while the peer was offline kept one tick forever.
    /// The island cannot correct itself later — a deposit is unauthenticated and
    /// sealed, so it never learns who sent the row it is handing over. Only the
    /// recipient's own client knows, so only it can say.
    case deliveredReceipt(targetIDs: [UUID])
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
    /// Multi-device send-side sync. When the user sends a message from one
    /// device, that device also seals a `carbon` to the user's OWN identity
    /// (to_uin = me) wrapping the original envelope + its destination (exactly
    /// one of `to` / `gid`). The user's other devices unwrap it and file the
    /// inner message as fromMe in the destination thread; the origin device
    /// dedups its own carbon by the inner message's id. Defined identically on
    /// iOS/Android/web.
    indirect case carbon(to: Int?, gid: Int?, env: Envelope)
    /// Cross-device read marker (megalist A2). Rides INSIDE a `carbon` to my
    /// own uin: the thread is the carbon's own to/gid, `at` is the wall clock
    /// of the read in ms. My other devices drop that thread's badge, minus
    /// whatever arrived after `at`. The island never sees this kind (it is
    /// inside the sealed blob) and the carbon ships under an ephemeral outer
    /// type, so nothing new is learned and nothing pushes.
    case readMark(at: Int64)
    /// A cross-island request ANSWERED, told to my own other devices (wire
    /// "ciack"). Rides INSIDE a `carbon` under the same ephemeral outer type
    /// the read marker uses, so the island sees nothing it has not always seen.
    ///
    /// ⚠⚠ Why it exists: a cross-island request is per-INSTALL state. The
    /// conveyor row carries no device id, so every device of the account keeps
    /// its own copy, while accepting speaks only to the PEER. Accept on the
    /// desktop and the phone still shows the request - and accepting it there
    /// too is NOT idempotent: it re-fetches the key card and overwrites the
    /// pinned keys, on the one class of peer whose every message is encrypted
    /// to exactly those keys.
    ///
    /// `card` rides along on an accept so the other devices copy the TOFU the
    /// accepting device did instead of each doing their own.
    case ciAck(uin: Int, host: String, act: String, card: CICard?)
    /// Room state key hand-off (stage 6 phase 2, wire "gskey", outer "skdm").
    case gsKey(gid: Int, ver: Int64, key: String)
    /// Room state key ask-back (wire "gsknack", outer "sknack").
    case gsKnack(gid: Int)
    /// Profile key hand-off (wire "pkey", outer "skdm"). The AES-256-GCM key
    /// my avatar blob is sealed under, handed to ONE contact. The island used
    /// to hold this itself, in `users.avatar_media_key` beside the uin and the
    /// nickname, so a seized island opened every face it stored. Rides "skdm"
    /// because that token already exists: a NEW outer type would itself
    /// announce "this account just changed its picture".
    /// See docs/profile-key-design.md.
    case pkey(key: String)
    /// Profile key ask-back (wire "pkeyask", outer "sknack"). Only the OWNER
    /// can answer, unlike a room key where any member can.
    case pkeyAsk
    /// Cross-island call signaling (wire kind "call", spec §5d). Same-island
    /// calls ride the WS as plaintext call_* events; across islands there is
    /// no shared socket, so the SAME signal payload is wrapped here, v=1-sealed
    /// and deposited to the peer's island. `sig` = the WS event type verbatim
    /// (call_offer/call_answer/call_ice/call_end/call_renegotiate*), `cid` =
    /// the call id, `ts` = sender epoch SECONDS (receivers drop stale offers),
    /// `data` = the signal extras (sdp/candidate/media/reason — all strings).
    case callSignal(id: UUID, sig: String, cid: String, ts: Int, data: [String: String])
    /// §5f cross-island contact request (wire kind "contactreq"). Adding a peer
    /// on another island used to be a purely local act — a key-card fetch and a
    /// row on this device, with nothing deposited and the peer never told. This
    /// envelope IS the missing half: `act` is the direction
    /// (request/accept/decline), `ts` = sender epoch SECONDS, `nickname` = the
    /// sender's current display name (so the request renders before any card
    /// fetch), `note` = an optional short greeting. Sealed v=1 to the peer's
    /// identity key and deposited to their PRIMARY island, exactly like a call
    /// signal. Routes to the pending-request store, NEVER the message store.
    case contactRequest(id: UUID, act: String, ts: Int, nickname: String, note: String? = nil)
    /// §5e cross-island profile refresh (wire kind "profile"). A cross-island
    /// contact's name and picture were read exactly ONCE, off the open key card,
    /// when the contact was added — the same-island `contact_renamed` broadcast
    /// cannot reach a holder on another island because the island's `contacts`
    /// table has no host column, so that audience does not exist. This envelope
    /// is the push that replaces it: the person who changed their profile seals
    /// it to each accepted cross-island contact and deposits it to their island.
    ///
    /// `ts` = sender epoch SECONDS (receivers ignore an older one than the last
    /// applied). `avatarMediaID`/`avatarMediaKey` describe the picture; the
    /// encrypted blob itself is DEPOSITED to the recipient's island under the
    /// same id (§5b `PUT /media/{id}`), never pulled from ours at render time.
    /// The key travels only inside this sealed envelope — never on the open key
    /// card or the signed record, both of which are unauthenticated while
    /// `GET /media/{id}` has no auth at all, so the key IS the access decision.
    /// Display fields only: a `profile` never carries or writes identity keys.
    case profile(id: UUID, ts: Int, nickname: String, avatarMediaID: String? = nil, avatarMediaKey: String? = nil)
    /// Home-island record self-push (federation gossip B1, wire kind "homerec").
    /// Carries the SENDER's own signed home-island record so a contact caches
    /// where to reach them even after the sender's island dies. Verified against
    /// the sender's pinned signing key on receipt; never rendered. Cross-client
    /// identical (`{"kind":"homerec","rec":{v,ik,sk,homes,ts,sig}}`).
    case homeRecord(rec: IslandRecordWire)

    /// Sender-key distribution (wire kind "skdm"): hands one group member the
    /// chain key for a (kid, epoch) so they derive message keys for the
    /// encrypt-once `gmsg` broadcasts. Rides the per-member ECIES seal via
    /// /messages/group-sealed; never rendered. The receiver binds the kid to
    /// the decrypt's authenticated sender. See RCQ/docs/sender-keys-design.md.
    case skdm(gid: Int, kid: String, epoch: Int, index: Int, ck: String)
    /// Sender-key recovery request (wire kind "sknack"): I got a gmsg for a kid
    /// I don't hold; the kid's owner re-seals a fresh SKDM. Per-member sealed.
    case sknack(gid: Int, kid: String)

    /// In-chat bridge sharing (wire kind "relay_share"): a contact hands you a
    /// relay descriptor to AUGMENT your transport pool (censorship-resistance:
    /// distribute off-config relays peer-to-peer). Stored as a relay-kind chat
    /// message + rendered as an Add card; never auto-applied. Cross-client
    /// identical with Android. See RCQ/docs/bridge-sharing-design.md.
    case relayShare(id: UUID, relay: RelayShareWire, note: String? = nil)
    /// An envelope kind this build does not know. Produced by the decoder
    /// instead of throwing, so a newer client's addition costs nothing here.
    case unknown(kind: String)

    /// Wire form of a shared relay (the `relay` object inside a relay_share).
    /// Terse keys shared byte-for-byte with Android (ContactRelayStore.relayToJson).
    struct RelayShareWire: Codable, Hashable {
        let proto: String
        let server: String
        let port: Int
        let sni: String
        let uuid: String?
        let pbk: String?
        let sid: String?
        let flow: String?
        let pw: String?
        let obfs: String?
        let label: String?
    }

    /// Codable mirror of the signed home-island record (RcqFederation builds it
    /// as `[String: Any]`; this is the wire-typed form carried in an envelope).
    struct IslandRecordWire: Codable, Hashable {
        let v: Int
        let ik: String
        let sk: String
        let homes: [HomeWire]
        let ts: Int
        let sig: String
        struct HomeWire: Codable, Hashable { let host: String; let uin: Int }
    }

    private enum K: String, CodingKey {
        case kind, id, text, mediaID, mediaKey, caption, targetID, targetIDs, asset, thumbnailB64, durationSec, at, ttl, price, ver, key
        case on
        case to, gid, env
        case sig, cid, ts, data
        case rec
        case relay, note
        case act, nickname
        case avatarMediaID = "avatar_media_id"
        case avatarMediaKey = "avatar_media_key"
        case kid, e, i, ck
        case forwardedFromName = "fwdName"
        case replyTo = "reply"
        case albumID = "album"
        case spoiler
        case fileName = "fname"
        case mime
        case sizeBytes = "size"
        case lat
        case lng
        case uin, host, card
        case pollID = "poll"
        case question = "q"
        case options = "opts"
        case singleChoice = "sc"
        case anonymous = "anon"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .unknown(let kind):
            // Re-encoding one should never happen — nothing constructs it and
            // nothing forwards it — but the kind is preserved rather than
            // invented, so a round trip through this type cannot quietly turn
            // somebody else's envelope into ours.
            try c.encode(kind, forKey: .kind)
        case .text(let id, let s, let ttl, let ts, let fwd, let reply):
            try c.encode("text", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(s, forKey: .text)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            // Only beside a `ttl`, on every kind that can carry one. The seal
            // points fill a nil `ts` in `withSendTimestamp`, so an envelope
            // reaching the wire with a timer always has an anchor.
            if ttl != nil { try c.encodeIfPresent(ts, forKey: .ts) }
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .photo(let id, let mediaID, let key, let caption, let ttl, let ts, let fwd, let reply, let album, let spoiler):
            try c.encode("photo", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            if ttl != nil { try c.encodeIfPresent(ts, forKey: .ts) }
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
            try c.encodeIfPresent(album, forKey: .albumID)
            if spoiler { try c.encode(true, forKey: .spoiler) }
        case .video(let id, let mediaID, let key, let thumb, let dur, let caption, let ttl, let ts, let fwd, let reply, let album, let spoiler):
            try c.encode("video", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encode(thumb, forKey: .thumbnailB64)
            try c.encode(dur, forKey: .durationSec)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            if ttl != nil { try c.encodeIfPresent(ts, forKey: .ts) }
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
            try c.encodeIfPresent(album, forKey: .albumID)
            if spoiler { try c.encode(true, forKey: .spoiler) }
        case .voice(let id, let mediaID, let key, let dur, let ttl, let ts, let fwd, let reply):
            try c.encode("voice", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encode(dur, forKey: .durationSec)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            if ttl != nil { try c.encodeIfPresent(ts, forKey: .ts) }
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .file(let id, let mediaID, let key, let fname, let mime, let size, let caption, let ttl, let ts, let fwd, let reply):
            try c.encode("file", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(mediaID, forKey: .mediaID)
            try c.encode(key, forKey: .mediaKey)
            try c.encode(fname, forKey: .fileName)
            try c.encode(mime, forKey: .mime)
            try c.encode(size, forKey: .sizeBytes)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            if ttl != nil { try c.encodeIfPresent(ts, forKey: .ts) }
            try c.encodeIfPresent(fwd, forKey: .forwardedFromName)
            try c.encodeIfPresent(reply, forKey: .replyTo)
        case .location(let id, let lat, let lng, let caption, let ttl, let ts, let fwd, let reply):
            try c.encode("location", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(lat, forKey: .lat)
            try c.encode(lng, forKey: .lng)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(ttl, forKey: .ttl)
            if ttl != nil { try c.encodeIfPresent(ts, forKey: .ts) }
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
        case .deliveredReceipt(let ids):
            try c.encode("delivered", forKey: .kind)
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
        case .readMark(let at):
            try c.encode("readmark", forKey: .kind)
            try c.encode(at, forKey: .at)
        case .ciAck(let uin, let host, let act, let card):
            try c.encode("ciack", forKey: .kind)
            try c.encode(uin, forKey: .uin)
            try c.encode(host, forKey: .host)
            try c.encode(act, forKey: .act)
            if let card { try c.encode(card, forKey: .card) }
        case .gsKey(let gid, let ver, let key):
            try c.encode("gskey", forKey: .kind)
            try c.encode(gid, forKey: .gid)
            try c.encode(ver, forKey: .ver)
            try c.encode(key, forKey: .key)
        case .gsKnack(let gid):
            try c.encode("gsknack", forKey: .kind)
            try c.encode(gid, forKey: .gid)
        case .pkey(let key):
            try c.encode("pkey", forKey: .kind)
            try c.encode(key, forKey: .key)
        case .pkeyAsk:
            try c.encode("pkeyask", forKey: .kind)
        case .carbon(let to, let gid, let env):
            try c.encode("carbon", forKey: .kind)
            try c.encodeIfPresent(to, forKey: .to)
            try c.encodeIfPresent(gid, forKey: .gid)
            try c.encode(env, forKey: .env)
        case .callSignal(let id, let sig, let cid, let ts, let data):
            try c.encode("call", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(sig, forKey: .sig)
            try c.encode(cid, forKey: .cid)
            try c.encode(ts, forKey: .ts)
            try c.encode(data, forKey: .data)
        case .contactRequest(let id, let act, let ts, let nickname, let note):
            try c.encode("contactreq", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(ts, forKey: .ts)
            try c.encode(act, forKey: .act)
            try c.encode(nickname, forKey: .nickname)
            // Omitted when absent, like every other optional on this wire
            // (`relay_share.note` uses the same key the same way). The decoder
            // below is `decodeIfPresent`, so an explicit JSON `null` from
            // another client reads back as nil either way.
            try c.encodeIfPresent(note, forKey: .note)
        case .profile(let id, let ts, let nickname, let avatarID, let avatarKey):
            try c.encode("profile", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(ts, forKey: .ts)
            try c.encode(nickname, forKey: .nickname)
            // Optionals are OMITTED, not emitted as null — the convention the
            // §5f contactreq encoder settled on right above. The decoder is
            // `decodeIfPresent`, so another client's explicit null reads back as
            // nil either way.
            //
            // ⚠ The avatar pair is ALL-OR-NOTHING, enforced here rather than
            // trusted to callers. An id without its key names a blob nobody can
            // open (`GET /media/{id}` has no auth, so the key IS the access
            // decision), and web and Android both collapse a half pair to "no
            // picture" — which, under the snapshot rule, CLEARS the picture the
            // peer holds. Emitting half a pair would therefore delete our face
            // on the other two clients. Both or neither.
            if let aid = avatarID, let akey = avatarKey, !aid.isEmpty, !akey.isEmpty {
                try c.encode(aid, forKey: .avatarMediaID)
                try c.encode(akey, forKey: .avatarMediaKey)
            }
        case .homeRecord(let rec):
            try c.encode("homerec", forKey: .kind)
            try c.encode(rec, forKey: .rec)
        case .skdm(let gid, let kid, let epoch, let index, let ck):
            try c.encode("skdm", forKey: .kind)
            try c.encode(gid, forKey: .gid)
            try c.encode(kid, forKey: .kid)
            try c.encode(epoch, forKey: .e)
            try c.encode(index, forKey: .i)
            try c.encode(ck, forKey: .ck)
        case .sknack(let gid, let kid):
            try c.encode("sknack", forKey: .kind)
            try c.encode(gid, forKey: .gid)
            try c.encode(kid, forKey: .kid)
        case .relayShare(let id, let relay, let note):
            try c.encode("relay_share", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(relay, forKey: .relay)
            try c.encodeIfPresent(note, forKey: .note)
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
                ts: try c.decodeIfPresent(Int.self, forKey: .ts),
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
                ts: try c.decodeIfPresent(Int.self, forKey: .ts),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo),
                albumID: try c.decodeIfPresent(UUID.self, forKey: .albumID),
                spoiler: try c.decodeIfPresent(Bool.self, forKey: .spoiler) ?? false
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
                ts: try c.decodeIfPresent(Int.self, forKey: .ts),
                forwardedFromName: try c.decodeIfPresent(String.self, forKey: .forwardedFromName),
                replyTo: try c.decodeIfPresent(ReplyContext.self, forKey: .replyTo),
                albumID: try c.decodeIfPresent(UUID.self, forKey: .albumID),
                spoiler: try c.decodeIfPresent(Bool.self, forKey: .spoiler) ?? false
            )
        case "voice":
            self = .voice(
                id: try c.decode(UUID.self, forKey: .id),
                mediaID: try c.decode(String.self, forKey: .mediaID),
                mediaKey: try c.decode(String.self, forKey: .mediaKey),
                durationSec: try c.decode(Double.self, forKey: .durationSec),
                ttl: try c.decodeIfPresent(Int.self, forKey: .ttl),
                ts: try c.decodeIfPresent(Int.self, forKey: .ts),
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
                ts: try c.decodeIfPresent(Int.self, forKey: .ts),
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
                ts: try c.decodeIfPresent(Int.self, forKey: .ts),
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
        case "delivered":
            self = .deliveredReceipt(targetIDs: try c.decode([UUID].self, forKey: .targetIDs))
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
        case "readmark":
            self = .readMark(at: try c.decode(Int64.self, forKey: .at))
        case "ciack":
            self = .ciAck(
                uin: try c.decode(Int.self, forKey: .uin),
                host: try c.decode(String.self, forKey: .host),
                act: try c.decode(String.self, forKey: .act),
                card: try c.decodeIfPresent(CICard.self, forKey: .card)
            )
        case "gskey":
            self = .gsKey(
                gid: try c.decode(Int.self, forKey: .gid),
                ver: try c.decode(Int64.self, forKey: .ver),
                key: try c.decode(String.self, forKey: .key)
            )
        case "gsknack":
            self = .gsKnack(gid: try c.decode(Int.self, forKey: .gid))
        case "pkey":
            self = .pkey(key: try c.decode(String.self, forKey: .key))
        case "pkeyask":
            self = .pkeyAsk
        case "carbon":
            self = .carbon(
                to: try c.decodeIfPresent(Int.self, forKey: .to),
                gid: try c.decodeIfPresent(Int.self, forKey: .gid),
                env: try c.decode(Envelope.self, forKey: .env)
            )
        case "call":
            self = .callSignal(
                id: try c.decode(UUID.self, forKey: .id),
                sig: try c.decode(String.self, forKey: .sig),
                cid: try c.decode(String.self, forKey: .cid),
                ts: try c.decode(Int.self, forKey: .ts),
                data: try c.decodeIfPresent([String: String].self, forKey: .data) ?? [:]
            )
        case "contactreq":
            self = .contactRequest(
                id: try c.decode(UUID.self, forKey: .id),
                act: try c.decode(String.self, forKey: .act),
                ts: try c.decode(Int.self, forKey: .ts),
                nickname: try c.decodeIfPresent(String.self, forKey: .nickname) ?? "",
                note: try c.decodeIfPresent(String.self, forKey: .note)
            )
        case "profile":
            self = .profile(
                id: try c.decode(UUID.self, forKey: .id),
                ts: try c.decode(Int.self, forKey: .ts),
                nickname: try c.decodeIfPresent(String.self, forKey: .nickname) ?? "",
                avatarMediaID: try c.decodeIfPresent(String.self, forKey: .avatarMediaID),
                avatarMediaKey: try c.decodeIfPresent(String.self, forKey: .avatarMediaKey)
            )
        case "homerec":
            self = .homeRecord(rec: try c.decode(IslandRecordWire.self, forKey: .rec))
        case "skdm":
            self = .skdm(
                gid: try c.decode(Int.self, forKey: .gid),
                kid: try c.decode(String.self, forKey: .kid),
                epoch: try c.decode(Int.self, forKey: .e),
                index: try c.decode(Int.self, forKey: .i),
                ck: try c.decode(String.self, forKey: .ck)
            )
        case "sknack":
            self = .sknack(
                gid: try c.decode(Int.self, forKey: .gid),
                kid: try c.decode(String.self, forKey: .kid)
            )
        case "relay_share":
            self = .relayShare(
                id: try c.decode(UUID.self, forKey: .id),
                relay: try c.decode(RelayShareWire.self, forKey: .relay),
                note: try c.decodeIfPresent(String.self, forKey: .note)
            )
        default:
            // ⚠⚠ NEVER throw here. This is the one place a wire addition from a
            // newer client lands, and a throw makes every such addition a
            // landmine: the row fails to decode, and whether that costs one
            // message or a whole queue drain depends on which caller happens to
            // be holding it. Android has always answered `Unknown(kind)` and the
            // web returns null; iOS was the odd one out, and it is the client
            // that most needs to survive an envelope it has never heard of,
            // because it is the one that ships slowest.
            //
            // Decoded and then ignored: nothing downstream matches `.unknown`,
            // so it is dropped exactly where an unrecognised envelope should be
            // dropped — after it has been safely read off the wire.
            self = .unknown(kind: kind)
        }
    }

    /// The inner `kind` string this envelope encodes to (mirrors `encode(to:)`).
    /// The Stage 2 padding policy reads it to decide whether to pad on send.
    /// Exhaustive on purpose: a new case must teach this map, not fall through.
    var wireKind: String {
        switch self {
        case .unknown(let kind): return kind
        case .text: return "text"
        case .photo: return "photo"
        case .video: return "video"
        case .voice: return "voice"
        case .file: return "file"
        case .location: return "location"
        case .deleteForEveryone: return "delete"
        case .systemNotice: return "system"
        case .readReceipt: return "read"
        case .deliveredReceipt: return "delivered"
        case .reaction: return "reaction"
        case .bounce: return "bounce"
        case .visit: return "visit"
        case .edit: return "edit"
        case .poll: return "poll"
        case .secureScreen: return "secscreen"
        case .screenshotTaken: return "shot"
        case .carbon: return "carbon"
        case .readMark: return "readmark"
        case .ciAck: return "ciack"
        case .gsKey: return "gskey"
        case .gsKnack: return "gsknack"
        case .pkey: return "pkey"
        case .pkeyAsk: return "pkeyask"
        case .callSignal: return "call"
        case .contactRequest: return "contactreq"
        case .profile: return "profile"
        case .homeRecord: return "homerec"
        case .skdm: return "skdm"
        case .sknack: return "sknack"
        case .relayShare: return "relay_share"
        }
    }

    /// Stamp the sender's clock onto an outgoing envelope that carries a `ttl`.
    ///
    /// Applied at the three seal points (v=1, v=2, group sender-key), which is
    /// every path a plaintext envelope takes to the wire, so no send site can
    /// forget the anchor and none has to remember it. Deliberately NOT done
    /// inside `encode(to:)`: `PushDecryptCache` re-encodes an already-received
    /// envelope to store it, and a clock read in the encoder would overwrite a
    /// peer's timestamp with our own.
    ///
    /// Only ever FILLS a nil. `resend` knows the compose time of a message that
    /// failed hours ago and passes it explicitly; a retry must not hand the peer
    /// a lifetime the sender's own copy will not get.
    ///
    /// A carbon has no timer of its own but wraps the envelope that does, so it
    /// recurses. Everything else is returned untouched.
    func withSendTimestamp(at now: Date = Date()) -> Envelope {
        let stamp = Int(now.timeIntervalSince1970)
        switch self {
        case .text(let id, let s, let ttl, let ts, let fwd, let reply):
            guard ttl != nil, ts == nil else { return self }
            return .text(id: id, text: s, ttl: ttl, ts: stamp, forwardedFromName: fwd, replyTo: reply)
        case .photo(let id, let mediaID, let key, let caption, let ttl, let ts, let fwd, let reply, let album, let spoiler):
            guard ttl != nil, ts == nil else { return self }
            return .photo(id: id, mediaID: mediaID, mediaKey: key, caption: caption, ttl: ttl, ts: stamp,
                          forwardedFromName: fwd, replyTo: reply, albumID: album, spoiler: spoiler)
        case .video(let id, let mediaID, let key, let thumb, let dur, let caption, let ttl, let ts, let fwd, let reply, let album, let spoiler):
            guard ttl != nil, ts == nil else { return self }
            return .video(id: id, mediaID: mediaID, mediaKey: key, thumbnailB64: thumb, durationSec: dur,
                          caption: caption, ttl: ttl, ts: stamp, forwardedFromName: fwd, replyTo: reply,
                          albumID: album, spoiler: spoiler)
        case .voice(let id, let mediaID, let key, let dur, let ttl, let ts, let fwd, let reply):
            guard ttl != nil, ts == nil else { return self }
            return .voice(id: id, mediaID: mediaID, mediaKey: key, durationSec: dur, ttl: ttl, ts: stamp,
                          forwardedFromName: fwd, replyTo: reply)
        case .file(let id, let mediaID, let key, let fname, let mime, let size, let caption, let ttl, let ts, let fwd, let reply):
            guard ttl != nil, ts == nil else { return self }
            return .file(id: id, mediaID: mediaID, mediaKey: key, fileName: fname, mime: mime, sizeBytes: size,
                         caption: caption, ttl: ttl, ts: stamp, forwardedFromName: fwd, replyTo: reply)
        case .location(let id, let lat, let lng, let caption, let ttl, let ts, let fwd, let reply):
            guard ttl != nil, ts == nil else { return self }
            return .location(id: id, lat: lat, lng: lng, caption: caption, ttl: ttl, ts: stamp,
                             forwardedFromName: fwd, replyTo: reply)
        case .carbon(let to, let gid, let env):
            return .carbon(to: to, gid: gid, env: env.withSendTimestamp(at: now))
        default:
            return self
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
    /// The sender's island host if they included it (v=1 `from_host`); nil for
    /// pre-`from_host` senders and all v=2 (same-island). Drives Variant A.
    var senderHost: String? = nil
    /// Base64 Ed25519 key (`spub`) that signed this envelope — proven by the
    /// signature check. Lets a `homerec` self-push bind the carried record to
    /// its real sender (rec.sk must equal this). nil for v=2.
    var senderSigningKey: String? = nil
    /// Which install of the sender sealed this (the v=2 ratchet address names
    /// it). nil for v=1 and group chains, which name no device — and the
    /// silence probe treats that nil as "clears nothing": crediting the
    /// primary for a copy that may have come from a sibling is exactly the
    /// confusion that kept a dead device unhealed on the web.
    var senderDeviceID: Int? = nil
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
    // Internal: QRSheet embeds it as the advisory `k=` pinning key (spec §5).
    let signingPubB64: String

    private static let WIRE_VERSION_V1 = 1
    private static let WIRE_VERSION_V2 = 2

    private static let HKDF_INFO_V1 = Data("RCQ-1to1-v1".utf8)
    private static let HKDF_INFO_V2 = Data("RCQ-1to1-v2".utf8)
    private static let HKDF_INFO_WEBLINK = Data("RCQ-weblink-v1".utf8)

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

    /// Cross-island group send (§5c): seal AS the guest identity — the `from`
    /// and `from_host` inside the envelope must be the sender's per-island uin
    /// and the group's island, so members local to that island see
    /// `from_host == their own island` (no Variant-A quarantine). The KEYS are
    /// the same on every island, so the signature verifies identically.
    func encrypt(envelope: Envelope, for recipient: PeerBundle, fromUIN: Int, fromHost: String) throws -> String {
        try encryptV1(envelope: envelope, for: recipient, overrideFrom: fromUIN, overrideHost: fromHost)
    }

    func encrypt(envelope: Envelope, for recipient: PeerBundle) throws -> String {
        try encryptV1(envelope: envelope, for: recipient, overrideFrom: nil, overrideHost: nil)
    }

    private func encryptV1(envelope: Envelope, for recipient: PeerBundle, overrideFrom: Int?, overrideHost: String?) throws -> String {
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

        let envelopeJSON = try JSONEncoder().encode(envelope.withSendTimestamp())
        let toSign = ephemeralPubBytes + envelopeJSON
        let signature = try signingPriv.signature(for: toSign)

        // `from_host` (the sender's island) lets the recipient tell a cross-island
        // sender from a local one (Variant A consent + correct labeling). Additive:
        // old decoders ignore it; the authenticated identity stays `spub`. Read
        // the host from the AccountManager-mirrored `rcq.baseURL` (NSE-safe:
        // UserDefaults.standard, no app-only deps — encrypt only runs in the app).
        let fromHost: String = overrideHost ?? {
            if let url = UserDefaults.standard.string(forKey: "rcq.baseURL"),
               let h = URL(string: url)?.host { return h }
            return "api.rcq.app"
        }()
        // signature is over the JSONEncoder bytes, so ship them as-is (no re-serialisation).
        // Stage 2: pad the inner plaintext up to a size bucket for content kinds, so
        // the sealed blob's length no longer tracks the message. Transparent to every
        // decoder (this app's own decryptV1, the NSE, web, Android): the sig is over
        // ek||env, not the inner, and receivers ignore the extra `_pad` key.
        let plaintext = try rcqInnerPlaintext([
            "from": overrideFrom ?? ownUIN,
            "from_host": fromHost,
            "spub": signingPubB64,
            "sig":  signature.base64EncodedString(),
            "env":  envelopeJSON.base64EncodedString(),
        ], kind: envelope.wireKind)

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

    // MARK: - sender keys (group encrypt-once)

    func sealGmsg(envelope: Envelope, gid: Int, kid: String, epoch: Int, index: Int, mk: Data) throws -> String {
        let envBytes = try JSONEncoder().encode(envelope.withSendTimestamp())
        let aad = SenderKeys.gmsgAAD(gid: gid, kid: kid, epoch: epoch, index: index)
        let sig = try signingPriv.signature(for: aad + envBytes)
        let plaintext = try JSONSerialization.data(withJSONObject: [
            "env": envBytes.base64EncodedString(),
            "sig": sig.base64EncodedString(),
        ])
        // The gmsg wire keeps the nonce SEPARATE (`n`) and ct = ciphertext||tag
        // (NOT CryptoKit's combined nonce||ct||tag) to match web/Android.
        let nonce = ChaChaPoly.Nonce()
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: mk), nonce: nonce, authenticating: aad)
        let wire: [String: Any] = [
            "v": 1,
            "kid": kid,
            "e": epoch,
            "i": index,
            "n": Data(nonce).base64EncodedString(),
            "ct": (box.ciphertext + box.tag).base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: wire).base64EncodedString()
    }

    /// Seal [plaintext] to a web client's ephemeral Curve25519 pubkey for the
    /// connect-to-web QR login. Same ECIES as `encrypt` (ephemeral Curve25519 →
    /// HKDF-SHA256(salt = ephPub + recipientPub, info "RCQ-weblink-v1") →
    /// ChaChaPoly, AAD = ephPub) but WITHOUT the inner envelope + signature —
    /// it carries a raw blob (the account LinkBlob JSON). Wire = base64(JSON
    /// {ek, ct}) with ct = CryptoKit combined (nonce(12) || ct || tag). The
    /// web's `openLinkSeal` and Android's `sealForWebLink` mirror this exactly.
    static func sealForWebLink(_ plaintext: Data, recipientWebPub: Data) throws -> String {
        guard let recipientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientWebPub)
        else { throw CryptoError.malformedWire }
        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPubBytes = ephemeralPriv.publicKey.rawRepresentation
        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPub)
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPubBytes + recipientWebPub,
            sharedInfo: Self.HKDF_INFO_WEBLINK,
            outputByteCount: 32
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: aeadKey, authenticating: ephemeralPubBytes)
        let wire: [String: Any] = [
            "ek": ephemeralPubBytes.base64EncodedString(),
            "ct": sealed.combined.base64EncodedString(),
        ]
        let wireJSON = try JSONSerialization.data(withJSONObject: wire)
        return wireJSON.base64EncodedString()
    }

    // MARK: - encrypt (Stage 3, v=2)

    /// Caller must have established the libsignal session via `ensureStage3Session(forPeerUIN:deviceId:)` first; sync method.
    func encryptStage3(envelope: Envelope, for recipient: PeerBundle, deviceId: UInt32) throws -> String {
        let stores = SignalProtocolStores.shared
        let ctx = RCQStoreContext.shared

        // The OUTER layer goes to the key of the DEVICE, which is the account
        // identity key for the primary and the install's own for a secondary.
        // Sealing to the account key regardless would hand a secondary a copy
        // it cannot open — indistinguishable, from the outside, from the loss
        // this fan-out exists to stop. So an unknown key is a device we skip,
        // never one we guess at.
        let recipientPubBytes: Data
        if deviceId == 1 {
            guard let accountKey = Data(base64Encoded: recipient.identityKey)
            else { throw CryptoError.malformedWire }
            recipientPubBytes = accountKey
        } else {
            guard let deviceKey = stores.peerDeviceOuterKey(forPeerUIN: recipient.uin, deviceId: deviceId)
            else { throw CryptoError.malformedWire }
            recipientPubBytes = deviceKey
        }
        guard let recipientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPubBytes)
        else { throw CryptoError.malformedWire }

        let recipientAddr = try ProtocolAddress(name: String(recipient.uin), deviceId: deviceId)
        let localAddr = try stores.localAddress()

        let envelopeJSON = try JSONEncoder().encode(envelope.withSendTimestamp())
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
        var innerFields: [String: Any] = [
            "from": ownUIN,
            "kind": kindStr,
            "msg":  libsignalBytes.base64EncodedString(),
        ]
        // Which of OUR devices sealed this, so the receiver addresses the
        // session as (from, dev). Omitted at 1: every build in the field
        // predates the key and reads a missing one as 1.
        let myDeviceId = stores.localDeviceId
        if myDeviceId != 1 { innerFields["dev"] = myDeviceId }
        // Stage 2: pad the inner plaintext to a size bucket for content kinds (same
        // scheme + buckets as v=1). The libsignal ct inside `msg` hides the message
        // but not its LENGTH; `_pad` lands the sealed blob on a bucket. Transparent
        // to old receivers, which read the inner by named keys and ignore `_pad`.
        let inner = try rcqInnerPlaintext(innerFields, kind: envelope.wireKind)
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
        let fromHost = inner["from_host"] as? String
        return DecryptedEnvelope(senderUIN: from, senderHost: fromHost, senderSigningKey: spubB64, envelope: env)
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
        // Absent `dev` = a sender from before per-device sessions, which
        // could only ever have been device 1. The range check is not
        // decoration: this value is attacker-chosen, and a negative one
        // would trap on the UInt32 conversion below.
        let senderDeviceId = (inner["dev"] as? Int) ?? 1
        guard (1...127).contains(senderDeviceId) else { throw CryptoError.malformedWire }
        let senderAddr = try ProtocolAddress(name: String(from), deviceId: UInt32(senderDeviceId))
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
        return DecryptedEnvelope(senderUIN: from, senderDeviceID: senderDeviceId, envelope: env)
    }
}


/// RCQ Sender Keys (custom v=1) — group encrypt-once primitives. Byte-for-byte
/// compatible with web (sender-keys.ts) + Android (SenderKeys.kt): same
/// HMAC-SHA256 ratchet, ChaCha20-Poly1305 framing, AAD string, gmsg JSON, and
/// Ed25519 signature. `openGmsg` is keyless (just mk + spub); `sealGmsg` needs
/// the signing key and lives on SignalCryptoService. Spec: sender-keys-design.md.
enum SenderKeys {
    static let MAX_SKIP = 512

    // mk_i = HMAC-SHA256(ck_i, 0x01); ck_{i+1} = HMAC-SHA256(ck_i, 0x02).
    static func deriveMessageKey(_ chainKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: SymmetricKey(data: chainKey)))
    }
    static func nextChainKey(_ chainKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: SymmetricKey(data: chainKey)))
    }

    static func gmsgAAD(gid: Int, kid: String, epoch: Int, index: Int) -> Data {
        Data("rcq.gmsg.v1|\(gid)|\(kid)|\(epoch)|\(index)".utf8)
    }

    struct GmsgHeader { let kid: String; let epoch: Int; let index: Int }

    /// Peek the routing header of a gmsg payload without the chain key.
    static func parseGmsgHeader(_ payloadB64: String) -> GmsgHeader? {
        guard let data = Data(base64Encoded: payloadB64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["v"] as? Int) == 1,
              let kid = obj["kid"] as? String,
              let e = obj["e"] as? Int, let i = obj["i"] as? Int else { return nil }
        return GmsgHeader(kid: kid, epoch: e, index: i)
    }

    struct OpenedGmsg { let envelope: Envelope; let verified: Bool }

    /// Decrypt + verify a gmsg payload under `mk`, checking the signature
    /// against `expectedSpubB64`. Returns nil on AEAD failure (wrong key/tamper).
    static func openGmsg(_ payloadB64: String, gid: Int, mk: Data, expectedSpubB64: String) -> OpenedGmsg? {
        guard let data = Data(base64Encoded: payloadB64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kid = obj["kid"] as? String, let e = obj["e"] as? Int, let i = obj["i"] as? Int,
              let nB64 = obj["n"] as? String, let ctB64 = obj["ct"] as? String,
              let nonceData = Data(base64Encoded: nB64), let ctTag = Data(base64Encoded: ctB64),
              ctTag.count >= 16 else { return nil }
        let aad = gmsgAAD(gid: gid, kid: kid, epoch: e, index: i)
        let ciphertext = ctTag.prefix(ctTag.count - 16)
        let tag = ctTag.suffix(16)
        guard let nonce = try? ChaChaPoly.Nonce(data: nonceData),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plaintext = try? ChaChaPoly.open(box, using: SymmetricKey(data: mk), authenticating: aad),
              let inner = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              let envB64 = inner["env"] as? String, let sigB64 = inner["sig"] as? String,
              let envBytes = Data(base64Encoded: envB64), let sig = Data(base64Encoded: sigB64),
              let env = try? JSONDecoder().decode(Envelope.self, from: envBytes) else { return nil }
        var verified = false
        if let spub = Data(base64Encoded: expectedSpubB64),
           let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: spub) {
            verified = pub.isValidSignature(sig, for: aad + envBytes)
        }
        return OpenedGmsg(envelope: env, verified: verified)
    }

    /// 16 random bytes, base64 — a fresh distribution id.
    static func newKid() -> String {
        var b = Data(count: 16); _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return b.base64EncodedString()
    }
    static func randomChainKey() -> Data {
        var b = Data(count: 32); _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return b
    }
}
