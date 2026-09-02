// The §1 rule and the §2/§3 forms of docs/island-fingerprint-design.md, every
// branch, against the app's own IslandTrust. The rule is what makes a changed
// certificate a refusal rather than a shrug, so the branches here are the
// ones that must not drift between the five codebases: the flagship never
// pinned, a typed pin that wins over an authority, CA first and the `ca` write
// on the success branch, a known island never downgraded, and a refusal that
// writes nothing.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias T = IslandTrust
let fpA = String(repeating: "ab12cd34", count: 8)
let fpB = String(repeating: "0f1e2d3c", count: 8)
let fpC = String(repeating: "9876fedc", count: 8)

print("fingerprint:")
check("canonical passes through", T.parseFingerprint(fpA) == fpA)
check("openssl colons and uppercase normalise",
      T.parseFingerprint("AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34") == fpA)
check("spaces and a trailing newline are fine", T.parseFingerprint(" ab12 cd34 ab12 cd34 ab12 cd34 ab12 cd34 ab12 cd34 ab12 cd34 ab12 cd34 ab12 cd34\n") == fpA)
check("63 hex characters are not a fingerprint", T.parseFingerprint(String(fpA.dropLast())) == nil)
check("65 hex characters are not a fingerprint", T.parseFingerprint(fpA + "0") == nil)
check("a non-hex character is refused", T.parseFingerprint(String(fpA.dropLast()) + "g") == nil)
check("an empty string is refused", T.parseFingerprint("") == nil)
check("the display form is four lines of four groups",
      T.displayFingerprint(fpA) == "ab12 cd34 ab12 cd34\nab12 cd34 ab12 cd34\nab12 cd34 ab12 cd34\nab12 cd34 ab12 cd34")
check("the inline form is sixteen groups on one line",
      T.inlineFingerprint(fpA).components(separatedBy: " ").count == 16 && !T.inlineFingerprint(fpA).contains("\n"))
