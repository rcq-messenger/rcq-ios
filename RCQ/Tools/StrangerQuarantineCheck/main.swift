// The extension's half of the same-island stranger quarantine against the
// app's. Who is held (`QuarantineMirror.holds`), and which kinds.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

print("who the extension holds:")
let mirror = AppGroup.QuarantineMirror(allowed: [7], known: [10, 20])
check("a stranger is held", mirror.holds(99))
check("a contact or a peer written to is not", !mirror.holds(10) && !mirror.holds(20))
check("a stranger let in is not", !mirror.holds(7))
check("with no live roster in the app nobody is held, as the app fails open",
      !AppGroup.QuarantineMirror(allowed: [], known: nil).holds(99))
check("an empty roster still holds a stranger",
      AppGroup.QuarantineMirror(allowed: [], known: []).holds(99))

print("the written form reads back:")
let encoded = try! JSONEncoder().encode(["acct": mirror])
let decoded = try! JSONDecoder().decode([String: AppGroup.QuarantineMirror].self, from: encoded)
check("round trip", decoded["acct"] == mirror)
let noRoster = try! JSONDecoder().decode(
    AppGroup.QuarantineMirror.self, from: Data(#"{"allowed":[1]}"#.utf8)
)
check("an entry without `known` is one without a roster", noRoster.known == nil && !noRoster.holds(5))

// The case list of `func <name>(_ ...: Envelope)` up to its `return true`.
func heldKinds(in path: String, function: String) -> Set<String>? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let start = text.range(of: "func \(function)(") else { return nil }
    let rest = text[start.upperBound...]
    guard let caseStart = rest.range(of: "case "),
          let end = rest.range(of: "return true", range: caseStart.upperBound..<rest.endIndex)
    else { return nil }
    let list = rest[caseStart.upperBound..<end.lowerBound]
    return Set(list.split(whereSeparator: { ",: \n".contains($0) }).compactMap { word -> String? in
        word.hasPrefix(".") ? String(word.dropFirst()) : nil
    })
}

print("the same kinds on both sides:")
let args = CommandLine.arguments
if args.count >= 3,
   let app = heldKinds(in: args[1], function: "isContentKind"),
   let ext = heldKinds(in: args[2], function: "isQuarantinedKind") {
    check("app holds \(app.sorted())", !app.isEmpty)
    check("extension holds the same", app == ext)
    check("a poll is not held (unlike another island's requests)", !ext.contains("poll"))
} else {
    check("both kind lists found in the sources", false)
}

if failures > 0 {
    print("\n\(failures) FAILED")
    exit(1)
}
print("\nall passed")
