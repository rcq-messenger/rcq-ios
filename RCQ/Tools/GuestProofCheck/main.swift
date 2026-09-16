// The guest-copy rules of spec 2026-09-15 (C-G), every branch, against the
// app's own CrossIslandLogic.swift and the island's proof vector. The same
// vector is pinned on Android (GuestProofTest) and on the web
// (cli/test/guest-proof.mjs): three clients that disagree about one byte of
// `rcq-guest-v1` get `bad_signature` from every island, and nobody can join.
import CryptoKit
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data {
    var out = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

guard CommandLine.arguments.count > 3,
      let raw = FileManager.default.contents(atPath: CommandLine.arguments[1]),
      let fx = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
      let cryptoSource = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8),
      let ingestSource = try? String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8) else {
    print("usage: check <guest-proof-v1.json> <CryptoService.swift> <MessageService.swift>")
    exit(2)
}

/// Every occurrence of `open<...>close` in `source`. The two app sources are
/// read as text on purpose: compiling CryptoService here would pull in the
/// whole app, and the question asked of them is about spellings, not types.
func between(_ source: String, _ open: String, _ close: String) -> Set<String> {
    var out = Set<String>()
    var rest = Substring(source)
    while let a = rest.range(of: open) {
        rest = rest[a.upperBound...]
        guard let b = rest.range(of: close) else { break }
        out.insert(String(rest[..<b.lowerBound]))
        rest = rest[b.upperBound...]
    }
    return out
}

/// Every string the Envelope ENCODER writes as a `kind`: what this client can
/// actually put on the wire.
func encodedKinds(_ source: String) -> Set<String> {
    between(source, "c.encode(\"", "\", forKey: .kind)")
}

/// Every bare string case in the file, which is a superset of what the Envelope
/// DECODER answers to. A superset is the right side to err on: the check below
/// only asks whether a dropped kind is in it.
func decodedKinds(_ source: String) -> Set<String> {
    var out = Set<String>()
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("case \""), t.hasSuffix("\":") else { continue }
        let body = t.dropFirst(6).dropLast(2)
        if !body.contains("\"") { out.insert(String(body)) }
    }
    return out
}

/// The kinds the room-frame drop actually names, read out of
/// `MessageService.oneToOneOnlyKind`. A rule and an ingest that disagree is the
/// bug this catches: the rule passes its own table check and drops nothing.
func ingestKinds(_ source: String) -> Set<String> {
    guard let start = source.range(of: "func oneToOneOnlyKind") else { return [] }
    let tail = source[start.upperBound...]
    let end = tail.range(of: "default: return nil")?.lowerBound ?? tail.endIndex
    return between(String(tail[..<end]), "return \"", "\"")
}
let hostInput = fx["host_input"] as! String
let canonicalHost = fx["canonical_host"] as! String
let spellings = fx["host_spellings_same_binding"] as! [String]
let groupId = fx["group_id"] as! Int
let ikUnpadded = fx["identity_key_b64_unpadded"] as! String
let ikPadded = fx["identity_key_b64"] as! String
let seed = unhex(fx["signing_seed_hex"] as! String)
let skB64 = fx["signing_key_b64"] as! String
let challenge = fx["challenge"] as! String
let proofHex = fx["proof_bytes_hex"] as! String
let proofText = fx["proof_bytes_text"] as! String
let sigB64 = fx["signature_b64"] as! String

print("fixture bytes:")
check("fixture version is 1", (fx["version"] as? Int) == GuestProof.version)
check("canonical host of the input", GuestProof.canonicalHost(hostInput) == canonicalHost)
for s in spellings {
    check("spelling \(s) binds the same host", GuestProof.canonicalHost(s) == canonicalHost)
}
let ik = GuestProof.decodeKey32(ikUnpadded)
let ikFromPadded = GuestProof.decodeKey32(ikPadded)
let sk = GuestProof.decodeKey32(skB64)
check("identity key decodes unpadded", ik != nil)
check("padded and unpadded identity key are the same bytes", ik != nil && ik == ikFromPadded)
check("signing key decodes", sk != nil)
let bytes = GuestProof.proofBytes(host: hostInput, groupId: groupId, identityKey: ik!, signingKey: sk!, challenge: challenge)
check("proof bytes equal proof_bytes_hex", bytes.map(hex) == proofHex)
check("proof bytes equal proof_bytes_text", bytes.map { String(decoding: $0, as: UTF8.self) } == proofText)
check("no trailing newline", bytes?.last != 0x0A)
let fromPadded = GuestProof.proofBytes(host: canonicalHost, groupId: groupId, identityKey: ikFromPadded!, signingKey: sk!, challenge: challenge)
check("padded key and canonical host give the same bytes", fromPadded == bytes)

