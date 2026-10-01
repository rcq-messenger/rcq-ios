// PinnedRoomLink, the pattern a pinned announcement is split by into text and
// room cards (#990). The ChatView code around it reads groups 1-4 and parses
// the key out of the matched link, and strips every match out of the banner;
// both are re-enacted here against the REAL pattern. This project has no test
// target.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let rx = try! NSRegularExpression(pattern: PinnedRoomLink.pattern, options: [.caseInsensitive])

/// What `ChatView.pinnedSegments` takes from the first link in `text`: the id,
/// the island, the key, and the text left after the link.
func firstLink(_ text: String) -> (id: Int, host: String?, key: String?, after: String)? {
    let ns = text as NSString
    guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let g1 = m.range(at: 1), g2 = m.range(at: 2), g3 = m.range(at: 3), g4 = m.range(at: 4)
    let id = Int(g1.location != NSNotFound ? ns.substring(with: g1) : ns.substring(with: g3)) ?? 0
    let hostRange = g1.location != NSNotFound ? g2 : g4
    let host = hostRange.location != NSNotFound ? ns.substring(with: hostRange).lowercased() : nil
    let url = URL(string: ns.substring(with: m.range))
    let key = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "k" }?.value }
    let after = ns.substring(from: m.range.location + m.range.length)
    return (id, host, key, after)
}

/// What `ChatView.pinnedDisplayText` does to the banner text.
func stripped(_ text: String) -> String {
    text.replacingOccurrences(of: PinnedRoomLink.pattern, with: "", options: [.regularExpression, .caseInsensitive])
}

print("an island with a port")
let ported = firstLink("Join https://rcq.app/g/42@island.example:8443?k=ABCDEFGH12 today")
check("keeps the port in the island", ported?.host == "island.example:8443")
check("and the key", ported?.key == "ABCDEFGH12")
check("leaves nothing of the link behind", ported?.after == " today")
let scheme = firstLink("rcq://group/42@island.example:8443?k=ABCDEFGH12")
check("the rcq:// form too", scheme?.id == 42 && scheme?.host == "island.example:8443" && scheme?.key == "ABCDEFGH12")
check("the banner strips the port and the key with the link",
      stripped("Join: https://rcq.app/g/42@island.example:8443?k=ABCDEFGH12 now") == "Join:  now")

print("the forms that worked before")
let plain = firstLink("https://rcq.app/g/42@is2.rcq.app?k=ABCDEFGH12")
check("an island without a port", plain?.host == "is2.rcq.app" && plain?.key == "ABCDEFGH12")
let bare = firstLink("https://rcq.app/g/42?k=ABCDEFGH12")
check("a bare link has no island and keeps its key", bare != nil && bare?.host == nil && bare?.key == "ABCDEFGH12")
check("a link without a key", firstLink("https://rcq.app/g/42@is2.rcq.app")?.key == nil)

print("punctuation after a link stays in the sentence")
check("a question mark right after the link",
      firstLink("Did you join https://rcq.app/g/42?")?.after == "?"
        && stripped("Did you join https://rcq.app/g/42?") == "Did you join ?")
check("a full stop after the key",
      firstLink("See https://rcq.app/g/42@is2.rcq.app?k=ABCDEFGH12.")?.after == ".")
check("a closing bracket after the key",
      firstLink("(https://rcq.app/g/42?k=ABCDEFGH12)")?.after == ")")
check("a full stop after an island with a port",
      firstLink("See https://rcq.app/g/42@island.example:8443.")?.host == "island.example:8443")

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASS")
