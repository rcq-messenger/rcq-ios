// Every branch of SenderTrust.decide, ControlAuthority, SkdmRule and
// RoomKeyRule, against the app's own source. The cases are the ones the
// sender-auth review named: a contact of our island forged by anyone who read
// a key card, a host dropped to land in a cross-island contact's thread, a
// room member or owner forged, our own number under somebody else's key, a
// chain re-sent under another key, and the legitimate traffic that must keep
// working (old clients, reissue, restore, multi-device, backup islands).
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func key(_ byte: UInt8) -> String { Data(repeating: byte, count: 32).base64EncodedString() }
let mine = key(1), alice = key(2), mallory = key(3), aliceNew = key(4), bob = key(5)
let me = 100, aliceUIN = 200, bobUIN = 300

func decide(_ build: (inout SenderTrustFacts) -> Void) -> SenderTrust {
    var f = SenderTrustFacts(from: aliceUIN, spub: alice, me: me, myKey: mine)
    build(&f)
    return SenderTrust.decide(f)
}

print("our own number:")
check("our number under our key is us", decide { $0.from = me; $0.spub = mine } == .ownKey)
check("our key is us even with a from_host stamped",
      decide { $0.from = me; $0.spub = mine; $0.claimedHost = "is2.rcq.app" } == .ownKey)
check("our number on our island under another key is forged",
      decide { $0.from = me; $0.spub = mallory } == .forged)
check("our number in a room under another key is forged",
      decide { $0.from = me; $0.spub = mallory; $0.room = [SenderKeyRow(uin: me, host: nil, key: mine)] } == .forged)
check("our number over a checked v=2 session is our session, not our key",
      decide { $0.from = me; $0.spub = nil; $0.viaSession = true } == .ownSession)
check("our number with no key and no session proves nothing",
      decide { $0.from = me; $0.spub = nil } == .unpinned)
check("our number on ANOTHER island under another key is somebody else there",
      decide { $0.from = me; $0.spub = mallory; $0.claimedHost = "is2.rcq.app" } == .unpinned)

print("a number of our island:")
check("signed by the pinned key", decide { $0.pin = alice; $0.islandKey = alice } == .pinned(host: nil))
check("first sight: signed by the key the island serves", decide { $0.islandKey = alice } == .pinned(host: nil))
check("signed by another key than the pin is forged", decide { $0.spub = mallory; $0.pin = alice; $0.islandKey = alice } == .forged)
check("signed by another key than the island serves is forged", decide { $0.spub = mallory; $0.islandKey = alice } == .forged)
check("a reissue: the island serves the new key that signed it",
      decide { $0.spub = aliceNew; $0.pin = alice; $0.islandKey = aliceNew } == .repinned)
check("an old pin still proves the old key while the island moved on",
      decide { $0.pin = alice; $0.islandKey = aliceNew } == .pinned(host: nil))
check("a roster row without a key and no pin: a stranger", decide { $0.islandKey = "" } == .unpinned)
check("nobody known: a stranger", decide { _ in } == .unpinned)
check("a garbage key in the envelope proves nothing", decide { $0.spub = "%%%"; $0.islandKey = alice } == .unpinned)
check("v=2 through a checked session is the number", decide { $0.spub = nil; $0.viaSession = true; $0.pin = alice } == .pinned(host: nil))
check("v=2 with no session behind it is nobody", decide { $0.spub = nil; $0.pin = alice } == .unpinned)
check("no from_host but a cross-island contact's key: that contact, at their row",
      decide { $0.spub = bob; $0.pin = alice; $0.crossIsland = [SenderKeyRow(uin: aliceUIN, host: "b.example", key: bob)] }
        == .pinned(host: "b.example"))
check("no from_host, the cross-island contact's number but a third key: forged",
      decide { $0.spub = mallory; $0.pin = alice; $0.crossIsland = [SenderKeyRow(uin: aliceUIN, host: "b.example", key: bob)] }
        == .forged)
check("no from_host and only a cross-island row under another key: a stranger",
      decide { $0.spub = mallory; $0.crossIsland = [SenderKeyRow(uin: aliceUIN, host: "b.example", key: bob)] }
        == .unpinned)
check("a row for another number never vouches",
      decide { $0.spub = bob; $0.crossIsland = [SenderKeyRow(uin: bobUIN, host: "b.example", key: bob)] } == .unpinned)

print("another island, as the sender says:")
let rows = [SenderKeyRow(uin: aliceUIN, host: "b.example", key: alice)]
check("the exact address under its pinned key", decide { $0.claimedHost = "b.example"; $0.crossIsland = rows } == .pinned(host: "b.example"))
check("the exact address under another key is forged",
      decide { $0.spub = mallory; $0.claimedHost = "b.example"; $0.crossIsland = rows } == .forged)
check("another island of theirs, same key (a backup made primary)",
      decide { $0.claimedHost = "c.example"; $0.crossIsland = rows } == .pinned(host: "b.example"))
check("an unknown address under another key is a stranger",
      decide { $0.spub = mallory; $0.claimedHost = "c.example"; $0.crossIsland = rows } == .unpinned)