print("signature (CryptoKit, as the app signs):")
let priv = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
check("seed gives the fixture's signing key", priv.publicKey.rawRepresentation.base64EncodedString() == skB64)
let fixtureSig = Data(base64Encoded: sigB64)!
check("fixture signature verifies over the bytes", priv.publicKey.isValidSignature(fixtureSig, for: bytes!))
let ours = try! priv.signature(for: bytes!)
check("a signature made here verifies", priv.publicKey.isValidSignature(ours, for: bytes!))
let otherRoom = GuestProof.proofBytes(host: hostInput, groupId: groupId + 1, identityKey: ik!, signingKey: sk!, challenge: challenge)!
check("the room is bound (group id swapped fails)", !priv.publicKey.isValidSignature(fixtureSig, for: otherRoom))
var swappedIk = ik!
swappedIk[0] ^= 0xFF
let otherIk = GuestProof.proofBytes(host: hostInput, groupId: groupId, identityKey: swappedIk, signingKey: sk!, challenge: challenge)!
check("the identity key is bound (ik swapped fails)", !priv.publicKey.isValidSignature(fixtureSig, for: otherIk))
let otherHost = GuestProof.proofBytes(host: "is2.rcq.app", groupId: groupId, identityKey: ik!, signingKey: sk!, challenge: challenge)!
check("the island is bound (another host fails)", !priv.publicKey.isValidSignature(fixtureSig, for: otherHost))

print("request body:")
let body = GuestProof.requestBody(
    host: "api.rcq.app", groupId: groupId, nickname: "Anna",
    identityKey: ik!, signingKey: sk!, challenge: challenge, signature: fixtureSig
)
check("v is the integer 1", (body["v"] as? Int) == 1)
check("group_id is an integer", (body["group_id"] as? Int) == groupId)
check("identity_key is padded standard base64", (body["identity_key"] as? String) == ikPadded)
check("signing_key as the fixture", (body["signing_key"] as? String) == skB64)
check("signature is standard base64 of 64 bytes", (body["signature"] as? String).flatMap { Data(base64Encoded: $0) }?.count == 64)
check("no device_id, no home fields", body["device_id"] == nil && body["desired_uin"] == nil && body["home"] == nil)
check("body serialises as JSON", (try? JSONSerialization.data(withJSONObject: body)) != nil)

print("layout refusals:")
check("group id 0 refused", GuestProof.proofBytes(host: hostInput, groupId: 0, identityKey: ik!, signingKey: sk!, challenge: challenge) == nil)
check("negative group id refused", GuestProof.proofBytes(host: hostInput, groupId: -1041, identityKey: ik!, signingKey: sk!, challenge: challenge) == nil)
check("31-byte key refused", GuestProof.proofBytes(host: hostInput, groupId: groupId, identityKey: ik!.prefix(31), signingKey: sk!, challenge: challenge) == nil)
check("empty challenge refused", GuestProof.proofBytes(host: hostInput, groupId: groupId, identityKey: ik!, signingKey: sk!, challenge: "") == nil)
check("challenge with \\n refused", GuestProof.proofBytes(host: hostInput, groupId: groupId, identityKey: ik!, signingKey: sk!, challenge: "a\nb") == nil)
check("challenge with \\r\\n refused (one Swift Character)", GuestProof.proofBytes(host: hostInput, groupId: groupId, identityKey: ik!, signingKey: sk!, challenge: "a\r\nb") == nil)
check("host with \\r\\n inside refused", GuestProof.proofBytes(host: "api.rcq\r\n.app", groupId: groupId, identityKey: ik!, signingKey: sk!, challenge: challenge) == nil)
check("empty host refused", GuestProof.proofBytes(host: "  ", groupId: groupId, identityKey: ik!, signingKey: sk!, challenge: challenge) == nil)

