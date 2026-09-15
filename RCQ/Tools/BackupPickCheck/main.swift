// The backup auto-pick rule of report #988, every branch, against the app's
// own CrossIslandLogic.swift. The same cases are pinned on Android (JVM test)
// and on the web (cli/test/backup-pick.mjs): an island that sells entry must
// never be registered on by a toggle, and a person must never be shown the
// island's JSON for it.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias P = BackupAutoPick

func info(_ json: String) -> BackupProbeAnswer { BackupProbeAnswer(status: 200, body: Data(json.utf8)) }
func infoBytes(_ bytes: [UInt8]) -> BackupProbeAnswer { BackupProbeAnswer(status: 200, body: Data(bytes)) }
let ok200 = BackupProbeAnswer(status: 200, body: Data("ok".utf8))
func caps(_ inner: String) -> BackupProbe { P.classify(health: ok200, info: info("{\"capabilities\":{\(inner)}}")) }

print("door:")
check("policy open is open", caps("\"registration_policy\":\"open\"") == .open)
check("policy absent is open", caps("\"user_count\":3") == .open)
check("capabilities absent is open", P.classify(health: ok200, info: info("{\"name\":\"x\"}")) == .open)
check("paid is shut", caps("\"registration_policy\":\"paid\"") == .shut)
check("invite is shut", caps("\"registration_policy\":\"invite\"") == .shut)
check("an unknown policy word is shut", caps("\"registration_policy\":\"members\"") == .shut)
check("Open in another case is not open", caps("\"registration_policy\":\"Open\"") == .shut)
check("closed_island true is shut", caps("\"registration_policy\":\"open\",\"closed_island\":true") == .shut)
check("closed_island false is open", caps("\"registration_policy\":\"open\",\"closed_island\":false") == .open)
check("malformed policy (number) is shut", caps("\"registration_policy\":1") == .shut)
check("malformed closed_island (1) is shut", caps("\"closed_island\":1") == .shut)
check("malformed closed_island (\"false\") is shut", caps("\"closed_island\":\"false\"") == .shut)
check("malformed capabilities (array) is shut", P.classify(health: ok200, info: info("{\"capabilities\":[]}")) == .shut)
check("price ignored: open policy with a price is open",
      caps("\"registration_policy\":\"open\",\"entry_price_cents\":1500") == .open)
check("price ignored: paid policy without a price is shut",
      caps("\"registration_policy\":\"paid\",\"entry_price_cents\":0") == .shut)

print("null is malformed, not absent (D1):")
check("registration_policy null is shut", caps("\"registration_policy\":null") == .shut)
check("closed_island null is shut", caps("\"registration_policy\":\"open\",\"closed_island\":null") == .shut)
check("capabilities null is shut", P.classify(health: ok200, info: info("{\"capabilities\":null}")) == .shut)

print("probe:")
let openInfo = info("{\"capabilities\":{\"registration_policy\":\"open\"}}")
check("no health answer is silent", P.classify(health: nil, info: openInfo) == .silent)
check("health 503 is silent", P.classify(health: BackupProbeAnswer(status: 503, body: Data()), info: openInfo) == .silent)
check("health redirect is silent", P.classify(health: BackupProbeAnswer(status: 302, body: Data()), info: openInfo) == .silent)
check("info redirect is silent", P.classify(health: ok200, info: BackupProbeAnswer(status: 301, body: Data())) == .silent)
check("info 404 is silent", P.classify(health: ok200, info: BackupProbeAnswer(status: 404, body: Data("{}".utf8))) == .silent)
check("no info answer is silent", P.classify(health: ok200, info: nil) == .silent)
check("unreadable info (html) is silent", P.classify(health: ok200, info: info("<html>hi</html>")) == .silent)
check("unreadable info (json array) is silent", P.classify(health: ok200, info: info("[1,2]")) == .silent)

