// The extension's address rule against the app's, input by input (report
// 1071). Every spelling a sender's client could stamp into `from_host`, and
// every spelling a contact row or a block could be filed under.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func app(_ s: String) -> String? { IslandTrust.endpoint(fromAddress: s)?.authority }
func ext(_ s: String) -> String? { AppGroup.canonicalHost(s) }

let inputs = [
    "is2.rcq.app", "IS2.RCQ.app", "is2.rcq.app:443", "https://is2.rcq.app",
    "https://is2.rcq.app/", "HTTPS://Island.Example:8443/x/", "island.example:8443",
    "island.example:8443#ab12", "  api.rcq.app  ", "api.rcq.app#",
    "203.0.113.5", "203.0.113.5:9444", "localhost:9443", "[::1]:8443", "[::1]",
    "https://[2001:db8::1]:443/", "пример.рф", "xn--e1afmkfd.xn--p1ai",
    "", "   ", "#ab12", "https://", "http://cdn.rcq.app", "cdn.rcq.app:80",
]
print("same answer as the app:")
for i in inputs {
    let a = app(i), e = ext(i)
    check("\"\(i)\" -> \(a ?? "nil")", a == e)
}

print("one island, one name:")
check("case, scheme, slash and :443 are one island",
      Set(["is2.rcq.app", "IS2.rcq.APP", "https://is2.rcq.app/", "is2.rcq.app:443"].map(ext)) == ["is2.rcq.app"])
check("another port is another island", ext("is2.rcq.app:8443") != ext("is2.rcq.app"))
check("the fingerprint is not part of the name", ext("island.example:8443#ab12") == "island.example:8443")
check("nothing is no island", ext("") == nil && ext("#fp") == nil)

if failures > 0 {
    print("\n\(failures) FAILED")
    exit(1)
}
print("\nall passed")