print("host canonicalisation (reissue_proof.canonical_host):")
check("port 8443 kept", GuestProof.canonicalHost("Island.Example:8443") == "island.example:8443")
check("port 443 dropped", GuestProof.canonicalHost("island.example:443") == "island.example")
check("trailing dots dropped", GuestProof.canonicalHost("island.example..") == "island.example")
check("ipv6 with port", GuestProof.canonicalHost("[2001:DB8::1]:8443") == "[2001:db8::1]:8443")
check("ipv6 with 443", GuestProof.canonicalHost("[2001:db8::1]:443") == "[2001:db8::1]")
check("bare ipv6 literal untouched", GuestProof.canonicalHost("2001:db8::1") == "2001:db8::1")
check("whitespace trimmed", GuestProof.canonicalHost("  api.rcq.app \n") == "api.rcq.app")

print("key decoding (reissue_proof.decode_key32):")
check("url-safe alphabet refused", GuestProof.decodeKey32(skB64.replacingOccurrences(of: "/", with: "_")) == nil)
check("64 bytes refused", GuestProof.decodeKey32(fixtureSig.base64EncodedString()) == nil)
check("garbage refused", GuestProof.decodeKey32("not base64 at all") == nil)

print("path decision (decideGuestPath):")
func info(_ s: String) -> Data { Data(s.utf8) }
check("no answer is legacy", GuestPath.decide(serverInfo: nil) == .legacy)
check("advertised nil is legacy", GuestPath.decide(advertised: nil) == .legacy)
check("advertised false is legacy", GuestPath.decide(advertised: false) == .legacy)
check("advertised true is guest", GuestPath.decide(advertised: true) == .guest)
check("true is guest", GuestPath.decide(serverInfo: info("{\"capabilities\":{\"guest_accounts_v1\":true}}")) == .guest)
check("false is legacy", GuestPath.decide(serverInfo: info("{\"capabilities\":{\"guest_accounts_v1\":false}}")) == .legacy)
check("absent is legacy", GuestPath.decide(serverInfo: info("{\"capabilities\":{\"registration_policy\":\"paid\"}}")) == .legacy)
check("no capabilities is legacy", GuestPath.decide(serverInfo: info("{\"name\":\"x\"}")) == .legacy)
check("string true is legacy", GuestPath.decide(serverInfo: info("{\"capabilities\":{\"guest_accounts_v1\":\"true\"}}")) == .legacy)
check("1 is legacy", GuestPath.decide(serverInfo: info("{\"capabilities\":{\"guest_accounts_v1\":1}}")) == .legacy)
check("null is legacy", GuestPath.decide(serverInfo: info("{\"capabilities\":{\"guest_accounts_v1\":null}}")) == .legacy)
check("html is legacy", GuestPath.decide(serverInfo: info("<html>true</html>")) == .legacy)
check("trailing comma is legacy", GuestPath.decide(serverInfo: info("{\"capabilities\":{\"guest_accounts_v1\":true,}}")) == .legacy)

print("refusal parsing:")
func refusal(_ status: Int, _ json: String) -> IslandRefusal { IslandRefusal.parse(status: status, body: Data(json.utf8)) }
check("code read", refusal(403, "{\"detail\":{\"code\":\"guest_closed\"}}").code == "guest_closed")
check("scope read", refusal(429, "{\"detail\":{\"code\":\"guest_add_limit\",\"scope\":\"seat\"}}").scope == "seat")
check("plain detail has no code", refusal(404, "{\"detail\":\"Not Found\"}").code == nil)
check("html has no code", refusal(502, "<html>guest_closed</html>").code == nil)
check("bare island_busy is a code", refusal(503, "{\"detail\":\"island_busy\"}").code == "island_busy")
check("native prose is not a code", refusal(403, "{\"detail\":\"the group owner has blocked this user\"}").code == nil)
check("404 Not Found still reads as legacy", GuestJoinStep.after(refusal(404, "{\"detail\":\"Not Found\"}"), retried: false) == .legacy)

