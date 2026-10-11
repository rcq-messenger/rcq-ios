// GroupLogStall and GroupLogWalk against the app's own source. The cases are
// report 981's: a row that fails on short visits to the app, a row that fails
// a different way each time, a drain that serves the row on several pages,
// an ack that did not land after a write-off, and a stuck room in front of
// others on an island that fills a page room by room.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// The record as the app keeps it: encoded, and decoded by the next launch.
func relaunch(_ s: GroupLogStall?) -> GroupLogStall? {
    guard let s else { return nil }
    let data = try! JSONEncoder().encode([String(21): s])
    return try! JSONDecoder().decode([String: GroupLogStall].self, from: data)["21"]
}

print("strikes:")
do {
    // One drain per launch, the record carried over disk between them.
    var s: GroupLogStall? = nil
    s = relaunch(GroupLogStall.strike(s, seq: 40, way: "A", drain: 7))
    check("first failure is one strike", s?.strikes == 1 && s?.writtenOff == false)
    s = relaunch(GroupLogStall.strike(s, seq: 40, way: "A", drain: 8))
    check("a second launch adds to it", s?.strikes == 2 && s?.writtenOff == false)
    s = relaunch(GroupLogStall.strike(s, seq: 40, way: "A", drain: 9))
    check("the third drain alike gives it up", s?.strikes == 3 && s?.writtenOff == true)
}
do {
    var s = GroupLogStall.strike(nil, seq: 40, way: "A", drain: 1)
    s = GroupLogStall.strike(s, seq: 40, way: "A", drain: 1)
    s = GroupLogStall.strike(s, seq: 40, way: "A", drain: 1)
    check("pages of one drain count once", s.strikes == 1 && s.drains == 1 && !s.writtenOff)
}
do {
    var s = GroupLogStall.strike(nil, seq: 40, way: "A", drain: 1)
    s = GroupLogStall.strike(s, seq: 40, way: "A", drain: 2)
    s = GroupLogStall.strike(s, seq: 41, way: "A", drain: 3)
    check("another row in front starts over", s.seq == 41 && s.strikes == 1 && s.drains == 1)
}
do {
    var s: GroupLogStall? = nil
    let ways = ["A", "B", "A", "B", "A"]
    for (i, w) in ways.enumerated() {
        s = GroupLogStall.strike(s, seq: 40, way: w, drain: i + 1)
    }
    check("alternating failures are not given up on the same-way count", s?.writtenOff == false)
    s = GroupLogStall.strike(s, seq: 40, way: "B", drain: 6)
    check("but are after six drains failing at all", s?.writtenOff == true && s?.drains == 6)
}
do {
    var s = GroupLogStall.strike(nil, seq: 40, way: "A", drain: 1)
    s = GroupLogStall.strike(s, seq: 40, way: "A", drain: 2)
    s = GroupLogStall.strike(s, seq: 40, way: "A", drain: 3)
    let again = GroupLogStall.strike(s, seq: 40, way: "B", drain: 4)
    check("a written-off row served again (its ack lost) stays written off", again.writtenOff && again == s)
}

print("way of an error:")
enum E: Error { case missingPreKey(UInt32), decryptFailed, invalidMessage(String) }
struct Pending: Error {}
check("the case without what it carried",
      GroupLogStall.way(of: E.missingPreKey(17)) == GroupLogStall.way(of: E.missingPreKey(4_000_000)))
check("a message text does not split a case",
      GroupLogStall.way(of: E.invalidMessage("mac at 12")) == GroupLogStall.way(of: E.invalidMessage("other")))
check("different cases differ", GroupLogStall.way(of: E.decryptFailed) != GroupLogStall.way(of: E.missingPreKey(1)))
check("a plain struct error has a stable name", GroupLogStall.way(of: Pending()) == GroupLogStall.way(of: Pending()))
check("NSError by domain and code",
      GroupLogStall.way(of: NSError(domain: "x", code: 3, userInfo: ["a": 1]))
        == GroupLogStall.way(of: NSError(domain: "x", code: 3, userInfo: ["b": 2]))
        && GroupLogStall.way(of: NSError(domain: "x", code: 3)) != GroupLogStall.way(of: NSError(domain: "y", code: 3)))

