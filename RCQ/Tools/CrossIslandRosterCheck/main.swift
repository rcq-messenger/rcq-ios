// The three rules at the bottom of Services/CrossIslandLogic.swift that report
// #1024 and the push reports were made of:
//
//  - CrossIslandRoster.fold, the cross-island half of the visible roster made
//    equal to the store in BOTH directions, because a 304 is the permanent
//    answer for an account whose only changes are cross-island;
//  - PeerIsland.cardHost, which island a number means when a card is about to
//    resolve it, with the store as the LAST word and never our own island by
//    default;
//  - GuestFlag, what a reply can say about our own row being a guest copy, the
//    iOS twin of Android's GuestFlagWireTest.
//
// Each of these is invisible when wrong in the same way: nothing throws, nothing
// logs, the chat works, and the screen is simply about somebody else or one row
// short. Compiled from the REAL source the app builds. Outside the app target on
// purpose, like BackupPickCheck and IslandTrustCheck: this project has no test
// target.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// A roster row reduced to what the rules look at. The app's `Contact` conforms
/// to the same protocol and carries thirty more fields, none of which any rule
/// here reads; `note` stands in for all of them, so a case can tell "the row
/// already on screen was kept" from "the store's copy replaced it".
struct Row: RosterRow, Equatable {
    let uin: Int
    let host: String?
    var note: String = ""
}

func local(_ uin: Int, _ note: String = "") -> Row { Row(uin: uin, host: nil, note: note) }
func foreign(_ uin: Int, _ host: String, _ note: String = "") -> Row {
    Row(uin: uin, host: host, note: note)
}

// MARK: - fold

print("fold: the store's rows the list is missing")
check("an empty list takes the store's rows",
      CrossIslandRoster.fold([], store: [foreign(5, "is2.rcq.app")])
        == [foreign(5, "is2.rcq.app")])
check("a row written by another device lands next to the island's own",
      CrossIslandRoster.fold([local(1), local(2)], store: [foreign(5, "is2.rcq.app")])
        == [local(1), local(2), foreign(5, "is2.rcq.app")])

print("fold: the rows the store no longer has")
check("a removed foreign row is DROPPED, which appending could never do",
      CrossIslandRoster.fold([local(1), foreign(5, "is2.rcq.app")], store: [])
        == [local(1)])
check("the same number on a DIFFERENT island is a different row and still drops",
      CrossIslandRoster.fold([local(1), foreign(5, "is2.rcq.app")],
                             store: [foreign(5, "other.example")])
        == [local(1), foreign(5, "other.example")])
check("an add and a remove in the same fold",
      CrossIslandRoster.fold([foreign(5, "is2.rcq.app"), foreign(6, "is2.rcq.app")],
                             store: [foreign(6, "is2.rcq.app"), foreign(7, "is2.rcq.app")])
        == [foreign(6, "is2.rcq.app"), foreign(7, "is2.rcq.app")])

print("fold: the island's own rows are never touched")
check("a same-island row survives a fold against an empty store",
      CrossIslandRoster.fold([local(1, "served"), local(2, "served")], store: []) == nil)
check("same-island rows keep their order and their contents",
      CrossIslandRoster.fold([local(9, "served"), local(1, "served")],
                             store: [foreign(5, "is2.rcq.app")])
        == [local(9, "served"), local(1, "served"), foreign(5, "is2.rcq.app")])
check("a store row whose number a same-island contact holds is skipped: one "
      + "number is one thread, and two rows for it would share one history",
      CrossIslandRoster.fold([local(5, "served")], store: [foreign(5, "is2.rcq.app")]) == nil)

print("fold: nothing moved")
check("nil when the two halves already agree",
      CrossIslandRoster.fold([local(1), foreign(5, "is2.rcq.app")],
                             store: [foreign(5, "is2.rcq.app")]) == nil)
check("nil for an empty list and an empty store", CrossIslandRoster.fold([Row](), store: []) == nil)
// The 304 branch runs this on EVERY presence frame, so a fold that reported a
// change each time would wake every view that reads the roster, forever.
check("idempotent: folding the answer again reports nothing",
      {
          let once = CrossIslandRoster.fold([local(1)], store: [foreign(5, "is2.rcq.app")]) ?? []
          return CrossIslandRoster.fold(once, store: [foreign(5, "is2.rcq.app")]) == nil
      }())

print("fold: the row already on screen is kept, not rebuilt")
check("the list's copy wins over the store's: the displayed fields have their "
      + "own refresh path, and a row in front of somebody is not rebuilt",
      CrossIslandRoster.fold([foreign(5, "is2.rcq.app", "on screen")],
                             store: [foreign(5, "is2.rcq.app", "from store")]) == nil)
check("host matching is case-insensitive, or a rehosted row is rebuilt for nothing",
      CrossIslandRoster.fold([foreign(5, "IS2.rcq.app", "on screen")],
                             store: [foreign(5, "is2.rcq.app", "from store")]) == nil)