print("self-join answers (spec 12.1):")
typealias Step = GuestJoinStep
check("no answer: recover fallback", Step.after(nil, retried: false) == .recoverFallback)
for code in ["invalid_challenge", "guest_replayed", "guest_busy"] {
    let r = IslandRefusal(status: code == "invalid_challenge" ? 400 : 409, code: code)
    check("\(code): one retry", Step.after(r, retried: false) == .retryWithFreshChallenge)
    check("\(code) after the retry: refused", Step.after(r, retried: true) == .refused(r))
}
let rotated = IslandRefusal(status: 404, code: "identity_rotated")
check("identity_rotated: rotated flow", Step.after(rotated, retried: false) == .rotated)
check("404 without a code: legacy", Step.after(IslandRefusal(status: 404, code: nil), retried: false) == .legacy)
check("405 without a code: legacy", Step.after(IslandRefusal(status: 405, code: nil), retried: false) == .legacy)
let notFound = IslandRefusal(status: 404, code: "group_not_found")
check("404 group_not_found: refused, not legacy", Step.after(notFound, retried: false) == .refused(notFound))
check("502 without a code: recover fallback", Step.after(IslandRefusal(status: 502, code: nil), retried: false) == .recoverFallback)
check("503 guest_unavailable: recover fallback", Step.after(IslandRefusal(status: 503, code: "guest_unavailable"), retried: false) == .recoverFallback)
let closed = IslandRefusal(status: 403, code: "guest_closed")
check("guest_closed: refused, no legacy fallback", Step.after(closed, retried: false) == .refused(closed))
let limited = IslandRefusal(status: 429, code: "rate_limited")
check("rate_limited: refused", Step.after(limited, retried: false) == .refused(limited))
let badSig = IslandRefusal(status: 401, code: "bad_signature")
check("bad_signature: refused", Step.after(badSig, retried: false) == .refused(badSig))

print("sentences (spec 12.5):")
func j(_ code: String?) -> String? { GuestSentence.join(IslandRefusal(status: 403, code: code)) }
func a(_ code: String?, _ scope: String? = nil) -> String? { GuestSentence.add(IslandRefusal(status: 403, code: code, scope: scope)) }
check("guest_closed", j("guest_closed") == "guest.join.closed")
check("guest_room_closed", j("guest_room_closed") == "guest.join.room_closed")
check("guest_room_full", j("guest_room_full") == "guest.join.room_full")
check("guest_room_limit", j("guest_room_limit") == "guest.join.room_limit")
check("rate_limited", j("rate_limited") == "guest.join.rate")
check("guest_group_limit", j("guest_group_limit") == "guest.join.group_limit")
check("guest_unavailable", j("guest_unavailable") == "guest.unavailable")
check("entry_required on legacy", j("entry_required") == "guest.join.old_paid")
check("invite_required on legacy", j("invite_required") == "guest.join.old_invite")
check("guest_restricted elsewhere", j("guest_restricted") == "guest.restricted")
check("unknown code: generic", j("bad_signature") == nil && j(nil) == nil)
for code in ["invalid_challenge", "guest_replayed", "guest_busy", "island_busy"] {
    check("\(code) after the retry: guest.unavailable", j(code) == "guest.unavailable")
}
check("invite_invalid on legacy", j("invite_invalid") == "guest.join.old_invite")
check("group_closed: closed hint", j("group_closed") == "group_join.closed_hint")
check("blocked on join", j("blocked") == "group_join.error.blocked")
check("429 without a code: rate", GuestSentence.join(IslandRefusal(status: 429, code: nil)) == "guest.join.rate")
// F2 (16.09): the rotated-elsewhere notice is the entire answer. No sentence of
// its own, and ⚠ not the generic line either, which is why every caller asks
// `noticeOnly` BEFORE falling back to it. Android returns null at the same
// point and the web sets no error at all; this used to print a second sentence
// beside the notice.
check("identity_rotated: the notice says it, and nothing else",
      j("identity_rotated") == nil
      && GuestSentence.noticeOnly(IslandRefusal(status: 404, code: "identity_rotated")))
