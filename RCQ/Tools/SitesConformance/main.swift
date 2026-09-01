// This client's half of the `.rcq` conformance run. Every case in
// docs/rcq-sites-conformance.json is driven through the app's own
// SiteAddressParser, SiteSanitizer and SiteCSS, and the assertions are the
// corpus's own: presence and absence of substrings, never byte equality, because
// three implementations will differ in whitespace and attribute order and none
// of that is a defect.
//
// A case that fails here is not a failing test, it is a page that is inert in
// one reader and live in another.
import Foundation

let corpusPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "../../../docs/rcq-sites-conformance.json"
guard let raw = try? Data(contentsOf: URL(fileURLWithPath: corpusPath)),
      let corpus = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
    print("cannot read corpus at \(corpusPath)")
    exit(2)
}

var passed = 0
var failures: [String] = []

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failures.append("\(label)  \(detail())") }
}

// ── addresses: parsed on THIS device, never resolved anywhere ──
for (i, item) in (corpus["addresses"] as? [[String: Any]] ?? []).enumerated() {
    let input = item["input"] as? String ?? ""
    let ownHost = item["ownHost"] as? String ?? ""
    let got = SiteAddressParser.parse(input, ownHost: ownHost)
    let shown = got.map { "\($0.name)@\($0.host)" } ?? "nil"
    if let expect = item["expect"] as? [String: Any] {
        let want = "\(expect["name"] as? String ?? "")@\(expect["host"] as? String ?? "")"
        check(shown == want, "addresses[\(i)]", "\(input.debugDescription) want \(want) got \(shown)")
    } else {
        check(got == nil, "addresses[\(i)]", "\(input.debugDescription) want nil got \(shown)")
    }
}

// ── sanitiser: the fixture bundle is spelled out in the corpus's first `why` ──
let fixtureCSS = "@import \"https://evil.example/imported.css\";"
    + "body{background:url(https://evil.example/bg.png);color:#111}"

func render(_ html: String) async -> String {
    let manifest = SiteManifest(
        v: 1, name: "blog", version: 1, key: "k",
        files: [
            "index.html": "-", "about.html": "-", "style.css": "-",
            "logo.png": "-", "mark.svg": "-",
        ],
        sig: "-", title: nil, icon: nil
    )
    let bodies: [String: Data] = [
        "index.html": Data(html.utf8),
        "about.html": Data("<p>about</p>".utf8),
        "style.css": Data(fixtureCSS.utf8),
        "logo.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        "mark.svg": Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8),
    ]
    // The bytes are already hash-checked by SitesRepository in the app; here the
    // fixture stands in for a bundle that verified.
    let sanitiser = SiteSanitizer(manifest: manifest, path: "index.html", fetch: { path in
        guard let bytes = bodies[path] else { throw SiteError.missing }
        return bytes
    })
    return await sanitiser.inline(html)
}

func assertSubstrings(_ out: String, _ item: [String: Any], _ label: String) {
    var bad: [String] = []
    for needle in item["mustNotContain"] as? [String] ?? [] where out.contains(needle) {
        bad.append("must NOT contain \(needle.debugDescription)")
    }
    for needle in item["mustContain"] as? [String] ?? [] where !out.contains(needle) {
        bad.append("must contain \(needle.debugDescription)")
    }
    check(bad.isEmpty, label, "\(bad.joined(separator: " · "))\n      \(out)")
}

for (i, item) in (corpus["sanitiser"] as? [[String: Any]] ?? []).enumerated() {
    assertSubstrings(await render(item["html"] as? String ?? ""), item, "sanitiser[\(i)]")
}

// ── css: the same cleaner a <style> block and a bundle stylesheet both go through ──
for (i, item) in (corpus["css"] as? [[String: Any]] ?? []).enumerated() {
    assertSubstrings(SiteCSS.clean(item["css"] as? String ?? ""), item, "css[\(i)]")
}

for failure in failures { print("FAIL  \(failure)") }
print("passed \(passed) / \(passed + failures.count)")
exit(failures.isEmpty ? 0 : 1)