print("fold: order")
// Android can take the store's order because CrossIslandStore.list() is sorted
// by addedAt. Here all() is a dictionary's values and has no order to inherit,
// so a fold that took it would let somebody's chat list reshuffle on a rehash.
check("rows already on screen keep their places, new ones go on the end",
      CrossIslandRoster.fold([local(1), foreign(5, "a.example"), foreign(6, "a.example")],
                             store: [foreign(7, "a.example"),
                                     foreign(6, "a.example"),
                                     foreign(5, "a.example")])
        == [local(1), foreign(5, "a.example"), foreign(6, "a.example"), foreign(7, "a.example")])
check("a reshuffled store alone is not a change",
      CrossIslandRoster.fold([local(1), foreign(5, "a.example"), foreign(6, "a.example")],
                             store: [foreign(6, "a.example"), foreign(5, "a.example")]) == nil)

// MARK: - cardHost

print("cardHost: a caller that knows which island it means")
check("a room on another island is believed",
      PeerIsland.cardHost(callerHost: "is2.rcq.app", ourIsland: "api.rcq.app",
                          rosterMatched: false, rosterHost: nil, storeHost: nil)
        == "is2.rcq.app")
// #433: the row said is2, the card showed the api account. #429: the request
// went to the api account while the is2 one sat pending.
check("a caller naming OUR island is an answer and falls back to nothing",
      PeerIsland.cardHost(callerHost: "api.rcq.app", ourIsland: "api.rcq.app",
                          rosterMatched: false, rosterHost: nil,
                          storeHost: "is2.rcq.app") == nil)
check("...case-insensitively, since the caller's spelling is whatever it dialled",
      PeerIsland.cardHost(callerHost: "API.rcq.app", ourIsland: "api.rcq.app",
                          rosterMatched: false, rosterHost: nil, storeHost: nil) == nil)
check("a roster row's host wins over a foreign caller's: the room knows where it "
      + "found the number, the roster knows where the person lives",
      PeerIsland.cardHost(callerHost: "room.example", ourIsland: "api.rcq.app",
                          rosterMatched: true, rosterHost: "is2.rcq.app", storeHost: nil)
        == "is2.rcq.app")

print("cardHost: a 1:1, where the caller says nothing")
check("a matched same-island row answers OUR island and is not second-guessed",
      PeerIsland.cardHost(callerHost: nil, ourIsland: "api.rcq.app",
                          rosterMatched: true, rosterHost: nil,
                          storeHost: "is2.rcq.app") == nil)
check("a matched foreign row answers its island",
      PeerIsland.cardHost(callerHost: nil, ourIsland: "api.rcq.app",
                          rosterMatched: true, rosterHost: "is2.rcq.app", storeHost: nil)
        == "is2.rcq.app")
// The line #1024 needed: the store holds the contact while the roster has not
// folded it in yet (an accept from another device, a roster answering 304).
// Without it the card resolved them on OUR island, drew whoever holds that
// number there, and sent that stranger a sealed visit ping.
check("no roster row but the store holds one: THEIR island, not ours",
      PeerIsland.cardHost(callerHost: nil, ourIsland: "api.rcq.app",
                          rosterMatched: false, rosterHost: nil, storeHost: "is2.rcq.app")
        == "is2.rcq.app")
check("nothing anywhere: our own island, which is what a bare number means",
      PeerIsland.cardHost(callerHost: nil, ourIsland: "api.rcq.app",
                          rosterMatched: false, rosterHost: nil, storeHost: nil) == nil)
check("a store row filed under our OWN island still resolves to ours: the "
      + "question is \"somewhere else, and where\"",
      PeerIsland.cardHost(callerHost: nil, ourIsland: "api.rcq.app",
                          rosterMatched: false, rosterHost: nil, storeHost: "API.rcq.app") == nil)
check("no idea which island we are on: a foreign caller is still believed",
      PeerIsland.cardHost(callerHost: "is2.rcq.app", ourIsland: nil,
                          rosterMatched: false, rosterHost: nil, storeHost: nil)
        == "is2.rcq.app")

// MARK: - GuestFlag

print("guest flag: what a reply can say about our own row")
func wire(_ json: String) -> Bool { GuestFlag.isGuest(json: Data(json.utf8)) }
// is2.rcq.app was still on 2026.09.04.11 while the push reports came in.
check("an island that never heard of guests means not a guest",
      wire(#"{"uin":1234,"token":"t"}"#) == false)
check("an explicit denial means not a guest",
      wire(#"{"uin":1234,"token":"t","guest":false}"#) == false)
check("only an explicit yes sets it",
      wire(#"{"uin":1234,"token":"t","guest":true}"#) == true)
check("a null flag falls to not a guest",
      wire(#"{"uin":1234,"token":"t","guest":null}"#) == false)
check("a wrong-typed flag falls to not a guest",
      wire(#"{"uin":1234,"token":"t","guest":"yes"}"#) == false)
// The one route by which a resident could plausibly be told they are a guest.
check("a plain reply from any island carries no guest claim",
      wire(#"{"uin":1234,"token":"t","moved_from":99}"#) == false)
check("nil resolves to not a guest, which is what makes a stale true impossible",
      GuestFlag.isGuest(wire: nil) == false)
check("true is carried through, or the feature does nothing",
      GuestFlag.isGuest(wire: true) == true)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