check("a pin of our island never vouches for another island's number",
      decide { $0.claimedHost = "c.example"; $0.pin = alice } == .unpinned)
check("v=2 never comes from another island", decide { $0.spub = nil; $0.viaSession = true; $0.claimedHost = "b.example"; $0.crossIsland = rows } == .unpinned)

print("a room:")
let roster = [SenderKeyRow(uin: aliceUIN, host: nil, key: alice), SenderKeyRow(uin: bobUIN, host: nil, key: bob)]
check("a member under the roster's key", decide { $0.room = roster } == .pinned(host: nil))
check("a member under another key is forged", decide { $0.spub = mallory; $0.room = roster } == .forged)
check("the owner forged by a member is forged", decide { $0.from = bobUIN; $0.spub = alice; $0.room = roster } == .forged)
check("a non-member is nobody in the room", decide { $0.from = 999; $0.spub = mallory; $0.room = roster } == .unpinned)
check("a non-member under another key than their pin is forged",
      decide { $0.from = 999; $0.spub = mallory; $0.pin = bob; $0.room = roster } == .forged)
check("a non-member under their own pin is still nobody in the room",
      decide { $0.from = 999; $0.spub = bob; $0.pin = bob; $0.room = roster } == .unpinned)
check("another island's room ignores our island's pin",
      decide { $0.from = 999; $0.spub = mallory; $0.pin = bob; $0.room = roster; $0.roomHost = "b.example" } == .unpinned)
check("a member's pin wins over a stale roster row",
      decide { $0.pin = alice; $0.room = [SenderKeyRow(uin: aliceUIN, host: nil, key: mallory)] } == .pinned(host: nil))
check("a member who reissued: the roster serves the new key", decide { $0.spub = aliceNew; $0.pin = alice; $0.room = [SenderKeyRow(uin: aliceUIN, host: nil, key: aliceNew)] } == .repinned)
check("a roster row without a key falls back to the island's card",
      decide { $0.room = [SenderKeyRow(uin: aliceUIN, host: nil, key: "")]; $0.islandKey = alice } == .pinned(host: nil))
check("a cross-island contact's key does not make somebody a member",
      decide { $0.from = 999; $0.spub = bob; $0.room = roster; $0.crossIsland = [SenderKeyRow(uin: 999, host: "b.example", key: bob)] } == .unpinned)
check("a room on another island: its roster's key, its island",
      decide { $0.room = roster; $0.roomHost = "b.example" } == .pinned(host: "b.example"))
check("a room on another island: another key is forged",
      decide { $0.spub = mallory; $0.room = roster; $0.roomHost = "b.example" } == .forged)
check("a room on another island: a row with no key proves nothing",
      decide { $0.room = [SenderKeyRow(uin: aliceUIN, host: nil, key: "")]; $0.roomHost = "b.example" } == .unpinned)

print("what may act:")
check("own key, pinned and repinned may act",
      SenderTrust.ownKey.isAuthentic && SenderTrust.pinned(host: nil).isAuthentic && SenderTrust.repinned.isAuthentic)
check("our v=2 session, a stranger and a forgery may not",
      !SenderTrust.ownSession.isAuthentic && !SenderTrust.unpinned.isAuthentic && !SenderTrust.forged.isAuthentic)

print("edits:")
typealias T = ControlAuthority.Target<String>
let theirs = T(thread: "peer:200", senderUIN: aliceUIN, isFromMe: false)
let ours = T(thread: "peer:200", senderUIN: me, isFromMe: true)
let inRoom = T(thread: "group:7", senderUIN: bobUIN, isFromMe: false)
check("the author edits their row in their thread", ControlAuthority.mayEdit(theirs, in: "peer:200", by: aliceUIN))
check("the peer does not edit OUR row in our chat", !ControlAuthority.mayEdit(ours, in: "peer:200", by: aliceUIN))
check("a 1:1 sender does not reach a room's row", !ControlAuthority.mayEdit(inRoom, in: "peer:300", by: bobUIN))
check("a member does not edit another member's row", !ControlAuthority.mayEdit(inRoom, in: "group:7", by: aliceUIN))
check("an unknown target is not edited", !ControlAuthority.mayEdit(nil as T?, in: "peer:200", by: aliceUIN))
check("our carbon edits our own row", ControlAuthority.mayEdit(ours, in: "peer:200", by: me, ownCarbon: true))
check("our carbon does not edit theirs", !ControlAuthority.mayEdit(theirs, in: "peer:200", by: me, ownCarbon: true))

print("deletes:")
check("the author deletes their row", ControlAuthority.mayDelete(theirs, in: "peer:200", by: aliceUIN))
check("the peer does not delete our row", !ControlAuthority.mayDelete(ours, in: "peer:200", by: aliceUIN))
check("a moderator deletes in their room", ControlAuthority.mayDelete(inRoom, in: "group:7", by: aliceUIN, senderModerates: true))
check("a moderator does not reach a 1:1 row",
      !ControlAuthority.mayDelete(theirs, in: "group:7", by: bobUIN, senderModerates: true))
