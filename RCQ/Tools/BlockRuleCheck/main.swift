// BlockRule, the rule at the bottom of Services/CrossIslandLogic.swift that
// reports 1064 and 1065 were about: a block names a person (a number on our
// island, or uin@host on another one, plus their key when a row says it), and a
// row is dropped only when it comes from that person. Compiled from the REAL
// source the app builds; this project has no test target.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let keyA = Data(repeating: 0xA1, count: 32)
let keyB = Data(repeating: 0xB2, count: 32)

typealias E = BlockRule.Entry

print("our own island")
let own134 = [E(uin: 134, host: nil)]
check("our island's 134 is blocked by a block of our 134",
      BlockRule.blocks(own134, uin: 134, host: nil, key: nil))
check("134 on another island is somebody else (report 1065)",
      !BlockRule.blocks(own134, uin: 134, host: "is2.rcq.app", key: nil))
check("another number on our island is not blocked",
      !BlockRule.blocks(own134, uin: 135, host: nil, key: nil))

print("another island")
let ci134 = [E(uin: 134, host: "is2.rcq.app")]
check("134@is2 is blocked by a block of 134@is2",
      BlockRule.blocks(ci134, uin: 134, host: "is2.rcq.app", key: nil))
check("the island is compared without case",
      BlockRule.blocks([E(uin: 134, host: "IS2.rcq.app")], uin: 134, host: "is2.RCQ.app", key: nil))
check("our own island's 134 is NOT silenced by a block of 134@is2 (report 1065)",
      !BlockRule.blocks(ci134, uin: 134, host: nil, key: nil))
check("134 on a third island is not silenced either",
      !BlockRule.blocks(ci134, uin: 134, host: "falcon.example", key: nil))
check("an island with a port is its own address",
      BlockRule.blocks([E(uin: 7, host: "island.example:8443")], uin: 7, host: "island.example:8443", key: nil)
        && !BlockRule.blocks([E(uin: 7, host: "island.example:8443")], uin: 7, host: "island.example", key: nil))

print("the key: the same person from another address")
let ciKeyed = [E(uin: 134, host: "is2.rcq.app", key: keyA)]
check("a blocked contact writing from their new home under the pinned key is still blocked",
      BlockRule.blocks(ciKeyed, uin: 134, host: "backup.example", key: keyA))
check("even under another number there",
      BlockRule.blocks(ciKeyed, uin: 9001, host: "backup.example", key: keyA))
check("a blocked number of our island moved to a backup keeps its block",
      BlockRule.blocks([E(uin: 50, host: nil, key: keyA)], uin: 77, host: "is3.example", key: keyA))
check("another key at another address is somebody else",
      !BlockRule.blocks(ciKeyed, uin: 134, host: "backup.example", key: keyB))
check("no key on the row (v=2) matches by address only",
      !BlockRule.blocks(ciKeyed, uin: 134, host: "backup.example", key: nil))
check("an entry with an empty key matches nothing by key",
      !BlockRule.blocks([E(uin: 1, host: nil, key: Data())], uin: 2, host: nil, key: Data()))

print("an older build's bare-number block")
let legacy = [E(uin: 134, host: nil, anyIsland: true)]
check("still blocks our island's 134 after the update",
      BlockRule.blocks(legacy, uin: 134, host: nil, key: nil))
check("and 134 on every other island, as it did, so the update unblocks nobody",
      BlockRule.blocks(legacy, uin: 134, host: "is2.rcq.app", key: nil)
        && BlockRule.blocks(legacy, uin: 134, host: "falcon.example", key: nil))
check("and no other number",
      !BlockRule.blocks(legacy, uin: 135, host: "is2.rcq.app", key: nil))

print("nothing blocked")
check("an empty list blocks nobody",
      !BlockRule.blocks([], uin: 134, host: nil, key: keyA))

// The ciack wire, shared with Android 0.213 and the web: when a block or an
// unblock from another device was decided, and whether it names the address.
print("ciack: what a block or unblock names")
typealias A = CIAckRule
check("a plain block names the address", A.scope(act: "block", scope: nil, keyOnly: false) == .address)
check("\"scope\": \"address\" names the address", A.scope(act: "unblock", scope: "address", keyOnly: false) == .address)
check("blockkey names the key", A.scope(act: "blockkey", scope: "key", keyOnly: false) == .key)
check("blockkey with no scope still names only the key", A.scope(act: "blockkey", scope: nil, keyOnly: false) == .key)
check("a plain block carrying \"scope\": \"key\" names only the key",
      A.scope(act: "block", scope: "key", keyOnly: false) == .key)
check("the web's keyOnly: true names only the key", A.scope(act: "unblock", scope: nil, keyOnly: true) == .key)
check("a scope this build does not know is ignored, never read as the address",
      A.scope(act: "block", scope: "person", keyOnly: false) == nil)
check("a key act claiming the address scope is ignored",
      A.scope(act: "unblockkey", scope: "address", keyOnly: false) == nil)
check("accept and decline have no scope", A.scope(act: "accept", scope: "key", keyOnly: false) == nil)
check("block and blockkey block, unblock and unblockkey lift, accept is neither",
      A.blocks("block") == true && A.blocks("blockkey") == true
        && A.blocks("unblock") == false && A.blocks("unblockkey") == false && A.blocks("accept") == nil)

print("ciack: when it was decided")
check("ts first", A.stamp(ts: 50, at: 40) == 50)
check("at when there is no ts (the web's first builds)", A.stamp(ts: nil, at: 40) == 40)
check("a zero ts is no ts", A.stamp(ts: 0, at: 40) == 40)
check("neither: no stamp", A.stamp(ts: nil, at: 0) == nil)
check("a stamp is the decision time", A.decisionAt(stamp: 50, depositedAt: 70, now: 90) == 50)
check("a timeless act counts from its deposit", A.decisionAt(stamp: nil, depositedAt: 70, now: 90) == 70)
check("a timeless live act counts from now", A.decisionAt(stamp: nil, depositedAt: nil, now: 90) == 90)

print("ciack: which decision wins")
let blockedAt100 = A.Decision(on: true, at: 100)
check("nothing held: any decision lands", A.lands(nil, at: 1))
check("a newer unblock lifts a block", A.lands(blockedAt100, at: 101))
check("an unblock at the same time keeps the block", !A.lands(blockedAt100, at: 100))
check("the late echo of an older block does not undo a newer unblock",
      !A.lands(A.Decision(on: false, at: 200), at: 150))
check("a tap here is dated now", A.localAt(blockedAt100, now: 500) == 500)
check("a tap here lands past a decision dated ahead by a fast clock",
      A.localAt(A.Decision(on: true, at: 900), now: 500) == 901)
check("a tap here with nothing held is now", A.localAt(nil, now: 500) == 500)

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASS")