print("walk:")
do {
    var w = GroupLogWalk()
    check("first page asks for every room", w.request == nil)
    // Room 21 is stuck at 100, its tail fills the page (an island filling
    // room by room); rooms 30 and 40 got nothing.
    let again = w.took(served: [21: 150], named: [21, 30, 40], more: true, blocked: [21], moved: false)
    check("a page that only got stuck goes on", again)
    check("without the stuck room", w.request == [.init(gid: 30, after: nil), .init(gid: 40, after: nil)])
    let again2 = w.took(served: [30: 9, 40: 12], named: [30, 40], more: false, blocked: [], moved: true)
    check("then reads the stuck room ahead", again2 && w.readingAhead)
    check("from past what this drain read", w.request == [.init(gid: 21, after: 150)])
    let again3 = w.took(served: [21: 300], named: [21], more: true, blocked: [21], moved: false)
    check("ahead while it gets somewhere", again3 && w.request == [.init(gid: 21, after: 300)])
    let again4 = w.took(served: [21: 340], named: [21], more: false, blocked: [], moved: false)
    check("until the room runs dry", !again4)
}
do {
    var w = GroupLogWalk()
    let again = w.took(served: [5: 20], named: [5], more: false, blocked: [], moved: true)
    check("a drain with nothing stuck is one page", !again && !w.readingAhead)
}
do {
    var w = GroupLogWalk()
    let again = w.took(served: [21: 150, 30: 9], named: [21, 30], more: false, blocked: [21], moved: true)
    check("a room stuck on a page that held all of it is not read again", !again && !w.readingAhead)
}
do {
    var w = GroupLogWalk()
    _ = w.took(served: [21: 150], named: [21, 30, 40], more: true, blocked: [21], moved: false)
    _ = w.took(served: [30: 9, 40: 3], named: [30, 40], more: false, blocked: [40], moved: true)
    check("only the room cut short is read ahead", w.readingAhead && w.request == [.init(gid: 21, after: 150)])
}
do {
    var w = GroupLogWalk()
    _ = w.took(served: [21: 150], named: [21, 30], more: true, blocked: [21], moved: false)
    let again = w.took(served: [30: 9], named: [30], more: true, blocked: [], moved: false)
    check("a main page that moved nothing ends the main walk", again && w.readingAhead)
}
do {
    var w = GroupLogWalk()
    _ = w.took(served: [21: 150], named: [21], more: true, blocked: [21], moved: false)
    check("every room stuck: straight to reading ahead", w.readingAhead && w.request == [.init(gid: 21, after: 150)])
    let again = w.took(served: [:], named: [21], more: true, blocked: [], moved: false)
    check("a read-ahead page that brought nothing ends it", !again)
}
do {
    var w = GroupLogWalk()
    var pages = 1
    var more = w.took(served: [21: 10], named: [21, 30], more: true, blocked: [21], moved: false)
    var seq = 10
    while more {
        seq += 10
        pages += 1
        more = w.took(served: w.readingAhead ? [21: seq] : [30: seq], named: [], more: true, blocked: [], moved: true)
    }
    check("no drain walks more than \(GroupLogWalk.maxPages) pages", pages == GroupLogWalk.maxPages)
}
do {
    let data = try! JSONEncoder().encode([GroupLogWalk.Room(gid: 3, after: nil), GroupLogWalk.Room(gid: 4, after: 9)])
    let json = String(decoding: data, as: UTF8.self)
    check("a room with no position leaves `after` out", json.contains("{\"gid\":3}") && json.contains("\"after\":9"))
}

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("all passed")