check("nothing else is notice-only",
      !GuestSentence.noticeOnly(IslandRefusal(status: 403, code: "guest_closed"))
      && !GuestSentence.noticeOnly(IslandRefusal(status: 404, code: nil)))
// E2: one table on all three clients. These four were named on Android or the
// web and fell through to the generic line here, so one refusal said two
// different things depending on which client the person held.
check("group_not_found: the room is gone", j("group_not_found") == "group_join.gone")
check("guest_key_retired on a join", j("guest_key_retired") == "group.add.foreign.stale_key")
check("target_guest on a join", j("target_guest") == "group.transfer.err.target_guest")
check("add: target_guest", a("target_guest") == "group.transfer.err.target_guest")
check("add: invalid_challenge is the same wait",
      a("invalid_challenge") == "guest.unavailable" && a("guest_replayed") == "guest.unavailable")
check("add: guest_room_closed same key", a("guest_room_closed") == "guest.join.room_closed")
check("add: guest_room_full", a("guest_room_full") == "guest.join.room_full")
check("add: guest_group_limit", a("guest_group_limit") == "guest.join.group_limit")
check("add: guest_add_limit group", a("guest_add_limit", "group") == "group.add.foreign.limit")
check("add: guest_add_limit seat", a("guest_add_limit", "seat") == "group.add.foreign.seat_limit")
check("add: guest_add_limit without scope is group", a("guest_add_limit") == "group.add.foreign.limit")
check("add: guest_key_retired", a("guest_key_retired") == "group.add.foreign.stale_key")
check("add: guest_restricted is the adder sentence", a("guest_restricted") == "group.add.foreign.guest_adder")
check("add: guest_busy / island_busy", a("guest_busy") == "guest.unavailable" && a("island_busy") == "guest.unavailable")
check("add: blocked", a("blocked") == "group.add.error.blocked")
check("add: invite_contacts_only", a("invite_contacts_only") == "group.add.error.contacts_only")
check("add: invite_nobody", a("invite_nobody") == "group.add.error.nobody")
check("add: native prose blocked", GuestSentence.add(IslandRefusal(status: 403, code: nil), prose: "{\"detail\":\"the group owner has blocked this user\"}") == "group.add.error.blocked")
check("add: native prose contacts", GuestSentence.add(IslandRefusal(status: 403, code: nil), prose: "this user only accepts group invites from their contacts") == "group.add.error.contacts_only")
check("add: native prose nobody", GuestSentence.add(IslandRefusal(status: 403, code: nil), prose: "this user does not accept group invites") == "group.add.error.nobody")
// E2: the island has no row for that number. Android says NO_USER and the web
// says the same sentence; without this row iOS read it as a vague "couldn't
// add", for the same refusal.
check("add: native prose no such user",
      GuestSentence.add(IslandRefusal(status: 404, code: nil), prose: "{\"detail\":\"no such user\"}")
      == "group.transfer.err.no_such_user")
check("add: no code, no prose: generic", a(nil) == nil)
check("transfer: target_guest", GuestSentence.transfer(IslandRefusal(status: 409, code: "target_guest")) == "group.transfer.err.target_guest")
check("respond: guest_restricted", GuestSentence.respond(IslandRefusal(status: 403, code: "guest_restricted")) == "guest.restricted.contacts")