print("body is rejected, never truncated or read leniently (D5):")
func padded(to size: Int) -> String {
    let head = "{\"capabilities\":{\"registration_policy\":\"open\"},\"pad\":\""
    let tail = "\"}"
    return head + String(repeating: "a", count: size - head.utf8.count - tail.utf8.count) + tail
}
check("info exactly at the cap is read", P.classify(health: ok200, info: info(padded(to: P.infoBodyCap))) == .open)
check("info one byte over the cap is silent", P.classify(health: ok200, info: info(padded(to: P.infoBodyCap + 1))) == .silent)
check("trailing comma is silent", P.classify(health: ok200, info: info("{\"capabilities\":{\"registration_policy\":\"paid\"},}")) == .silent)
check("trailing comma in an array is silent", P.classify(health: ok200, info: info("{\"a\":[1,],\"capabilities\":{}}")) == .silent)
check("comment is silent", P.classify(health: ok200, info: info("{/*x*/\"capabilities\":{}}")) == .silent)
check("single quotes are silent", P.classify(health: ok200, info: info("{'capabilities':{}}")) == .silent)
check("unquoted key is silent", P.classify(health: ok200, info: info("{capabilities:{}}")) == .silent)
check("trailing garbage is silent", P.classify(health: ok200, info: info("{\"capabilities\":{}} x")) == .silent)
check("two objects are silent", P.classify(health: ok200, info: info("{}{}")) == .silent)
check("NaN is silent", P.classify(health: ok200, info: info("{\"n\":NaN}")) == .silent)
check("leading zero is silent", P.classify(health: ok200, info: info("{\"n\":01}")) == .silent)
check("raw control character in a string is silent",
      P.classify(health: ok200, info: infoBytes(Array("{\"n\":\"".utf8) + [0x01] + Array("\"}".utf8))) == .silent)
check("invalid UTF-8 is silent",
      P.classify(health: ok200, info: infoBytes(Array("{\"n\":\"".utf8) + [0xFF, 0xFE] + Array("\"}".utf8))) == .silent)
check("UTF-8 byte order mark is silent",
      P.classify(health: ok200, info: infoBytes([0xEF, 0xBB, 0xBF] + Array("{\"name\":\"x\"}".utf8))) == .silent)
check("UTF-16 body is silent",
      P.classify(health: ok200, info: BackupProbeAnswer(status: 200, body: "{\"name\":\"x\"}".data(using: .utf16LittleEndian)!)) == .silent)
check("nesting past the depth limit is silent, not a crash",
      P.classify(health: ok200, info: info("{\"a\":" + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000) + "}")) == .silent)
check("strict JSON with whitespace, escapes, numbers and nesting is read",
      P.classify(health: ok200, info: info(
        " \n{\"name\":\"is\\u00e9 \\\"2\\\"\\n\",\"n\":-1.5e+3,\"z\":0,\"l\":[true,false,null,{}],"
        + "\"capabilities\":{\"registration_policy\":\"open\",\"closed_island\":false}}\t\r\n")) == .open)

print("refusal (D9):")
check("403 entry_required is entry", P.doorRefusal(status: 403, body: "{\"detail\":{\"code\":\"entry_required\"}}") == .entry)
check("403 invite_required is invite", P.doorRefusal(status: 403, body: "{\"detail\":{\"code\":\"invite_required\"}}") == .invite)
check("403 invite_invalid is invite", P.doorRefusal(status: 403, body: "{\"detail\":{\"code\":\"invite_invalid\"}}") == .invite)
check("502 with the code is not a refusal", P.doorRefusal(status: 502, body: "{\"detail\":{\"code\":\"entry_required\"}}") == nil)
check("no status (0) with the code is not a refusal", P.doorRefusal(status: 0, body: "{\"detail\":{\"code\":\"entry_required\"}}") == nil)
check("a page containing the word is not a refusal", P.doorRefusal(status: 403, body: "entry_required") == nil)
check("bare-string detail is not a refusal", P.doorRefusal(status: 403, body: "{\"detail\":\"entry_required\"}") == nil)
check("top-level code without detail is not a refusal", P.doorRefusal(status: 403, body: "{\"code\":\"entry_required\"}") == nil)
check("another code is not a refusal", P.doorRefusal(status: 403, body: "{\"detail\":{\"code\":\"banned\"}}") == nil)
check("a non-string code is not a refusal", P.doorRefusal(status: 403, body: "{\"detail\":{\"code\":1}}") == nil)
check("a code in another case is not a refusal", P.doorRefusal(status: 403, body: "{\"detail\":{\"code\":\"ENTRY_REQUIRED\"}}") == nil)

