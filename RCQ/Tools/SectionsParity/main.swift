// This client's half of the sections parity run. It prints one line per fact;
// the web's half (web.mjs) prints the same lines from the web's own built
// bundle, and run.sh diffs them. Nothing is asserted here: the comparison is
// the assertion, and it is against another implementation rather than against
// a string somebody typed.
//
// Per fixture, in BOTH argument orders:
//
//   content  the normal form `merge(merge(a,b), merge(a,b))`, printed with
//            every key sorted on both sides. This is the answer to "did the
//            two implementations agree about what the tree says", and it is
//            where a tie-break that picked the other value shows up.
//   value    the exact text a watched stranger's value is held as. This is the
//            answer to "did the two implementations agree about the BYTES the
//            tie-break compares", which the sorted content line cannot see.
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let raw = try! Data(contentsOf: dir.appendingPathComponent("fixtures.json"))
let cases = try! JSONSerialization.jsonObject(with: raw) as! [[String: Any]]

/// Every key sorted, at every depth: the one shape both clients can print.
///
/// ⚠ NOT `Sections.encode`, which deliberately leaves a stranger's members in
/// the order they arrived; this line is about content, and the `value` lines
/// below are about order. It does go THROUGH `Sections.encode`, though, so the
/// blob this client would seal is what gets compared rather than the tree in
/// memory.
///
/// ⚠⚠ And not Foundation's `.sortedKeys` either, which is not a byte sort:
/// it folds case and compares digit runs numerically, so it files
/// `p:4471@is2.rcq.app` before `p:100200`. That is fine where `encode` uses it
/// (nothing but this client ever compares those bytes) and useless here, where
/// the whole point is a shape the web can print too.
func sortedForm(_ tree: SectionsTree) -> String {
    guard let any = try? JSONSerialization.jsonObject(with: Sections.encode(tree)) else { return "<unprintable>" }
    return sortedJSON(any)
}

func sortedJSON(_ v: Any) -> String {
    if let d = v as? [String: Any] {
        let body = d.keys.sorted(by: Sections.utf8Less).map { scalarJSON($0) + ":" + sortedJSON(d[$0]!) }
        return "{" + body.joined(separator: ",") + "}"
    }
    if let a = v as? [Any] { return "[" + a.map(sortedJSON).joined(separator: ",") + "]" }
    return scalarJSON(v)
}

func scalarJSON(_ v: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [v], options: []),
          let s = String(data: data, encoding: .utf8), s.count >= 3 else { return "null" }
    return String(s.dropFirst().dropLast())
}

/// The text a watched value is held as, or "-" when it is not a container and
/// so has no member order to hold.
func watched(_ tree: SectionsTree, _ path: String) -> String {
    let parts = path.split(separator: ":", maxSplits: 2).map(String.init)
    let holder: [String: Any]?
    switch parts.first {
    case "top": holder = tree
    case "rec": holder = Sections.records(tree).first { Sections.id($0) == parts[1] }
    default: holder = nil
    }
    guard let holder, let v = holder[parts.count == 3 ? parts[2] : parts[1]] else { return "-" }
    if let box = v as? SectionsRawJSON { return box.text }
    return "-"
}

for c in cases {
    let name = c["name"] as! String
    let a = Data((c["a"] as! String).utf8)
    let b = Data((c["b"] as! String).utf8)
    let watch = c["watch"] as! [String]
    for (order, pair) in [("ab", (a, b)), ("ba", (b, a))] {
        guard let x = Sections.decode(pair.0), let y = Sections.decode(pair.1) else {
            print("\(name)|\(order)|decode|FAILED")
            continue
        }
        guard let merged = try? Sections.merge(x, y), let normal = try? Sections.merge(merged, merged) else {
            print("\(name)|\(order)|merge|FAILED")
            continue
        }
        print("\(name)|\(order)|content|\(sortedForm(normal))")
        for p in watch {
            print("\(name)|\(order)|value \(p)|\(watched(normal, p))")
        }
        // ⚠ The cache is not a tree in memory, it is bytes: `SectionsStore`
        // saves `encode` and loads `decode`, so anything the round trip does
        // not carry is gone by the next cold start. A stranger's member order
        // that survived the merge and died in the cache would put the whole
        // disagreement back a launch later.
        guard let again = Sections.decode(Sections.encode(normal)) else {
            print("\(name)|\(order)|roundtrip|FAILED")
            continue
        }
        print("\(name)|\(order)|roundtrip|\(sortedForm(again))")
        for p in watch {
            print("\(name)|\(order)|roundtrip \(p)|\(watched(again, p))")
        }
    }
}