print("nickname never carries a home number (D1):")
check("real name kept", GuestNickname.wire("Anna", homeUins: [123456]) == "Anna")
check("empty name is neutral", GuestNickname.wire("  ", homeUins: [123456]) == GuestNickname.neutral)
check("nil name is neutral", GuestNickname.wire(nil, homeUins: [123456]) == GuestNickname.neutral)
check("user-<uin> is neutral", GuestNickname.wire("user-123456", homeUins: [123456]) == GuestNickname.neutral)
check("bare uin is neutral", GuestNickname.wire("123456", homeUins: [123456]) == GuestNickname.neutral)
check("zero-padded uin is neutral", GuestNickname.wire("id 00123456", homeUins: [123456]) == GuestNickname.neutral)
check("other digits kept", GuestNickname.wire("Anna 1234567", homeUins: [123456]) == "Anna 1234567")
check("neutral word has no digits", !GuestNickname.neutral.contains(where: { $0.isNumber }))
check("usable is nil for the number", GuestNickname.usable("user-42", homeUins: [42]) == nil)
check("clamped to 64", GuestNickname.wire(String(repeating: "a", count: 80), homeUins: []).count == 64)

print("legacy register body:")
let withChal = LegacyGuestRegister.body(nickname: "Anna", identityKey: ikPadded, signingKey: skB64, challenge: "c", signature: "s")
check("carries the register challenge", withChal["challenge"] == "c" && withChal["signature"] == "s")
check("never desired_uin", withChal["desired_uin"] == nil)
let noChal = LegacyGuestRegister.body(nickname: "Anna", identityKey: ikPadded, signingKey: skB64, challenge: nil, signature: nil)
check("an island without the challenge gets the plain body", noChal.count == 3 && noChal["challenge"] == nil)

print("card re-fetch before an add:")
check("same keys, other padding: not stale",
      !GuestAddRule.cardIsStale(pinnedIdentityKey: ikUnpadded, pinnedSigningKey: skB64, cardIdentityKey: ikPadded, cardSigningKey: skB64))
check("new identity key: stale",
      GuestAddRule.cardIsStale(pinnedIdentityKey: ikPadded, pinnedSigningKey: skB64, cardIdentityKey: swappedIk.base64EncodedString(), cardSigningKey: skB64))
check("new signing key: stale",
      GuestAddRule.cardIsStale(pinnedIdentityKey: ikPadded, pinnedSigningKey: skB64, cardIdentityKey: ikPadded, cardSigningKey: ikPadded))
check("undecodable card key: stale",
      GuestAddRule.cardIsStale(pinnedIdentityKey: ikPadded, pinnedSigningKey: skB64, cardIdentityKey: "???", cardSigningKey: skB64))

print("room frames (spec 7):")
for kind in ["contactreq", "ciack", "pkey", "pkeyask", "profile", "visit", "call", "carbon",
             "readmark", "homerec", "gskey", "gsknack", "secscreen", "shot"] {
    check("\(kind) dropped inside a room frame", GroupFrameRule.dropsInGroupFrame(kind: kind))
}
check("exactly the fourteen kinds of D4", GroupFrameRule.oneToOneOnlyKinds.count == 14)
for kind in ["text", "photo", "video", "voice", "file", "location", "skdm", "sknack", "reaction", "edit", "delete", "poll", "read", "delivered"] {
    check("\(kind) kept inside a room frame", !GroupFrameRule.dropsInGroupFrame(kind: kind))
}

// E3: the list against the WIRE, not against the prose of the spec. A kind no
// case encodes is a kind nothing carries, so its entry drops nothing at all and
// the rule passes every table test while the frame sails through. `screenshot`
// for `shot` is exactly that mistake.
print("room frames against the real encoder and decoder (E3):")
let encoded = encodedKinds(cryptoSource)
let decoded = decodedKinds(cryptoSource)
let dropped = GroupFrameRule.oneToOneOnlyKinds
check("the encoder was found in CryptoService.swift", encoded.count > 20)
check("the decoder was found in CryptoService.swift", decoded.count > 20)
for kind in dropped.sorted() {
    check("\(kind) is a kind this client encodes", encoded.contains(kind))
    check("\(kind) is a kind this client decodes", decoded.contains(kind))
}
check("the screenshot notice is shot on the wire",
      dropped.contains("shot") && !dropped.contains("screenshot"))
check("the secure-screen notice is secscreen",
      dropped.contains("secscreen") && !dropped.contains("secure-screen"))