print("walk:")
final class Log { var calls: [String] = [] }

/// `catalogue` is what the verified catalogue yields after exclusions on the
/// direct route (nil: unfetchable or failing verification); `relayCatalogue`
/// is the same once the relay is up (defaults to `catalogue`).
func walk(
    _ catalogue: [String]?,
    relayCatalogue: [String]?? = .none,
    doors: [String: BackupProbe],
    relayDoors: [String: BackupProbe]? = nil,
    relayUp: Bool = true,
    register: [String: P.RegisterAttempt] = [:],
    recover: [String: P.RecoverAttempt] = [:]
) async -> (P.Outcome, [String]) {
    let log = Log()
    var relay = false
    let outcome = await P.run(
        catalogue: {
            log.calls.append(relay ? "relay-catalogue" : "catalogue")
            if relay, case .some(let c) = relayCatalogue { return c }
            return catalogue
        },
        probe: { h in
            log.calls.append((relay ? "relay-probe " : "probe ") + h)
            return (relay ? (relayDoors ?? doors) : doors)[h] ?? .silent
        },
        openRelay: {
            log.calls.append("open-relay")
            relay = relayUp
            return relayUp
        },
        register: { h in log.calls.append("register " + h); return register[h] ?? .failed },
        recover: { h in log.calls.append("recover " + h); return recover[h] ?? .noCopy }
    )
    return (outcome, log.calls)
}
func steps(_ calls: [String]) -> [String] { calls.filter { $0 != "catalogue" } }

var r = await walk(["a", "b"], doors: ["a": .open], register: ["a": .added])
check("open island: registered and stops, b never probed (D3)",
      r.0 == .added(host: "a") && steps(r.1) == ["probe a", "register a"])

r = await walk(["a", "b", "c"], doors: ["a": .silent, "b": .shut, "c": .open], recover: ["b": .adopted])
check("one at a time in catalogue order, stop at the first backup (D3)",
      r.0 == .added(host: "b") && steps(r.1) == ["probe a", "probe b", "recover b"])

r = await walk(["a", "b"], doors: ["a": .shut, "b": .open], register: ["b": .added])
check("shut island: recover only, never register, then the next",
      r.0 == .added(host: "b") && steps(r.1) == ["probe a", "recover a", "probe b", "register b"])

r = await walk(["a"], doors: ["a": .shut], recover: ["a": .adopted])
check("shut island with an existing copy: adopted", r.0 == .added(host: "a") && steps(r.1) == ["probe a", "recover a"])

r = await walk(["a"], doors: ["a": .shut], recover: ["a": .failed])
check("shut island, recover fails: exactly one recover, no open island",
      r.0 == .noOpenIsland && steps(r.1) == ["probe a", "recover a"])

r = await walk(["a", "b"], doors: ["a": .open, "b": .open],
               register: ["a": .doorRefused, "b": .added])
check("403 door refusal after the add's own recover: no second recover, then the next (D4)",
      r.0 == .added(host: "b") && steps(r.1) == ["probe a", "register a", "probe b", "register b"])

r = await walk(["a"], doors: ["a": .open], register: ["a": .doorRefused], recover: ["a": .adopted])
check("403 door refusal: recover never called again on that island (D4)",
      r.0 == .noOpenIsland && !r.1.contains("recover a"))

r = await walk(["a", "b"], doors: ["a": .shut, "b": .shut])
check("never register on shut islands", !r.1.contains { $0.hasPrefix("register") } && r.0 == .noOpenIsland)

r = await walk(["a", "b"], doors: ["a": .silent, "b": .open], register: ["b": .added])
check("silent island: nothing dialled on it",
      r.0 == .added(host: "b") && steps(r.1) == ["probe a", "probe b", "register b"])

