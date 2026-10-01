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

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASS")
