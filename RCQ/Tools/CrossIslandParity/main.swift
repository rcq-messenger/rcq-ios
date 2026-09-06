// Run the fixtures through the REAL CrossIslandVault and print one line per
// case. web.mjs prints the same lines from web-chat's own built bundle; run.sh
// diffs them. A difference here is not cosmetic: three clients write this one
// slot, it is the only copy of these contacts in existence, and a client that
// disagrees about the bytes rewrites the slot at the others forever.
import Foundation

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let raw = try! Data(contentsOf: URL(fileURLWithPath: dir + "/fixtures.json"))
let cases = try! JSONSerialization.jsonObject(with: raw) as! [[String: Any]]

func state(_ text: String) -> CrossIslandVault.State {
    CrossIslandVault.decode(text.data(using: .utf8)!)!
}

for c in cases {
    let name = c["name"] as! String
    let now = (c["now"] as! NSNumber).doubleValue
    let a = state(c["a"] as! String)
    let b = state(c["b"] as! String)
    let ab = CrossIslandVault.merge(a, b, now: now)
    let ba = CrossIslandVault.merge(b, a, now: now)
    let out = String(data: CrossIslandVault.encode(ab)!, encoding: .utf8)!
    let sym = String(data: CrossIslandVault.encode(ba)!, encoding: .utf8)!
    // Commutative, or two devices converge on different lists depending on
    // which one synced first; idempotent, or every sync is another write.
    let idem = String(data: CrossIslandVault.encode(CrossIslandVault.merge(ab, ab, now: now))!, encoding: .utf8)!
    print("\(name)\t\(out)")
    print("\(name) [reversed]\t\(sym)")
    print("\(name) [twice]\t\(idem)")
}
