// PeerLiveness, the rule at the bottom of Services/CrossIslandLogic.swift that
// report 1067 is about: is a contact on another island still there. Only the
// island's exact answers count; everything unclear is unknown and changes
// nothing. Compiled from the REAL source the app builds; this project has no
// test target.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias R = PeerLiveness.Reply
func json(_ s: String) -> Data { Data(s.utf8) }
func reply(_ status: Int, _ body: String) -> R { R(status: status, body: json(body)) }

// Two 32-byte keys, padded and unpadded spellings of the first.
let ikA = Data(repeating: 0x11, count: 32).base64EncodedString()
let skA = Data(repeating: 0x22, count: 32).base64EncodedString()
let skAUnpadded = String(skA.dropLast())
let skB = Data(repeating: 0x33, count: 32).base64EncodedString()
let ikB = Data(repeating: 0x44, count: 32).base64EncodedString()

func card(_ ik: String, _ sk: String) -> R {
    reply(200, "{\"uin\":134,\"identity_key\":\"\(ik)\",\"signing_key\":\"\(sk)\"}")
}
let noSuchUser = reply(404, "{\"detail\":\"no such user\"}")
let noAccount = reply(404, "{\"detail\":\"no account for key\"}")

func step1(_ r: R?) -> PeerLiveness.CardStep {
    PeerLiveness.cardStep(r, pinnedIdentityKey: ikA, pinnedSigningKey: skA)
}

print("step 1: the open key card")
check("the pinned keys: alive", step1(card(ikA, skA)) == .alive)
check("an unpadded spelling of the pinned key is the same key", step1(card(ikA, skAUnpadded)) == .alive)
check("another signing key: key changed", step1(card(ikA, skB)) == .keyChanged)
check("another identity key: key changed", step1(card(ikB, skA)) == .keyChanged)
check("a 200 that is not a card (a decoy page) is unknown", step1(reply(200, "<html>hi</html>")) == .unknown)
check("a card without a signing key is unknown", step1(reply(200, "{\"identity_key\":\"\(ikA)\"}")) == .unknown)
check("the island's \"no such user\": absent", step1(noSuchUser) == .absent)
check("a bare 404 (no route, parked domain) is unknown", step1(reply(404, "{\"detail\":\"Not Found\"}")) == .unknown)
check("a 404 page that is not JSON is unknown", step1(reply(404, "Not Found")) == .unknown)
check("403 island_closed says nothing about the person", step1(reply(403, "{\"detail\":\"island_closed\"}")) == .unknown)
check("a 5xx is unknown", step1(reply(502, "")) == .unknown)
check("no answer is unknown", step1(nil) == .unknown)
check("a row with no pinned signing key is anchored by its identity key alone",
      PeerLiveness.cardStep(card(ikA, skB), pinnedIdentityKey: ikA, pinnedSigningKey: "") == .alive)

print("step 2: the account for the pinned key")
check("another number under the pinned key: moved",
      PeerLiveness.ownerStep(reply(200, "{\"uin\":555}"), uin: 134) == .moved)
check("the same number back proves nothing",
      PeerLiveness.ownerStep(reply(200, "{\"uin\":134}"), uin: 134) == .unknown)
check("the island's \"no account for key\": absent",
      PeerLiveness.ownerStep(noAccount, uin: 134) == .absent)
check("\"no such user\" is not the words for this step",
      PeerLiveness.ownerStep(noSuchUser, uin: 134) == .unknown)
check("a bare 404 is unknown", PeerLiveness.ownerStep(reply(404, "nope"), uin: 134) == .unknown)
check("a 200 without a number is unknown", PeerLiveness.ownerStep(reply(200, "{}"), uin: 134) == .unknown)
check("no answer is unknown", PeerLiveness.ownerStep(nil, uin: 134) == .unknown)
check("the key goes into the query percent-encoded",
      PeerLiveness.ownerPath(signingKey: "ab+/c=") == "/federation/uin-for-key?signing_key=ab%2B%2Fc%3D")

