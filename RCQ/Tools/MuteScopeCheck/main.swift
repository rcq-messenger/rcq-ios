// Mutes per account: how a chat is named in the lists (`MuteKeys`), what the
// extension reads for a push (`MutedStore`), what an island's answer changes,
// and where the phone-wide lists of older builds go.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

print("names:")
check("a number of our island is the number", MuteKeys.peer(134) == "peer:134")
check("somebody on another island is uin@host, in the canonical spelling",
      MuteKeys.peer(134, host: "HTTPS://Is2.RCQ.app:443/") == "peer:134@is2.rcq.app")
check("a port that is not 443 stays", MuteKeys.peer(5, host: "island.example:8443") == "peer:5@island.example:8443")
check("an address is not a number of ours", MuteKeys.ownPeer("peer:134@is2.rcq.app") == nil)
check("and reads back as the address", MuteKeys.address("peer:134@is2.rcq.app") == "134@is2.rcq.app")
check("our number is no address", MuteKeys.address("peer:134") == nil && MuteKeys.ownPeer("peer:134") == 134)
check("the island keeps its own numbers and groups",
      MuteKeys.isIslandKept("peer:5") && MuteKeys.isIslandKept("group:7"))
check("never somebody on another island, nor a room there",
      !MuteKeys.isIslandKept("peer:5@is2.rcq.app") && !MuteKeys.isIslandKept("group:-1000"))

print("the extension's copy of one account:")
let lists = MuteKeys.lists(
    muted: ["peer:5", "peer:134@is2.rcq.app", "group:7", "group:-1000"],
    mentions: ["group:9"]
)
check("split by kind", lists == MutedStore.Lists(
    uins: [5], groupIDs: [-1000, 7], addresses: ["134@is2.rcq.app"], mentionGroupIDs: [9]
))

print("what a push is judged by:")
let a = "AAAAAAAA-0000-0000-0000-000000000001"
let b = "BBBBBBBB-0000-0000-0000-000000000002"
let written = MutedStore.encode([a: lists, b: MutedStore.Lists(uins: [134]), "empty": MutedStore.Lists()])!
let stored = MutedStore.decode(written)
if case .perAccount(let map)? = stored {
    check("written per account, the empty one left out", Set(map.keys) == [a, b])
} else {
    check("the written file reads back per account", false)
}
let forA = MutedStore.mutes(in: stored, for: [a])
let forB = MutedStore.mutes(in: stored, for: [b])
check("A's mute is A's", forA.silences(uin: 5) && !forB.silences(uin: 5))
check("A's group is not B's", forA.silencesGroup(7) && !forB.silencesGroup(7))
check("A's mentions-only group is A's", forA.mentionsOnly(9) && !forB.mentionsOnly(9))
check("somebody on another island by their address, any spelling of it",
      forA.silences(uin: 134, host: "IS2.rcq.app") && forA.silences(uin: 134, host: "https://is2.rcq.app"))
check("not the same number on a third island", !forA.silences(uin: 134, host: "is3.rcq.app"))
check("not the same number on our island", !forA.silences(uin: 134))
check("B's own 134 is not 134 on another island", forB.silences(uin: 134) && !forB.silences(uin: 134, host: "is2.rcq.app"))
let both = MutedStore.mutes(in: stored, for: [a, b])
check("a number two accounts here hold: either's mute holds", both.silences(uin: 5) && both.silences(uin: 134))
check("nobody named, nothing silenced", !MutedStore.mutes(in: stored, for: []).silences(uin: 5))

