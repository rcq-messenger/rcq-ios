// The tolerant catalogue reader in Services/ServerCatalogue.swift: the two
// required fields, the defaults for everything else, the per-entry skip that
// keeps one hand-edited row from costing the whole deck, the flagship-first
// ordering, and the source order. Driven against BOTH real files as they were
// served on 19.09, the ones that found the bug: the site copy where Falcon has
// no `operator_contact` key at all, and the GitHub copy where it is patched to
// an empty string.
//
// The same tolerance is expected of Android (IslandCatalog.kt) and the web
// (island-catalog.ts `sane`): a row without a contact is a row, not a broken
// file.
import Foundation

guard CommandLine.arguments.count > 2,
      let siteBytes = FileManager.default.contents(atPath: CommandLine.arguments[1]),
      let githubBytes = FileManager.default.contents(atPath: CommandLine.arguments[2]) else {
    print("usage: check <servers-rcq.app.json> <servers-github.json>")
    exit(2)
}

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// A file built from entry literals, so a case says what it is about.
func file(_ entries: String..., version: String = "\"version\": 1,", updated: String = "\"updated_at\": \"2026-09-19\",") -> Data {
    Data("{\(version)\(updated)\"servers\":[\(entries.joined(separator: ","))]}".utf8)
}
let minimal = "{\"url\":\"https://a.example\",\"name\":\"A\"}"

func parse(_ data: Data) -> ServerDirectory? {
    try? ServerCatalogue.parse(data)
}

print("the real files (19.09):")
for (label, bytes) in [("rcq.app", siteBytes), ("github", githubBytes)] {
    guard let read = parse(bytes) else {
        check("\(label): the file reads", false)
        continue
    }
    check("\(label): the file reads", true)
    check("\(label): all six entries decode, none skipped",
          read.servers.count == 6 && read.skipped.isEmpty)
    check("\(label): version and updated_at come through",
          read.version == 1 && !read.updatedAt.isEmpty)
    let falcon = read.servers.first(where: { $0.url == "https://146-190-232-70.sslip.io" })
    check("\(label): Falcon is in the list", falcon != nil)
    // The whole point of the fix: on the site copy this key is ABSENT, on the
    // GitHub copy it is "", and both have to read as no contact.
    check("\(label): Falcon has no operator contact and decodes anyway",
          falcon?.operatorContact == "")
    check("\(label): Falcon keeps its name, region and blurb",
          falcon?.name == "Falcon" && falcon?.region == "US" && falcon?.description.isEmpty == false)
    check("\(label): Falcon has no logo", falcon?.logo == nil)
    // is2 carries `auto_backup` and no `logo`; the flagship carries both. The
    // toggle's own list is the signed one, so `auto_backup` is a key this
    // reader walks past rather than a field it models.
    let is2 = read.servers.first(where: { $0.url == "https://is2.rcq.app" })
    check("\(label): an entry with auto_backup and no logo decodes whole",
          is2?.logo == nil && is2?.operatorContact == "hello@rcq.app"
          && is2?.addedAt == "2026-06-10" && is2?.description.hasPrefix("The maintainer's second island") == true)
    let flag = read.servers.first
    check("\(label): the flagship is first and keeps its mirrored logo",
          flag?.url == ServerCatalogue.flagship.url
          && flag?.logo == "https://rcq.app/islands/logos/api.rcq.app.png")
    check("\(label): every entry has a url and a name",
          read.servers.allSatisfy { !$0.url.isEmpty && !$0.name.isEmpty })
    check("\(label): displayHost is the bare host",
          read.servers.first(where: { $0.url == "https://rcq.project26.cc" })?.displayHost == "rcq.project26.cc")
}

print("the two required fields:")
check("url and name are enough", parse(file(minimal))?.servers.count == 1)
check("no url: the entry is skipped, the rest kept",
      parse(file("{\"name\":\"No address\"}", minimal)).map { $0.servers.count == 1 && $0.skipped.count == 1 } == true)
check("blank url is no url",
      parse(file("{\"url\":\"   \",\"name\":\"A\"}"))?.servers.isEmpty == true)
check("no name: the entry is kept and named by its host",
      parse(file("{\"url\":\"https://a.example\"}"))?.servers.first?.name == "a.example")
check("a blank name is the host too",
      parse(file("{\"url\":\"https://a.example\",\"name\":\"\"}"))?.servers.first?.name == "a.example")
check("url of the wrong type is no url",
      parse(file("{\"url\":42,\"name\":\"A\"}"))?.servers.isEmpty == true)
check("null url is no url",
      parse(file("{\"url\":null,\"name\":\"A\"}"))?.servers.isEmpty == true)
check("url and name are trimmed",
      parse(file("{\"url\":\" https://a.example \",\"name\":\" A \"}"))?.servers.first?.url == "https://a.example")

print("every other field is tolerant:")
let bare = parse(file(minimal))?.servers.first
check("absent description, region, contact and added_at default to empty",
      bare?.description == "" && bare?.region == "" && bare?.operatorContact == "" && bare?.addedAt == "")