// Sender keys proper ride the room channel and route() needs them.
check("skdm and sknack are never dropped", !dropped.contains("skdm") && !dropped.contains("sknack"))
let ingest = ingestKinds(ingestSource)
check("the ingest mapping was found in MessageService.swift", !ingest.isEmpty)
check("the ingest drops exactly the list, no more and no less", ingest == dropped)

print("roster rows from another island (D5):")
check("a proven copy is labelled", GuestRosterRule.label(guest: true, invited: false) == "group.member.guest")
check("an unclaimed seat is labelled", GuestRosterRule.label(guest: true, invited: true) == "group.member.invited")
check("invited wins over guest", GuestRosterRule.label(guest: false, invited: true) == "group.member.invited")
check("a member who lives here has no label", GuestRosterRule.label(guest: false, invited: false) == nil)
for (g, i) in [(true, false), (true, true), (false, true)] {
    check("guest=\(g) invited=\(i): no message", !GuestRosterRule.canMessage(guest: g, invited: i))
    check("guest=\(g) invited=\(i): no call", !GuestRosterRule.canCall(guest: g, invited: i))
    check("guest=\(g) invited=\(i): no visit ping", !GuestRosterRule.sendsVisitPing(guest: g, invited: i))
    check("guest=\(g) invited=\(i): no other profile action", !GuestRosterRule.hasProfileActions(guest: g, invited: i))
}
check("a copy still gets Add", GuestRosterRule.canAdd(guest: true, invited: false))
check("an unclaimed seat gets no Add", !GuestRosterRule.canAdd(guest: true, invited: true))
check("a member who lives here keeps everything",
      GuestRosterRule.canMessage(guest: false, invited: false)
      && GuestRosterRule.canCall(guest: false, invited: false)
      && GuestRosterRule.sendsVisitPing(guest: false, invited: false)
      && GuestRosterRule.hasProfileActions(guest: false, invited: false)
      && GuestRosterRule.canAdd(guest: false, invited: false))

print("our own session is a copy (D6):")
for surface in ["contact_search", "add_contact", "calls", "random", "audio_rooms",
                "uin_shop", "invites", "sites", "create_group"] {
    check("\(surface) hidden on a copy", GuestPrimaryRule.hides(surface, guestCopy: true))
    check("\(surface) drawn on a native account", !GuestPrimaryRule.hides(surface, guestCopy: false))
}
check("exactly the nine surfaces of D6", GuestPrimaryRule.hiddenSurfaces.count == 9)
check("rooms are never hidden", !GuestPrimaryRule.hides("groups", guestCopy: true))
check("no push token on a copy", !GuestPrimaryRule.registersPush(guestCopy: true))
check("push on a native account", GuestPrimaryRule.registersPush(guestCopy: false))
check("an island that says nothing changes nothing", GuestPrimaryRule.next(current: true, answered: nil))
check("a settle clears it", !GuestPrimaryRule.next(current: true, answered: false))
check("a refresh can set it", GuestPrimaryRule.next(current: false, answered: true))

print("last member who lives here (D8):")
func flags(_ uin: Int, _ guest: Bool, _ invited: Bool = false) -> RosterMemberFlags {
    RosterMemberFlags(uin: uin, guest: guest, invited: invited)
}
let meResident = flags(1, false)
check("everyone else is a copy: warn",
      LastResidentRule.lastResident(members: [meResident, flags(2, true), flags(3, true, true)], leaver: 1))
check("another resident stays: no warning",
      !LastResidentRule.lastResident(members: [meResident, flags(2, false), flags(3, true)], leaver: 1))
check("nobody else at all: no warning", !LastResidentRule.lastResident(members: [meResident], leaver: 1))
check("a guest leaving strands nobody",
      !LastResidentRule.lastResident(members: [flags(1, true), flags(2, true)], leaver: 1))
check("an unfetched roster never warns", !LastResidentRule.lastResident(members: [], leaver: 1))
check("a leaver who is not in the roster never warns",
      !LastResidentRule.lastResident(members: [flags(2, true)], leaver: 1))