print("step 3: the person's own record, from our island")
typealias H = PeerLiveness.Home
let recordJSON = "{\"homes\":[]}"
func step3(_ r: R?, _ homes: [H]?) -> PeerLiveness.RecordStep {
    PeerLiveness.recordStep(r, host: "is2.rcq.app", uin: 134) { _ in homes }
}
check("our island's \"no record\": absent", step3(reply(404, "{\"detail\":\"no record\"}"), nil) == .absent)
check("a record naming only this address: absent",
      step3(reply(200, recordJSON), [H(host: "is2.rcq.app", uin: 134)]) == .absent)
check("the same address spelled with :443 and a capital is the same address",
      step3(reply(200, recordJSON), [H(host: "IS2.rcq.app:443", uin: 134)]) == .absent)
check("another home named: moved",
      step3(reply(200, recordJSON), [H(host: "is2.rcq.app", uin: 134), H(host: "api.rcq.app", uin: 7)]) == .moved)
check("another number on the same island: moved",
      step3(reply(200, recordJSON), [H(host: "is2.rcq.app", uin: 999)]) == .moved)
check("a record that does not verify under the pinned key is unknown, not absent",
      step3(reply(200, recordJSON), nil) == .unknown)
check("a 429 from our own island is unknown, not \"no record\"",
      step3(reply(429, "{\"detail\":\"rate limited\"}"), nil) == .unknown)
check("a 5xx is unknown", step3(reply(503, ""), nil) == .unknown)
check("a bare 404 is unknown", step3(reply(404, "{\"detail\":\"Not Found\"}"), nil) == .unknown)
check("no answer is unknown", step3(nil, nil) == .unknown)
check("the key goes into the record query percent-encoded",
      PeerLiveness.recordPath(signingKey: "ab+/c=") == "/federation/gossip-record?sk=ab%2B%2Fc%3D")

print("the whole probe")
func run(_ answers: [String: R?], record: PeerLiveness.RecordStep = .absent) async -> (PeerLiveness.Verdict, [String], Bool) {
    var asked: [String] = []
    var readRecord = false
    let v = await PeerLiveness.classify(
        uin: 134, host: "is2.rcq.app", pinnedIdentityKey: ikA, pinnedSigningKey: skA,
        get: { path in
            asked.append(path)
            return answers[path] ?? nil
        },
        record: {
            readRecord = true
            return record
        }
    )
    return (v, asked, readRecord)
}
let keysPath = "/federation/keys/134"
let ownerPath = PeerLiveness.ownerPath(signingKey: skA)
let sem = DispatchSemaphore(value: 0)
Task {
    let alive = await run([keysPath: card(ikA, skA)])
    check("alive asks one question and never reads the record",
          alive.0 == .alive && alive.1 == [keysPath] && !alive.2)
    let changed = await run([keysPath: card(ikA, skB)])
    check("key changed stops at the card", changed.0 == .keyChanged && changed.1 == [keysPath])
    let closed = await run([keysPath: reply(403, "{\"detail\":\"island_closed\"}")])
    check("a closed island is unknown after one question", closed.0 == .unknown && closed.1 == [keysPath])
    let moved = await run([keysPath: noSuchUser, ownerPath: reply(200, "{\"uin\":555}")])
    check("moved to another number is moved, record never read", moved.0 == .moved && !moved.2)
    let gone = await run([keysPath: noSuchUser, ownerPath: noAccount])
    check("both 404s in the island's words and no record: gone",
          gone.0 == .gone && gone.1 == [keysPath, ownerPath] && gone.2)
    let backup = await run([keysPath: noSuchUser, ownerPath: noAccount], record: .moved)
    check("a deleted backup copy of someone alive at home is moved, not gone", backup.0 == .moved)
    let unreadable = await run([keysPath: noSuchUser, ownerPath: noAccount], record: .unknown)
    check("two clean 404s and a record that could not be read: unknown, not gone", unreadable.0 == .unknown)
    let halfDecoy = await run([keysPath: noSuchUser, ownerPath: reply(404, "<html>")])
    check("a clean first 404 and an unclear second answer: unknown", halfDecoy.0 == .unknown && !halfDecoy.2)
    let silent = await run([:])
    check("an island that never answers: unknown", silent.0 == .unknown)
    sem.signal()
}
sem.wait()

print("marks")
typealias M = PeerLiveness.Mark
let marked = M(sk: skA, gone: 2_000)
check("a mark holds for the row pinned under its key",
      PeerLiveness.holds(marked, rowSigningKey: skAUnpadded, rowAddedAt: 1_000))