check("absent logo is nil", bare?.logo == nil)
let sloppy = parse(file(
    "{\"url\":\"https://a.example\",\"name\":\"A\",\"description\":null,\"region\":7,"
    + "\"operator_contact\":[\"x\"],\"added_at\":false,\"logo\":{}}"
))?.servers.first
check("null, number, array, bool and object all read as the default, entry kept",
      sloppy != nil && sloppy?.description == "" && sloppy?.region == ""
      && sloppy?.operatorContact == "" && sloppy?.addedAt == "" && sloppy?.logo == nil)
check("an empty logo string is no logo, not a blank URL",
      parse(file("{\"url\":\"https://a.example\",\"name\":\"A\",\"logo\":\"\"}"))?.servers.first?.logo == nil)
check("unknown fields are ignored, not fatal",
      parse(file("{\"url\":\"https://a.example\",\"name\":\"A\",\"auto_backup\":true,\"price_cents\":900,\"nested\":{\"a\":[1,2]}}"))?.servers.count == 1)

print("one bad row never costs the deck:")
let mixed = parse(file(
    minimal,
    "{\"name\":\"nameless\"}",
    "\"a string, not an entry\"",
    "[1,2]",
    "null",
    "{\"url\":\"https://b.example\",\"name\":\"B\"}"
))
check("four bad rows dropped, two good ones kept, order kept",
      mixed?.servers.map(\.url) == ["https://a.example", "https://b.example"])
check("each dropped row is named for the log", mixed?.skipped.count == 4)
check("a row with no name is kept and named by its host",
      parse(file("{\"url\":\"https://c.example\"}"))?.servers.first?.name == "c.example")
check("a row that is not an object says so",
      parse(file("[1,2]"))?.skipped.first?.contains("not a JSON object") == true)
check("a null row says so and does not hang the read",
      parse(file("null", minimal))?.skipped.first?.contains("null") == true)
check("a null name is replaced by the host too, and the row stays",
      parse(file("{\"url\":\"https://c.example\",\"name\":null}"))?.servers.first?.name == "c.example")

print("the top level:")
check("no version defaults to 1", parse(file(minimal, version: ""))?.version == 1)
check("no updated_at defaults to empty", parse(file(minimal, updated: ""))?.updatedAt == "")
check("version of the wrong type defaults to 1",
      parse(file(minimal, version: "\"version\": \"one\","))?.version == 1)
check("no servers array at all is a failed read, not an empty list",
      parse(Data("{\"version\":1}".utf8)) == nil)
check("servers of the wrong type is a failed read",
      parse(Data("{\"servers\":{\"a\":1}}".utf8)) == nil)
check("an empty servers array reads, with no entries",
      parse(Data("{\"servers\":[]}".utf8))?.servers.isEmpty == true)
check("a JSON array at the top level is a failed read", parse(Data("[]".utf8)) == nil)
check("html is a failed read", parse(Data("<html>nope</html>".utf8)) == nil)
check("truncated json is a failed read", parse(Data("{\"servers\":[{\"url\":\"h".utf8)) == nil)
check("empty bytes are a failed read", parse(Data()) == nil)
check("every row bad is a read with no entries, and the caller treats it as a miss",
      parse(file("{}", "{}")).map { $0.servers.isEmpty && $0.skipped.count == 2 } == true)

print("flagship first:")
let flagshipEntry = ServerCatalogue.flagship
func stub(_ url: String) -> ServerEntry {
    ServerEntry(url: url, name: url, description: "", region: "", operatorContact: "", addedAt: "", logo: nil)
}
check("the flagship is moved to the front, the rest keep their order",
      ServerCatalogue.flagshipFirst([stub("https://x.example"), flagshipEntry, stub("https://y.example")])
        .map(\.url) == [flagshipEntry.url, "https://x.example", "https://y.example"])
check("a trailing slash still matches the flagship",
      ServerCatalogue.flagshipFirst([stub("https://x.example"), stub("https://api.rcq.app/")])
        .first?.url == "https://api.rcq.app/")
check("no flagship in the file: the order is left alone",
      ServerCatalogue.flagshipFirst([stub("https://x.example"), stub("https://y.example")])
        .map(\.url) == ["https://x.example", "https://y.example"])
check("an empty list survives", ServerCatalogue.flagshipFirst([]).isEmpty)
check("the flagship is the island every build points at", flagshipEntry.url == "https://api.rcq.app")

print("sources:")
check("rcq.app is asked FIRST, because raw.githubusercontent.com is blocked "
      + "on the networks where the picker matters",
      ServerCatalogue.sources.first?.absoluteString == "https://rcq.app/servers.json")
check("GitHub is the fallback, not the only road",
      ServerCatalogue.sources.count == 2
      && ServerCatalogue.sources.last?.absoluteString
        == "https://raw.githubusercontent.com/rcq-messenger/rcq-servers/main/servers.json")
check("both sources are https", ServerCatalogue.sources.allSatisfy { $0.scheme == "https" })

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