// E4: the rule above answers only a roster that is all there. This is what the
// leave surfaces actually call, and the case it exists for is the roster that
// cannot answer: it is FETCHED once, and anything still not SAFE warns.
print("a roster that cannot answer is fetched, never assumed (E4):")
func lc(_ members: [RosterMemberFlags], _ leaver: Int, _ count: Int) -> LastResidentRule.LeaveCheck {
    LastResidentRule.leaveCheck(members: members, leaver: leaver, memberCount: count)
}
check("a page of a bigger roster cannot answer on its own",
      lc([meResident, flags(2, true)], 1, 120) == .needRoster)
check("a page that shows no resident is never safe",
      lc([meResident, flags(2, true)], 1, 120) != .safe)
check("a page with another resident in it is safe",
      lc([meResident, flags(2, false)], 1, 120) == .safe)
check("an empty roster cannot answer", lc([], 1, 0) == .needRoster)
check("a whole roster of copies warns",
      lc([meResident, flags(2, true), flags(3, true, true)], 1, 3) == .warn)
check("another resident stays: safe", lc([meResident, flags(2, false)], 1, 2) == .safe)
check("a copy leaving strands nobody, page or not",
      lc([flags(1, true), flags(2, true)], 1, 2) == .safe
      && lc([flags(1, true), flags(2, true)], 1, 120) == .safe)
check("alone in the room: safe", lc([meResident], 1, 1) == .safe)
check("a leaver who is not in the roster cannot answer", lc([flags(2, true)], 1, 1) == .needRoster)
check("no number of our own in that room cannot answer", lc([flags(2, true)], 0, 1) == .needRoster)
check("the pure rule is exactly the warn case",
      LastResidentRule.lastResident(members: [meResident, flags(2, true)], leaver: 1)
      == (lc([meResident, flags(2, true)], 1, 2) == .warn))

print("settle sentences (spec 9.1, D7):")
func s(_ code: String?, _ status: Int = 403) -> String? { GuestSentence.settle(IslandRefusal(status: status, code: code)) }
check("invite_has_number", s("invite_has_number", 409) == "guest.settle.number_invite")
check("entry_required is the paid door", s("entry_required") == "reg.entry.required")
check("invite_required is the closed door", s("invite_required") == "reg.invite.required")
check("invite_invalid", s("invite_invalid") == "reg.invite.invalid")
check("voucher_other_island", s("voucher_other_island") == "reg.invite.invalid")
check("voucher_expired", s("voucher_expired") == "reg.invite.invalid")
check("voucher_spent", s("voucher_spent", 409) == "residency.code_spent")
// E2: the same code counts as SUCCESS on all three clients. The sheet asks
// this first and runs its success path; the sentence below stays for a caller
// that has none.
check("not_a_guest is a settle that already happened",
      GuestSentence.settleAlreadyDone(IslandRefusal(status: 409, code: "not_a_guest")))
check("nothing else reads as done",
      !GuestSentence.settleAlreadyDone(IslandRefusal(status: 403, code: "voucher_spent"))
      && !GuestSentence.settleAlreadyDone(IslandRefusal(status: 409, code: "invite_has_number"))
      && !GuestSentence.settleAlreadyDone(IslandRefusal(status: 500, code: nil)))
check("not_a_guest keeps a sentence for a caller with no success path",
      s("not_a_guest", 409) == "residency.already")
check("guest_unavailable", s("guest_unavailable", 503) == "guest.unavailable")
check("rate_limited", s("rate_limited", 429) == "guest.join.rate")
check("429 without a code", s(nil, 429) == "guest.join.rate")
check("unknown code falls back to the generic line", s("teapot") == nil && s(nil, 500) == nil)
check("the generic line exists", GuestSentence.settleGeneric == "residency.error")
// F2 (16.09): a settle stopped by a retired key says NOTHING beside the
// rotated-elsewhere notice. ⚠ The table answers nil for the code like it does
// for any unknown one, so the SHEET has to ask `noticeOnly` before it falls
// back to the generic line, exactly as the join sheet does; it used to paint
// "residency.error" under the notice instead.
check("identity_rotated on a settle: the notice says it, and nothing else",
      s("identity_rotated", 401) == nil
      && GuestSentence.noticeOnly(IslandRefusal(status: 401, code: "identity_rotated")))

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