check("a moderator does not reach another room",
      !ControlAuthority.mayDelete(T(thread: "group:8", senderUIN: aliceUIN, isFromMe: false), in: "group:7", by: bobUIN, senderModerates: true))
check("a plain member does not delete another's row", !ControlAuthority.mayDelete(inRoom, in: "group:7", by: aliceUIN))
check("our carbon deletes in its thread", ControlAuthority.mayDelete(theirs, in: "peer:200", by: me, ownCarbon: true))
check("our carbon does not reach another thread", !ControlAuthority.mayDelete(theirs, in: "peer:300", by: me, ownCarbon: true))

print("reactions:")
check("a reaction lands in its own thread", ControlAuthority.reactionThread(targetThread: "peer:200", envelopeThread: "peer:200", ownEcho: false) == "peer:200")
check("a 1:1 reaction does not reach a room's row", ControlAuthority.reactionThread(targetThread: "group:7", envelopeThread: "peer:300", ownEcho: false) == nil)
check("our own echo finds the row anywhere", ControlAuthority.reactionThread(targetThread: "group:7", envelopeThread: "peer:100", ownEcho: true) == "group:7")
check("an unknown target lands nowhere", ControlAuthority.reactionThread(targetThread: nil as String?, envelopeThread: "peer:200", ownEcho: true) == nil)

print("sender-key chains:")
let held = SkdmRule.Held(gid: 7, senderUIN: aliceUIN, spub: alice)
check("a new chain from a pinned member of the frame's room is stored",
      SkdmRule.verdict(held: nil, gid: 7, senderUIN: aliceUIN, spub: alice, frameRoom: true, senderAuthentic: true) == .store)
check("not from a pinned member: refused",
      SkdmRule.verdict(held: nil, gid: 7, senderUIN: aliceUIN, spub: alice, frameRoom: true, senderAuthentic: false) == .refuse)
check("a chain for another room than the frame's: refused",
      SkdmRule.verdict(held: nil, gid: 8, senderUIN: aliceUIN, spub: alice, frameRoom: false, senderAuthentic: true) == .refuse)
check("a re-send of a held chain under the same key is known",
      SkdmRule.verdict(held: held, gid: 7, senderUIN: aliceUIN, spub: alice, frameRoom: true, senderAuthentic: true) == .known)
check("a held chain re-sent under another key is refused, never re-keyed",
      SkdmRule.verdict(held: held, gid: 7, senderUIN: aliceUIN, spub: mallory, frameRoom: true, senderAuthentic: true) == .refuse)
check("another member's chain claimed by a member: refused",
      SkdmRule.verdict(held: held, gid: 7, senderUIN: bobUIN, spub: bob, frameRoom: true, senderAuthentic: true) == .refuse)
check("a chain of room 7 replayed into room 8: refused",
      SkdmRule.verdict(held: held, gid: 8, senderUIN: aliceUIN, spub: alice, frameRoom: true, senderAuthentic: true) == .refuse)
check("a chain with no key: refused",
      SkdmRule.verdict(held: nil, gid: 7, senderUIN: aliceUIN, spub: "", frameRoom: true, senderAuthentic: true) == .refuse)

print("room keys:")
// A minter: our own key, the owner, an admin, or a member with the info or members cap.
check("a minter's first key of a room sealed at 3 may be 4",
      RoomKeyRule.accepts(4, held: nil, sealed: 3, opensBlob: false, mayMint: true))
check("a held key may be repaired at its own version by a minter",
      RoomKeyRule.accepts(2, held: 2, sealed: nil, opensBlob: false, mayMint: true))
check("a minter's next generation is taken before the new blob arrives",
      RoomKeyRule.accepts(3, held: 2, sealed: 2, opensBlob: false, mayMint: true))
check("a jump that would wedge the room is refused, even from a minter",
      !RoomKeyRule.accepts(1 << 53, held: 2, sealed: 2, opensBlob: false, mayMint: true))
check("a minter's key for a room we know nothing about starts at 1",
      RoomKeyRule.accepts(1, held: nil, sealed: nil, opensBlob: false, mayMint: true))
check("a negative version is refused",
      !RoomKeyRule.accepts(-1, held: nil, sealed: nil, opensBlob: true, mayMint: true))
check("a plain member at sealed+1 with a key that opens nothing is refused",
      !RoomKeyRule.accepts(3, held: 2, sealed: 2, opensBlob: false, mayMint: false))
check("a plain member's key at the sealed version that opens the blob is taken",
      RoomKeyRule.accepts(2, held: nil, sealed: 2, opensBlob: true, mayMint: false))
check("a key that opens the blob under another version than the blob's is refused",
      !RoomKeyRule.accepts(9, held: nil, sealed: 2, opensBlob: true, mayMint: false))
check("a plain member's key for a room with no blob is refused",
      !RoomKeyRule.accepts(1, held: nil, sealed: nil, opensBlob: false, mayMint: false))

if failures > 0 {
    print("\n\(failures) FAILED")
    exit(1)
}
print("\nall passed")