check("a row pinned under another key is somebody else",
      !PeerLiveness.holds(marked, rowSigningKey: skB, rowAddedAt: 1_000))
check("no row, no mark", !PeerLiveness.holds(marked, rowSigningKey: nil, rowAddedAt: 0))
check("a contact added again after the mark starts clean",
      !PeerLiveness.holds(marked, rowSigningKey: skA, rowAddedAt: 3_000))
check("stamps alone always hold for the same key",
      PeerLiveness.holds(M(sk: skA, probedAt: 5), rowSigningKey: skA, rowAddedAt: 9_999))

print("when to ask")
let day = PeerLiveness.openEvery
check("never asked: ask", PeerLiveness.mayProbe(.open, last: nil, now: 10))
check("an open probe waits a day", !PeerLiveness.mayProbe(.open, last: 0, now: day - 1)
      && PeerLiveness.mayProbe(.open, last: 0, now: day))
check("a failure probe waits minutes, not a day",
      PeerLiveness.mayProbe(.failure, last: 0, now: PeerLiveness.failureEvery)
      && !PeerLiveness.mayProbe(.failure, last: 0, now: PeerLiveness.failureEvery - 1))
check("a clock that went backwards does not block forever", PeerLiveness.mayProbe(.open, last: 100, now: 50))

print("what a verdict does to a mark")
let blank = M(sk: skA)
check("gone marks gone and drops key changed",
      PeerLiveness.applying(.gone, to: M(sk: skA, keyChanged: 1), now: 7) == M(sk: skA, gone: 7))
check("a second gone keeps the first time",
      PeerLiveness.applying(.gone, to: M(sk: skA, gone: 3), now: 7).gone == 3)
check("key changed is remembered", PeerLiveness.applying(.keyChanged, to: blank, now: 7).keyChanged == 7)
check("alive lifts key changed", PeerLiveness.applying(.alive, to: M(sk: skA, keyChanged: 1), now: 7).keyChanged == nil)
check("moved changes nothing", PeerLiveness.applying(.moved, to: M(sk: skA, keyChanged: 1), now: 7) == M(sk: skA, keyChanged: 1))
check("unknown changes nothing", PeerLiveness.applying(.unknown, to: marked, now: 7) == marked)

check("gone keeps our island's clock beside the device's",
      PeerLiveness.applying(.gone, to: blank, now: 7, islandNow: 5) == M(sk: skA, gone: 7, goneOnIsland: 5))
check("a second gone keeps the first island time too",
      PeerLiveness.applying(.gone, to: M(sk: skA, gone: 3, goneOnIsland: 2), now: 7, islandNow: 6).goneOnIsland == 2)

print("only a verified message lifts gone")
check("a message deposited after the mark lifts it", PeerLiveness.heardFromLifts(marked, depositedAt: 2_500))
check("old mail deposited before the mark does not", !PeerLiveness.heardFromLifts(marked, depositedAt: 1_500))
check("a live delivery with no stamp lifts it", PeerLiveness.heardFromLifts(marked, depositedAt: nil))
check("nothing to lift without a mark", !PeerLiveness.heardFromLifts(blank, depositedAt: 2_500))
// The device ran an hour fast when it marked: on the island's clock the mark
// is an hour earlier than the device thinks.
let fastPhone = M(sk: skA, gone: 3_600_000 + 10_000, goneOnIsland: 10_000)
check("a phone running fast: a message a minute after the mark lifts it",
      PeerLiveness.heardFromLifts(fastPhone, depositedAt: 70_000))
let slowPhone = M(sk: skA, gone: 10_000, goneOnIsland: 3_600_000 + 10_000)
check("a phone running slow: old mail from before the mark does not",
      !PeerLiveness.heardFromLifts(slowPhone, depositedAt: 1_000_000))

print("the island's clock")
check("an HTTP date reads as ms since the epoch",
      PeerLiveness.httpDate("Thu, 01 Jan 1970 00:00:10 GMT") == 10_000)
check("no date, or not a date: nil",
      PeerLiveness.httpDate(nil) == nil && PeerLiveness.httpDate("yesterday") == nil)

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