check("sha256 of the DER is the fingerprint",
      T.fingerprint(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

print("address:")
var s = T.splitAddress("203.0.113.5#\(fpA)")
check("ip#fp splits", s.address == "203.0.113.5" && s.fingerprint == fpA && !s.badFragment)
s = T.splitAddress("island.example:8443#AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34:AB:12:CD:34")
check("host:port#openssl splits and keeps the port", s.address == "island.example:8443" && s.fingerprint == fpA)
s = T.splitAddress("https://203.0.113.5/#\(fpA)")
check("a pasted URL keeps working", s.address == "https://203.0.113.5/" && s.fingerprint == fpA)
s = T.splitAddress("  island.example  ")
check("no fragment is no fingerprint and not a bad one", s.address == "island.example" && s.fingerprint == nil && !s.badFragment)
s = T.splitAddress("island.example#notahash")
check("a fragment that is not a fingerprint is flagged", s.address == "island.example" && s.fingerprint == nil && s.badFragment)
s = T.splitAddress("island.example#k=abcdef")
check("a group invite's key pasted into the wrong field is flagged", s.badFragment)
s = T.splitAddress("island.example#\(fpA.dropLast())")
check("a truncated fingerprint is flagged", s.badFragment)
s = T.splitAddress("[::1]:8443#\(fpB)")
check("an IPv6 literal with a port splits", s.address == "[::1]:8443" && s.fingerprint == fpB)

var e = T.endpoint(fromAddress: "island.example")
check("the port defaults to 443", e?.host == "island.example" && e?.port == 443)
check("the key always carries the port", e?.key == "island.example:443")
check("the authority omits 443", e?.authority == "island.example")
e = T.endpoint(fromAddress: "HTTPS://Island.Example:8443/x/")
check("scheme, case and path fall away, the port stays", e?.host == "island.example" && e?.port == 8443 && e?.authority == "island.example:8443")
e = T.endpoint(fromAddress: "[::1]:8443#\(fpB)")
check("IPv6 brackets are stripped from the host", e?.host == "::1" && e?.port == 8443)
check("and kept in the key and the authority", e?.key == "[::1]:8443" && e?.authority == "[::1]:8443")
e = T.endpoint(fromAddress: "http://island.example")
check("http still means a TLS island on 443", e?.port == 443)
check("no host is no endpoint", T.endpoint(fromAddress: "https://") == nil && T.endpoint(fromAddress: "") == nil)
check("a key reads back", T.endpoint(fromKey: "[::1]:8443") == T.Endpoint(host: "::1", port: 8443)
      && T.endpoint(fromKey: "island.example:443")?.authority == "island.example")
check("the share form is host[:port]#fp",
      T.shareAddress(T.Endpoint(host: "island.example", port: 8443), fingerprint: fpA) == "island.example:8443#\(fpA)"
      && T.shareAddress(T.Endpoint(host: "island.example", port: 443), fingerprint: fpA) == "island.example#\(fpA)")

print("CA-only hosts:")
let extra = ["https://api.rcq.app", "https://cdn.rcq.app", "front.example"]
check("the apex", T.isCAOnly("rcq.app", extra: []))
check("anything under the apex", T.isCAOnly("is2.rcq.app", extra: []) && T.isCAOnly("API.RCQ.APP", extra: []))
check("not a look-alike", !T.isCAOnly("notrcq.app", extra: []) && !T.isCAOnly("rcq.app.example", extra: []))
check("the front the config named", T.isCAOnly("front.example", extra: extra))
check("an island is not", !T.isCAOnly("island.example", extra: extra) && !T.isCAOnly("203.0.113.5", extra: extra))

print("the rule:")
let island = T.Endpoint(host: "island.example", port: 443)
let flagship = T.Endpoint(host: "api.rcq.app", port: 443)
var records: [String: T.Record] = [:]
func run(_ fp: String, at end: T.Endpoint = island, caValid: Bool = false, caOnly: Bool = false) -> T.Decision {
    T.decide(endpoint: end, fingerprint: fp, caValid: caValid, caOnly: caOnly, now: 1000, records: &records)
}

check("CA-only host with a valid chain → accept, and NOTHING written: the flagship is never pinned",
      run(fpA, at: flagship, caValid: true, caOnly: true) == .accept && records.isEmpty)
check("CA-only host without a valid chain → refuse, nothing written",
      run(fpA, at: flagship, caOnly: true) == .refuseCAOnly && records.isEmpty)
records = ["api.rcq.app:443": T.Record(mode: .pinned, fp: fpA, source: .typed, since: 1, noticed: true)]
check("even a typed pin on a CA-only host counts for nothing",
      run(fpA, at: flagship, caOnly: true) == .refuseCAOnly
      && run(fpB, at: flagship, caValid: true, caOnly: true) == .accept)

records = [:]
check("CA valid → accept, and the ca record is written on the SUCCESS branch",
      run(fpA, caValid: true) == .accept && records["island.example:443"] == T.Record(mode: .ca, since: 1000, noticed: true))
check("a CA island showing a private cert → changed from ca, ca record kept",
      run(fpA) == .refuseChanged(old: nil, new: fpA, typed: false, ca: false) && records["island.example:443"]?.mode == .ca)
check("a CA island through the CA again → accept, record untouched",
      run(fpB, caValid: true) == .accept && records["island.example:443"] == T.Record(mode: .ca, since: 1000, noticed: true))

records = [:]
check("unknown island → first use, tofu pin",
      run(fpA) == .acceptFirstUse(fp: fpA)
      && records["island.example:443"] == T.Record(mode: .pinned, fp: fpA, source: .tofu, since: 1000, noticed: false))
check("same fingerprint again → accept", run(fpA) == .accept)
check("a different fingerprint → changed, and the pin is NOT overwritten",
      run(fpB) == .refuseChanged(old: fpA, new: fpB, typed: false, ca: false) && records["island.example:443"]?.fp == fpA)
check("CA valid overwrites a tofu pin: the island moved to a CA",
      run(fpB, caValid: true) == .accept && records["island.example:443"] == T.Record(mode: .ca, since: 1000, noticed: true))
check("the port is part of the identity",
      run(fpB, at: T.Endpoint(host: "island.example", port: 8443)) == .acceptFirstUse(fp: fpB)
      && records["island.example:8443"]?.fp == fpB && records["island.example:443"]?.mode == .ca)

records = ["island.example:443": T.Record(mode: .pinned, fp: fpA, source: .accepted, since: 1, noticed: true)]
check("CA valid overwrites an accepted pin too",
      run(fpC, caValid: true) == .accept && records["island.example:443"]?.mode == .ca)

records = ["island.example:443": T.Record(mode: .pinned, fp: fpA, source: .typed, since: 1, noticed: true)]
check("a typed pin that matches → accept", run(fpA) == .accept)
check("a typed pin that matches, CA-valid or not → accept, and the pin stays typed",
      run(fpA, caValid: true) == .accept
      && records["island.example:443"] == T.Record(mode: .pinned, fp: fpA, source: .typed, since: 1, noticed: true))
check("a typed pin that does not → changed, said as typed", run(fpB) == .refuseChanged(old: fpA, new: fpB, typed: true, ca: false))
check("a typed pin against a CA-valid chain → changed, ca carried, and NOT overwritten",
      run(fpB, caValid: true) == .refuseChanged(old: fpA, new: fpB, typed: true, ca: true)
      && records["island.example:443"] == T.Record(mode: .pinned, fp: fpA, source: .typed, since: 1, noticed: true))

print("the store:")
let suite = "rcq.islandtrust.check.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
T.caOnlyHostsProvider = { extra }
let trust = T(defaults: defaults)
let der = Data("leaf".utf8)
let derFP = T.fingerprint(of: der)
let other = Data("other leaf".utf8)
let otherFP = T.fingerprint(of: other)
check("the flagship is CA-only through the provider",
      trust.decide(host: "api.rcq.app", port: 443, leafDER: der, caValid: false) == .refuseCAOnly
      && trust.decide(host: "api.rcq.app", port: 443, leafDER: der, caValid: true) == .accept
      && trust.record(forKey: "api.rcq.app:443") == nil)
check("the front the config named is CA-only",
      trust.decide(host: "front.example", port: 443, leafDER: der, caValid: false) == .refuseCAOnly)
check("a CA-only refusal is not a changed entry", trust.changed.isEmpty && trust.change(forKey: "api.rcq.app:443") == nil)
check("first use is stored", trust.decide(host: "Island.Example", port: 443, leafDER: der, caValid: false) == .acceptFirstUse(fp: derFP)
      && trust.status(forAddress: "https://island.example/")?.record.source == .tofu)
check("the notice is queued until noticed", trust.firstUses.map(\.key) == ["island.example:443"])
check("a second process sees it too", T(defaults: defaults).firstUses.map(\.host) == ["island.example"])
trust.markNoticed(trust.firstUses[0])
check("noticed sticks", trust.firstUses.isEmpty && trust.record(forKey: "island.example:443")?.noticed == true
      && T(defaults: defaults).firstUses.isEmpty)
check("a changed leaf is refused and reported",
      trust.decide(host: "island.example", port: 443, leafDER: other, caValid: false) == .refuseChanged(old: derFP, new: otherFP, typed: false, ca: false)
      && trust.changed["island.example:443"]?.new == otherFP
      && trust.change(forKey: "island.example:443")?.entered == false)
check("the refusal wrote nothing", trust.record(forKey: "island.example:443")?.fp == derFP)
let cancelled = NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)
let timeout = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
check("the task error reads as Refused for that host",
      trust.refusal(for: cancelled, url: URL(string: "https://island.example/health"))
      == T.Refused(host: "island.example", old: derFP, new: otherFP, ca: false)
      && trust.isRefused(url: URL(string: "https://island.example/ws/1")))
check("but a timeout on the same host is still a timeout",
      trust.refusal(for: timeout, url: URL(string: "https://island.example/health")) == nil)
check("and a cancel on a host that is not refused is a cancel",
      trust.refusal(for: cancelled, url: URL(string: "https://other.example/health")) == nil
      && !trust.isRefused(url: URL(string: "https://island.example:8443/")))
trust.accept(trust.changed["island.example:443"]!)
check("accepting writes the new pin as accepted and clears the banner",
      trust.record(forKey: "island.example:443") == T.Record(mode: .pinned, fp: otherFP, source: .accepted, since: trust.record(forKey: "island.example:443")!.since, noticed: true)
      && trust.changed.isEmpty && !trust.isRefused(url: URL(string: "https://island.example/")))
check("and the island connects again", trust.decide(host: "island.example", port: 443, leafDER: other, caValid: false) == .accept)

print("the door:")
check("a typed address pins before any connection",
      trust.admit(typed: "[::1]:8443#\(fpB)") == .admitted(address: "[::1]:8443")
      && trust.record(forKey: "[::1]:8443") == T.Record(mode: .pinned, fp: fpB, source: .typed, since: trust.record(forKey: "[::1]:8443")!.since, noticed: true))
check("a typed address without a fragment is handed back untouched",
      trust.admit(typed: " https://island.example/ ") == .admitted(address: "https://island.example/"))
check("a bad fragment is refused by the door", trust.admit(typed: "island.example#nope") == .notAFingerprint)
check("a fragment on a CA-only host is an address error, nothing written",
      trust.admit(typed: "api.rcq.app#\(fpA)") == .caOnlyHost && trust.record(forKey: "api.rcq.app:443") == nil)
check("a fragment equal to what is on file is a no-op",
      trust.admit(typed: "[::1]:8443#\(fpB)") == .admitted(address: "[::1]:8443")
      && trust.record(forKey: "[::1]:8443")?.source == .typed)
let disagree = trust.admit(typed: "[::1]:8443#\(fpC)")
check("a fragment against a record that disagrees is a change, and NOT written",
      disagree == .changed(T.Change(key: "[::1]:8443", host: "[::1]:8443", old: fpB, new: fpC, typed: true, ca: false, entered: true))
      && trust.record(forKey: "[::1]:8443")?.fp == fpB
      && trust.changed["[::1]:8443"]?.entered == true
      && trust.change(forAddress: "https://[::1]:8443/")?.new == fpC)
if case .changed(let c) = disagree {
    check("a form rewrites its field with the accepted value",
          c.rewriting("https://[::1]:8443/#\(fpB)") == "https://[::1]:8443/#\(fpC)"
          && T.Change(key: c.key, host: c.host, old: c.old, new: c.new, typed: c.typed, ca: true, entered: false)
              .rewriting("[::1]:8443#\(fpB)") == "[::1]:8443")
    trust.accept(c)
    check("accepting the entered value writes it as typed",
          trust.record(forKey: "[::1]:8443") == T.Record(mode: .pinned, fp: fpC, source: .typed, since: trust.record(forKey: "[::1]:8443")!.since, noticed: true)
          && trust.changed.isEmpty)
}
check("a fragment against a CA record is a change from a certificate authority",
      trust.admit(typed: "island.example#\(fpA)") == .changed(T.Change(key: "island.example:443", host: "island.example", old: otherFP, new: fpA, typed: false, ca: false, entered: true)))
trust.forget(key: "island.example:443")
trust.decide(host: "island.example", port: 443, leafDER: der, caValid: true)
check("a CA record on file: the entered value is a change from the authority",
      trust.admit(typed: "island.example#\(fpA)") == .changed(T.Change(key: "island.example:443", host: "island.example", old: nil, new: fpA, typed: false, ca: false, entered: true)))
trust.forget(key: "island.example:443")
check("the typed pin has to match",
      trust.decide(host: "::1", port: 8443, leafDER: der, caValid: false) == .refuseChanged(old: fpC, new: derFP, typed: true, ca: false)
      && trust.changed["[::1]:8443"]?.typed == true)
check("the typed pin has to match a CA-valid chain too, and the refusal says the chain was CA-valid",
      trust.decide(host: "::1", port: 8443, leafDER: der, caValid: true) == .refuseChanged(old: fpC, new: derFP, typed: true, ca: true)
      && trust.changed["[::1]:8443"]?.ca == true)
trust.accept(trust.changed["[::1]:8443"]!)
check("accepting a CA-valid chain over a typed pin records ca",
      trust.record(forKey: "[::1]:8443") == T.Record(mode: .ca, since: trust.record(forKey: "[::1]:8443")!.since, noticed: true))
check("no first-use notice for a typed pin", trust.firstUses.isEmpty)
trust.forget(key: "[::1]:8443")
check("forgetting makes the next connection a first use",
      trust.record(forKey: "[::1]:8443") == nil && trust.changed["[::1]:8443"] == nil
      && trust.decide(host: "[::1]", port: 8443, leafDER: der, caValid: false) == .acceptFirstUse(fp: derFP))
trust.wipe()
check("the burn empties everything", trust.record(forKey: "island.example:443") == nil && trust.firstUses.isEmpty && trust.changed.isEmpty)

print(failures == 0 ? "all good" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