print("an older build's file, until the app hands it out:")
let older = MutedStore.decode(Data(#"{"uins":[5],"groupIDs":[7],"mentionGroupIDs":[9],"account":"\#(a)"}"#.utf8))
if case .olderBuild(let l, let owner)? = older {
    check("reads as the older form, with its owner", l.uins == [5] && owner == a)
} else {
    check("reads as the older form", false)
}
let oldForB = MutedStore.mutes(in: older, for: [b])
check("still judges every push, as it did", oldForB.silences(uin: 5) && oldForB.silencesGroup(7) && oldForB.mentionsOnly(9))
check("its bare number still covers every island, as it did", oldForB.silences(uin: 5, host: "is2.rcq.app"))
let oldest = MutedStore.decode(Data(#"{"uins":[1],"groupIDs":[]}"#.utf8))
if case .olderBuild(_, let owner)? = oldest {
    check("the oldest file, without mentions or owner, reads too", owner == nil)
} else {
    check("the oldest file reads", false)
}
check("garbage reads as nothing", MutedStore.decode(Data("[1,2]".utf8)) == nil)

print("an island's answer:")
let adopted = MuteKeys.adopt(
    muted: ["peer:1", "peer:2", "peer:134@is2.rcq.app", "group:7", "group:-1000"],
    islandUINs: [2, 3], islandGroups: [8, -1001]
)
check("its own numbers and groups are what it says",
      adopted.contains("peer:2") && adopted.contains("peer:3") && !adopted.contains("peer:1")
        && adopted.contains("group:8") && !adopted.contains("group:7"))
check("somebody on another island and a room there stay",
      adopted.contains("peer:134@is2.rcq.app") && adopted.contains("group:-1000"))
check("a negative id on the island's list (an older build's) names nothing", !adopted.contains("group:-1001"))

print("handing out the phone-wide lists:")
let c = "CCCCCCCC-0000-0000-0000-000000000003"
var ha = MuteKeys.Holdings()
ha.peers = [10]
ha.groups = [7]
var hb = MuteKeys.Holdings()
hb.peers = [20]
hb.addresses = ["10@is2.rcq.app"]
hb.groups = [7, -1000]
var hc = MuteKeys.Holdings()
hc.known = false
let legacy: Set<String> = ["peer:10", "peer:20", "peer:99", "group:7", "group:-1000", "group:8"]
let out = MuteKeys.handOut(muted: legacy, mentions: ["group:7"], holdings: [a: ha, b: hb], active: a)
check("a number goes to the account holding it on its own island", out.muted[a]?.contains("peer:10") == true)
check("and as uin@host to one holding somebody of that number elsewhere",
      out.muted[b]?.contains("peer:10@is2.rcq.app") == true && out.muted[b]?.contains("peer:10") == false)
check("not to an account holding neither", out.muted[a]?.contains("peer:20") == false && out.muted[b]?.contains("peer:20") == true)
check("a group to every account in it", out.muted[a]?.contains("group:7") == true && out.muted[b]?.contains("group:7") == true)
check("a room elsewhere to the account whose alias it is", out.muted[b]?.contains("group:-1000") == true
        && out.muted[a]?.contains("group:-1000") == false)
check("held by nobody shown: everywhere, nothing lost",
      out.muted[a]?.contains("peer:99") == true && out.muted[b]?.contains("peer:99") == true
        && out.muted[a]?.contains("group:8") == true && out.muted[b]?.contains("group:8") == true)
check("holders' islands hear their own mutes",
      out.pending[a] == ["peer:10", "group:7", "peer:99", "group:8"] && out.pending[b] == ["peer:20", "group:7"])
check("never an island not shown to hold the chat, nor anything it does not keep",
      out.pending[b]?.contains("peer:99") == false && out.pending[b]?.contains("peer:10@is2.rcq.app") == false
        && out.pending[b]?.contains("group:-1000") == false)
check("mentions-only to the group's accounts", out.mentions[a] == ["group:7"] && out.mentions[b] == ["group:7"])

let withUnknown = MuteKeys.handOut(muted: ["peer:10"], mentions: [], holdings: [a: ha, b: hb, c: hc], active: a)
check("an account nothing on disk speaks for gets it too, by the number, and its island is not told",
      withUnknown.muted[c] == ["peer:10"] && withUnknown.pending[c] == nil)

var unmutedA = ha
unmutedA.unmuted = ["peer:10", "group:7"]
let afterUnmute = MuteKeys.handOut(muted: ["peer:10"], mentions: ["group:7"], holdings: [a: unmutedA, b: hb], active: a)
check("not as a mute where this account's own last word was an unmute",
      afterUnmute.muted[a] == nil && afterUnmute.pending[a] == nil)
check("an unmute may be the switch to mentions only, which still goes", afterUnmute.mentions[a] == ["group:7"])

let noActive = MuteKeys.handOut(muted: ["peer:99"], mentions: [], holdings: [a: ha, b: hb], active: nil)
check("with no active account nobody's island is told about a chat nobody holds", noActive.pending.isEmpty)

// The extension may not read one list for every push again.
let args = CommandLine.arguments
if args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) {
    check("the extension reads the mutes of the push's account(s)",
          text.contains("MutedStore.shared.mutes(for:") && !text.contains("MutedStore.shared.is"))
} else {
    check("extension source found", false)
}

if failures > 0 {
    print("\n\(failures) FAILED")
    exit(1)
}
print("\nall passed")