r = await walk(["a", "b"], doors: ["a": .open, "b": .open], register: ["a": .failed, "b": .added])
check("another failure moves on", r.0 == .added(host: "b"))

r = await walk(["a", "a", "A"], doors: ["a": .open], register: ["a": .doorRefused])
check("each island tried at most once",
      steps(r.1) == ["probe a", "register a"] && r.0 == .noOpenIsland)

r = await walk(["a", "b"], doors: [:], relayDoors: ["b": .open], register: ["b": .added])
check("all silent: the relay pass runs once and can yield, catalogue not fetched again",
      r.0 == .added(host: "b")
        && r.1 == ["catalogue", "probe a", "probe b", "open-relay", "relay-probe a", "relay-probe b", "register b"])

r = await walk(["a", "b"], doors: [:])
check("all silent after the relay pass: no island reachable",
      r.0 == .noIslandReachable && r.1.filter { $0 == "open-relay" }.count == 1
        && !r.1.contains { $0.hasPrefix("register") || $0.hasPrefix("recover") })

r = await walk(["a"], doors: [:], relayUp: false)
check("no relay to bring up: pass skipped, no island reachable",
      r.0 == .noIslandReachable && r.1 == ["catalogue", "probe a", "open-relay"])

r = await walk(["a", "b"], doors: ["a": .silent, "b": .shut])
check("answered but none yielded: no open island, and no relay pass",
      r.0 == .noOpenIsland && !r.1.contains("open-relay"))

r = await walk(["a"], doors: ["a": .open], register: ["a": .failed])
check("answered, open, failed: no open island", r.0 == .noOpenIsland)

print("catalogue vs candidates (D2):")
r = await walk([], doors: [:])
check("verified catalogue, nothing left after exclusions: no open island, no relay pass",
      r.0 == .noOpenIsland && r.1 == ["catalogue"])

r = await walk(nil, doors: [:])
check("catalogue unfetchable or unverified: all silent, relay pass runs, fetched again over it",
      r.0 == .noIslandReachable && r.1 == ["catalogue", "open-relay", "relay-catalogue"])

r = await walk(nil, doors: [:], relayUp: false)
check("catalogue unfetchable and no relay to bring up: no island reachable",
      r.0 == .noIslandReachable && r.1 == ["catalogue", "open-relay"])

r = await walk(nil, relayCatalogue: ["a"], doors: [:], relayDoors: ["a": .open], register: ["a": .added])
check("catalogue only over the relay: walked there and yields",
      r.0 == .added(host: "a") && r.1 == ["catalogue", "open-relay", "relay-catalogue", "relay-probe a", "register a"])

r = await walk(nil, relayCatalogue: [], doors: [:])
check("catalogue only over the relay, empty after exclusions: no open island",
      r.0 == .noOpenIsland && r.1 == ["catalogue", "open-relay", "relay-catalogue"])

print("deadline (D6):")
check("direct deadline is 6 s", P.probeDeadline(overRelay: false) == 6)
check("relay deadline is 15 s", P.probeDeadline(overRelay: true) == 15)
let t0 = Date()
let slow: Int? = await P.withDeadline(0.2) {
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    return 1
}
let slowElapsed = Date().timeIntervalSince(t0)
check("a slow exchange is cut at the overall deadline", slow == nil && slowElapsed < 1.5)
let trickle: Int? = await P.withDeadline(0.3) {
    // Every step short, the whole long: an idle timeout would never trip.
    for _ in 0..<40 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        if Task.isCancelled { return nil }
    }
    return 2
}
check("a trickling exchange is cut too", trickle == nil)
let fast: Int? = await P.withDeadline(5) { 7 }
check("an exchange inside the deadline keeps its answer", fast == 7)

print("candidates:")
let c = P.candidates(
    catalogue: ["https://own.example", "is2.example", "IS2.example", "bad host", "added.example", "b.example"],
    normalize: { $0.contains(" ") ? nil : $0.replacingOccurrences(of: "https://", with: "") },
    isOwn: { $0 == "own.example" },
    existing: ["added.example"]
)
check("own, added, repeats and garbage excluded, order kept", c == ["is2.example", "b.example"])

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
