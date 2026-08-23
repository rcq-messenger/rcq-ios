import Foundation
import os.log

/// Chat-list sections: the format, the merge, the caps and the slot.
///
/// Founder item 1 of 23.08, built to `docs/sections-design-2026-08-23.md`. A
/// section is a user-made bucket in the chat list. The list of sections (and
/// which chat sits in which) lives in a SECOND vault slot, "sections", derived
/// exactly like "contacts": the island stores 32 hex characters and a sealed
/// blob and attaches no meaning to either. Web `src/lib/sections.ts` +
/// `src/lib/sections-vault.ts`, Android `data/SectionsVault.kt`, same JSON and
/// the same merge to the line.
///
/// ## Two rules that are easy to get wrong
///
/// ⚠⚠ PATCH, DO NOT REBUILD. Everything here copies the decoded JSON tree and
/// edits the keys it knows about. Nothing deserialises into a `Codable` struct
/// and re-encodes from scratch, because that silently deletes whatever a newer
/// build, or another platform, wrote next to it. `Sections` is a set of
/// accessors over `[String: Any]`, not the shape of the object.
///
/// ⚠⚠ A MEMBER KEY CARRIES THE HOST. A uin is per-island: `1234` here and
/// `1234@is2.rcq.app` are two different people, and keying them the same has
/// already cost this project a bug twice. A foreign group is worse: its LOCAL
/// id is a negative alias allocated in first-sight order on each device
/// (`VisitedIslandsStore.aliasFor`), so it is not the same number on two
/// phones. The slot only ever holds (remoteId, host), and the translation
/// happens at the edge.

/// The decoded slot. A plain JSON object so unknown keys ride through.
typealias SectionsTree = [String: Any]

/// A value under a key this build does not own, kept EXACTLY as the bytes
/// carried it: the same JSON, with the same members in the same order.
///
/// ⚠⚠ THE ORDER IS THE TIE-BREAK. An unknown key has no timestamp, so
/// `pickLarger` always decides it, and it ranks a container by its serialised
/// JSON. Web (`JSON.stringify`) and Android (Gson's `LinkedTreeMap`) both print
/// an object's members in the order the bytes had. Foundation cannot: a
/// dictionary out of `JSONSerialization` is hash-ordered, and parse order
/// survives two or three keys by luck and nothing further. So this client used
/// to rank `{"a":1,"z":9}` against `{"a":9,"z":1}` where the other two ranked
/// `{"z":9,"a":1}` against `{"z":1,"a":9}`, and picked the OTHER winner: three
/// clients, two answers, no stamp to settle it, and they rewrite the slot at
/// each other until the island 429s.
///
/// A stranger's value is therefore never re-serialised. `decode` keeps its text
/// (insignificant whitespace out, everything else byte for byte), `canonical`
/// ranks that text, and `encode` writes it back untouched, which is what "patch,
/// do not rebuild" (§2.1) means one level down: this client republishes another
/// build's object exactly as it received it, member order included.
///
/// ⚠ The text is the WRITER's spelling, kept, where web and Android RE-PRINT
/// from the parsed value. That is the same string for every writer that prints
/// minimal compact JSON, which all three do and which the design doc (§2)
/// already requires; keeping it is the safer of the two, because Foundation
/// does NOT re-print the way the other two do. It writes `a\/b` for `a/b`,
/// which this client used to rank above `aZb` where web ranks it below: any URL
/// in anybody's future key hit that. What is left over is the mirror image, and
/// nobody writes it: a blob that spells `é` the long way, or `1000` as `1e3`,
/// ranks here as the bytes say and on web as the re-print says. Android keeps
/// the writer's spelling too (Gson hands back the literal it parsed), so on
/// that pair this client is with Android and web is on its own.
final class SectionsRawJSON {
    /// The value as the bytes carried it, minified.
    let text: String
    /// What `JSONSerialization` made of the same bytes. Nothing in this build
    /// reads it; it is here so a build that LEARNS the key has the value and
    /// not just its spelling.
    let value: Any

    init(text: String, value: Any) {
        self.text = text
        self.value = value
    }
}

/// Where that order comes from. `JSONSerialization` throws it away, so the
/// slot's bytes are walked a second time: the scan reports, for the top-level
/// object and for each element of `s`, the minified text of every member's
/// value.
///
/// It runs on bytes `JSONSerialization` has already accepted, so it does not
/// validate, it follows. Anything it cannot follow gives up for the WHOLE tree
/// (`run` answers nil) and leaves the merge on plain sorted keys, which is
/// wrong the same way for every value rather than wrong for one of them. In
/// practice the only such thing is an ESCAPED NAME on the two objects whose
/// names this has to match up with `JSONSerialization`'s (the tree and a
/// record): decoding one differently from Foundation would file a value under
/// a key that is not in the tree, which is worse than not knowing the order.
/// Names INSIDE a stranger's value are copied through like any other bytes and
/// never compared, so they can be escaped all they like.
private struct SectionsJSONScan {
    struct Result {
        /// top-level member name -> minified text of its value
        let top: [String: String]
        /// index into `s` -> (member name -> minified text of its value)
        let records: [Int: [String: String]]
    }

    private let b: [UInt8]
    private var i = 0

    private init(_ d: Data) { b = [UInt8](d) }

    static func run(_ data: Data) -> Result? {
        var s = SectionsJSONScan(data)
        return s.document()
    }

    // MARK: The document, which is the only shape that gets special treatment

    private mutating func document() -> Result? {
        guard eat(0x7b) else { return nil }
        var top: [String: String] = [:]
        var records: [Int: [String: String]] = [:]
        if eat(0x7d) { return Result(top: top, records: records) }
        while true {
            var skip = [UInt8]()
            guard let key = memberName(&skip) else { return nil }
            guard eat(0x3a) else { return nil }
            if key == "s", peek() == 0x5b {
                guard let recs = recordArray() else { return nil }
                records = recs
            } else {
                var text = [UInt8]()
                guard value(&text) else { return nil }
                top[key] = String(decoding: text, as: UTF8.self)
            }
            if eat(0x2c) { continue }
            guard eat(0x7d) else { return nil }
            return Result(top: top, records: records)
        }
    }

    /// ⚠ Counts EVERY element, not just the objects. The index has to be the
    /// one `JSONSerialization`'s array has, or a record's members land on its
    /// neighbour.
    private mutating func recordArray() -> [Int: [String: String]]? {
        guard eat(0x5b) else { return nil }
        var out: [Int: [String: String]] = [:]
        if eat(0x5d) { return out }
        var n = 0
        while true {
            var text = [UInt8]()
            if peek() == 0x7b {
                guard let members = objectMembers(&text) else { return nil }
                out[n] = members
            } else {
                guard value(&text) else { return nil }
            }
            n += 1
            if eat(0x2c) { continue }
            guard eat(0x5d) else { return nil }
            return out
        }
    }

    /// An object, minified into `out`, that also reports each member's text.
    private mutating func objectMembers(_ out: inout [UInt8]) -> [String: String]? {
        guard eat(0x7b) else { return nil }
        out.append(0x7b)
        var members: [String: String] = [:]
        if eat(0x7d) {
            out.append(0x7d)
            return members
        }
        while true {
            guard let name = memberName(&out) else { return nil }
            guard eat(0x3a) else { return nil }
            out.append(0x3a)
            var text = [UInt8]()
            guard value(&text) else { return nil }
            out.append(contentsOf: text)
            members[name] = String(decoding: text, as: UTF8.self)
            if eat(0x2c) { out.append(0x2c); continue }
            guard eat(0x7d) else { return nil }
            out.append(0x7d)
            return members
        }
    }

    // MARK: Values, copied through as they are written

    private mutating func value(_ out: inout [UInt8]) -> Bool {
        switch peek() {
        case 0x7b: return object(&out)
        case 0x5b: return array(&out)
        case 0x22: return string(&out)
        case .some: return literal(&out)
        case .none: return false
        }
    }

    private mutating func object(_ out: inout [UInt8]) -> Bool {
        guard eat(0x7b) else { return false }
        out.append(0x7b)
        if eat(0x7d) {
            out.append(0x7d)
            return true
        }
        while true {
            guard peek() == 0x22, string(&out), eat(0x3a) else { return false }
            out.append(0x3a)
            guard value(&out) else { return false }
            if eat(0x2c) { out.append(0x2c); continue }
            guard eat(0x7d) else { return false }
            out.append(0x7d)
            return true
        }
    }

    private mutating func array(_ out: inout [UInt8]) -> Bool {
        guard eat(0x5b) else { return false }
        out.append(0x5b)
        if eat(0x5d) {
            out.append(0x5d)
            return true
        }
        while true {
            guard value(&out) else { return false }
            if eat(0x2c) { out.append(0x2c); continue }
            guard eat(0x5d) else { return false }
            out.append(0x5d)
            return true
        }
    }

    /// A string, escapes and all, copied byte for byte. `\uXXXX` needs no case
    /// of its own: the four hex digits are ordinary bytes and neither of the
    /// two characters this loop looks for.
    private mutating func string(_ out: inout [UInt8]) -> Bool {
        guard i < b.count, b[i] == 0x22 else { return false }
        out.append(0x22)
        i += 1
        while i < b.count {
            let c = b[i]
            if c == 0x5c {
                guard i + 1 < b.count else { return false }
                out.append(c)
                out.append(b[i + 1])
                i += 2
                continue
            }
            out.append(c)
            i += 1
            if c == 0x22 { return true }
        }
        return false
    }

    /// A number, `true`, `false` or `null`: everything up to the first byte
    /// that cannot be part of one.
    private mutating func literal(_ out: inout [UInt8]) -> Bool {
        space()
        let start = i
        while i < b.count {
            let c = b[i]
            if c == 0x2c || c == 0x7d || c == 0x5d || isSpace(c) { break }
            out.append(c)
            i += 1
        }
        return i > start
    }

    /// A member NAME, appended to `out` and returned decoded. An escape in a
    /// name is refused: see the note on the type.
    private mutating func memberName(_ out: inout [UInt8]) -> String? {
        guard peek() == 0x22 else { return nil }
        var raw = [UInt8]()
        guard string(&raw), raw.count >= 2, !raw.contains(0x5c) else { return nil }
        out.append(contentsOf: raw)
        return String(decoding: raw[1..<(raw.count - 1)], as: UTF8.self)
    }

    // MARK: Bytes

    private func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d }

    private mutating func space() {
        while i < b.count, isSpace(b[i]) { i += 1 }
    }

    private mutating func peek() -> UInt8? {
        space()
        return i < b.count ? b[i] : nil
    }

    private mutating func eat(_ c: UInt8) -> Bool {
        space()
        guard i < b.count, b[i] == c else { return false }
        i += 1
        return true
    }
}

enum SectionsError: Error {
    case tooManySections
    case sectionFull
    case tooManyMembers
    case tooLarge
    case unreadable

    /// Localisation suffix, identical on all three clients (`sections.err.*`).
    var code: String {
        switch self {
        case .tooManySections: return "too_many_sections"
        case .sectionFull: return "section_full"
        case .tooManyMembers: return "too_many_members"
        case .tooLarge: return "too_large"
        case .unreadable: return "unreadable"
        }
    }
}

/// Pure. No I/O, no SwiftUI, no UserDefaults: the transport is `SectionsVault`
/// and the cache is `SectionsStore`, and everything here is a function from
/// trees to trees so the merge can be reasoned about (and tested) on its own.
enum Sections {

    // MARK: - Reserved built-in ids

    /// Ids the three clients agree on, so the ORDER of the built-in sections
    /// syncs even though their membership is derived rather than stored.
    static let sysSaved = "sys.saved"
    static let sysFav = "sys.fav"
    static let sysCI = "sys.ci"
    static let sysGroups = "sys.groups"
    static let sysOnline = "sys.online"
    static let sysOffline = "sys.offline"
    static let sysArchive = "sys.archive"

    /// In the order they are listed, which is also their default order.
    static let builtinIDs = [sysSaved, sysFav, sysCI, sysGroups, sysOnline, sysOffline, sysArchive]

    /// Default `o` for a built-in with no record yet. A client that does not
    /// RENDER one of these (Saved Messages is a section on Android and a menu
    /// entry here) still keeps its record and writes it back: dropping it would
    /// delete another client's setting.
    static let defaultOrder: [String: Int] = [
        sysSaved: 0,
        sysFav: 1024,
        sysCI: 2048,
        sysGroups: 3072,
        sysOnline: 4096,
        sysOffline: 5120,
        sysArchive: 6144,
    ]

    static let orderStep = 1024

    // MARK: - Caps
    //
    // The island caps a slot at 256 KB decoded; the seal costs 1 + 12 + 16
    // bytes and pads to a 512-byte boundary with a 4-byte length prefix, so the
    // JSON ceiling is 261 628 bytes. Worst case at these caps is under 170 KB.

    static let maxSections = 64
    static let maxMembersPerSection = 512
    static let maxMembersTotal = 4096
    static let maxNameScalars = 32
    /// Refuse to write above this, after dropping expired tombstones. Never
    /// truncate, never silently drop a member, never hand the island a blob it
    /// will 413.
    static let maxWriteBytes = 200 * 1024
    static let tombstoneTTLMs = 90 * 24 * 3600 * 1000

    // MARK: - Member keys

    /// `p:<uin>` on our own island, `p:<uin>@<host>` for a peer on another one.
    static func peerKey(_ uin: Int, host: String? = nil) -> String {
        guard let host, !host.isEmpty else { return "p:\(uin)" }
        return "p:\(uin)@\(host.lowercased())"
    }

    /// `g:<id>` for a group on our island, `g:<remoteId>@<host>` for a foreign
    /// one. ⚠ `remoteId` is the id on ITS island, never the negative local
    /// alias.
    static func groupKey(_ remoteId: Int, host: String? = nil) -> String {
        guard let host, !host.isEmpty else { return "g:\(remoteId)" }
        return "g:\(remoteId)@\(host.lowercased())"
    }

    /// The member key for a group row, or nil when this device cannot name the
    /// group in a way another device would recognise.
    ///
    /// ⚠⚠ A foreign group's `id` in this client is the LOCAL ALIAS: a negative
    /// number handed out in first-sight order by `VisitedIslandsStore`,
    /// different on every device. Putting one in the slot would file this chat
    /// here and a different chat, or none, over there. This is the edge where
    /// alias becomes (remoteId, host).
    static func key(forGroupID id: Int) -> String? {
        guard VisitedIslandsStore.shared.isForeignGroupId(id) else { return groupKey(id) }
        guard let ref = VisitedIslandsStore.shared.refByAlias(id) else { return nil }
        return groupKey(ref.remoteId, host: ref.host)
    }

    static func key(forGroup g: RCQGroup) -> String? { key(forGroupID: g.id) }

    static func isGroupKey(_ key: String) -> Bool { key.hasPrefix("g:") }

    // MARK: - Accessors over the JSON tree

    static func emptyTree() -> SectionsTree {
        ["v": 1, "s": [[String: Any]](), "d": [String: Int](), "w": 0]
    }

    /// A JSON number, or nil for anything that is not one.
    ///
    /// ⚠ A JSON `true` / `false` decodes into an NSNumber as well
    /// (`__NSCFBoolean`), so a bare `as? NSNumber` reads `true` as 1. That
    /// alone would split the merge: `pickLarger` would take its NUMERIC
    /// branch for a boolean against a number, where web takes the
    /// stringify branch (`typeof true === 'number'` is false), and the two
    /// clients would resolve the same unknown-key conflict to different
    /// values, decide the other side is missing something of theirs, and
    /// rewrite the slot at each other until the island 429s. Nothing in v1
    /// writes a boolean anywhere in the tree; the merge is a forever
    /// contract with builds that might.
    static func num(_ v: Any?) -> Int? {
        guard let d = jsonNumber(v) else { return nil }
        // ⚠ `Int(Double)` TRAPS outside Int's range, and this tree arrives
        // from another device's blob, so a `1e300` written by anything at
        // all has to be dropped here rather than converted.
        guard d >= -9.007199254740992e15, d <= 9.007199254740992e15 else { return nil }
        return Int(d)
    }

    /// The same value as a Double, which is how the other two clients compare
    /// JSON numbers. Booleans and non-finite values are not numbers here.
    static func jsonNumber(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func str(_ r: [String: Any], _ k: String) -> String? { r[k] as? String }

    static func id(_ r: [String: Any]) -> String { (r["id"] as? String) ?? "" }

    /// A `key -> ms` map with everything that is not a finite number dropped.
    static func map(_ v: Any?) -> [String: Int] {
        guard let dict = v as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for (k, raw) in dict {
            if let n = num(raw) { out[k] = n }
        }
        return out
    }

    static func records(_ tree: SectionsTree) -> [[String: Any]] {
        (tree["s"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func version(_ tree: SectionsTree) -> Int { num(tree["v"]) ?? 0 }

    static func orderOf(_ r: [String: Any]) -> Int {
        if let o = num(r["o"]) { return o }
        return defaultOrder[id(r)] ?? (builtinIDs.count + 1) * orderStep
    }

    static func recordFor(_ tree: SectionsTree, _ sid: String) -> [String: Any]? {
        records(tree).first { id($0) == sid }
    }

    /// Every section this client should consider, built-ins included
    /// (synthesised at their default order when the slot has no record for
    /// them), in the one total order every device agrees on: `o` ascending,
    /// ties by id.
    static func orderedSections(_ tree: SectionsTree) -> [[String: Any]] {
        var out = records(tree).filter { str($0, "k") != "u" || str($0, "n") != nil }
        for bid in builtinIDs where !out.contains(where: { id($0) == bid }) {
            out.append(["id": bid, "k": "d", "o": defaultOrder[bid] ?? 0])
        }
        return out.sorted { lhs, rhs in
            let lo = orderOf(lhs), ro = orderOf(rhs)
            if lo != ro { return lo < ro }
            return utf8Less(id(lhs), id(rhs))
        }
    }

    static func userSections(_ tree: SectionsTree) -> [[String: Any]] {
        orderedSections(tree).filter { str($0, "k") == "u" }
    }

    /// The explicit PIN flag of a section, or nil when the slot says nothing
    /// about it. ⚠ nil is not "off": the Archive gate this client already
    /// shipped reads a missing flag as ON, which is what the migration write in
    /// `SectionsVault.sync` then makes explicit and propagates.
    static func pinFlag(_ tree: SectionsTree, _ sid: String) -> Bool? {
        guard let rec = recordFor(tree, sid), let p = num(rec["p"]) else { return nil }
        return p == 1
    }

    /// member key -> the id of the user section holding it. The merge
    /// guarantees one section per key, so this is a function, not a multimap.
    static func memberIndex(_ tree: SectionsTree) -> [String: String] {
        var out: [String: String] = [:]
        for r in records(tree) where str(r, "k") == "u" {
            for key in map(r["m"]).keys { out[key] = id(r) }
        }
        return out
    }

    static func membersOf(_ tree: SectionsTree, _ sid: String) -> [String] {
        Array(map(recordFor(tree, sid)?["m"]).keys)
    }

    static func totalMembers(_ tree: SectionsTree) -> Int {
        records(tree).reduce(0) { $0 + (str($1, "k") == "u" ? map($1["m"]).count : 0) }
    }

    // MARK: - Codec

    /// Decode a slot's plaintext.
    ///
    /// Returns nil for "this build cannot read it": a `v` above 1, or bytes
    /// that are not the tree at all. The caller then renders the built-in
    /// sections and NEVER writes the slot. ⚠ This is deliberately not the
    /// contacts slot's rule ("unknown version reads as empty"): that rule
    /// overwrites, and overwriting here would erase the sections the user made
    /// on a newer client.
    ///
    /// An absent slot (the island has nothing) is an empty tree, which is
    /// readable and writable.
    static func decode(_ plaintext: Data?) -> SectionsTree? {
        guard let plaintext else { return emptyTree() }
        guard let j = try? JSONSerialization.jsonObject(with: plaintext),
              let o = j as? [String: Any] else { return nil }
        guard num(o["v"]) == 1 else { return nil }
        guard let raw = o["s"] as? [Any] else { return nil }
        // The second walk over the same bytes, and the only place the member
        // ORDER of a value this build does not own can still be read. See
        // `SectionsRawJSON`. ⚠ Only when there is one to read: nothing this
        // build writes puts a container under a key it does not own, so the
        // tree every device actually carries today skips the walk entirely.
        let scan = carriesStranger(o) ? SectionsJSONScan.run(plaintext) : nil
        var out = keepText(o, scan?.top, structural: topStructural)
        out["v"] = 1
        out["s"] = raw.enumerated().compactMap { idx, e -> [String: Any]? in
            guard let r = e as? [String: Any], r["id"] is String else { return nil }
            return keepText(r, scan?.records[idx], structural: recordStructural)
        }
        out["d"] = map(o["d"])
        out["w"] = num(o["w"]) ?? 0
        return out
    }

    /// The keys this build reads as VALUES rather than as somebody else's JSON.
    /// Everything else on the object keeps its text, known field or not:
    /// `k`/`n`/`o`/`p`/`h` are scalars here, but a build that put an object in
    /// one of them still has to rank the same way on three clients, and they
    /// are decided by `pickLarger` on a stamp tie exactly like an unknown key.
    private static let topStructural: Set<String> = ["v", "s", "d", "w"]
    private static let recordStructural: Set<String> = ["id", "t", "m", "x"]

    private static func keepText(
        _ o: [String: Any], _ texts: [String: String]?, structural: Set<String>
    ) -> [String: Any] {
        guard let texts else { return o }
        var out = o
        for (k, v) in o where !structural.contains(k) {
            // Scalars have no member order to lose, and leaving them as
            // Foundation values keeps `num`, `str` and the numeric branch of
            // `pickLarger` reading them as values.
            guard isContainer(v), let t = texts[k] else { continue }
            out[k] = SectionsRawJSON(text: t, value: v)
        }
        return out
    }

    private static func isContainer(_ v: Any) -> Bool { v is [String: Any] || v is [Any] }

    /// Does this tree hold a container under a key this build does not own, at
    /// either of the two depths one can live at? Decoding asks it of the parsed
    /// bytes, to know whether the order is worth a second walk; `encode` asks
    /// it of the tree, to pick a writer.
    ///
    /// ⚠⚠ It counts a value that was NOT kept as text (a scan that gave up)
    /// exactly like one that was, and that is the point: if `encode` chose its
    /// writer by asking "is there a `SectionsRawJSON` in here", two trees that
    /// SAY the same thing could serialise differently, `sameContent` would
    /// answer "different" about a tree that is identical, and this device would
    /// put the slot on every single sync until the hour's budget ran out.
    /// Asked this way the answer depends on the content and nothing else.
    private static func carriesStranger(_ tree: [String: Any]) -> Bool {
        func stranger(_ v: Any) -> Bool { v is SectionsRawJSON || isContainer(v) }
        if tree.contains(where: { !topStructural.contains($0.key) && stranger($0.value) }) { return true }
        return records(tree).contains { r in
            r.contains { !recordStructural.contains($0.key) && stranger($0.value) }
        }
    }

    /// Canonical bytes: the keys THIS BUILD owns sorted, so two trees that SAY
    /// the same thing serialise the same way whatever order the dictionaries
    /// happened to hold, and a stranger's value written back exactly as it
    /// arrived.
    ///
    /// ⚠ The sort is not cosmetic and neither is the exception to it. Sorting
    /// is what makes `sameContent` an answer about content rather than about
    /// whichever order a Swift dictionary felt like; NOT sorting a stranger's
    /// value is what stops this client from reordering another build's object
    /// on every write, which the client that wrote it would then keep putting
    /// back.
    static func encode(_ tree: SectionsTree) -> Data {
        // Fast path, and the only one anything reaches today: with nothing but
        // this build's own keys in the tree there is no order to preserve, and
        // Foundation sorts a 4096-member map faster than we assemble one.
        // ⚠ Its `.sortedKeys` is not a byte sort (it folds case and reads digit
        // runs as numbers, so `p:4471@is2.rcq.app` files before `p:100200`),
        // which is fine here and nowhere else: these bytes are only ever
        // compared with other bytes this same function produced.
        guard carriesStranger(tree) else {
            return (try? JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])) ?? Data()
        }
        return Data(canonical(tree).utf8)
    }

    static func treeBytes(_ tree: SectionsTree) -> Int { encode(tree).count }

    // MARK: - Merge

    /// The whole of the conflict story, in one commutative, idempotent
    /// function.
    ///
    /// Both paths use it: the read path folds what the island serves into the
    /// cache (`cache = merge(cache, remote)`), and the write path folds the
    /// cache into what the island holds right now, inside the read-merge-write
    /// loop (`next = merge(decode(remote), cache)`).
    ///
    /// Per-FIELD last-writer-wins, so a rename on the phone and a reorder on
    /// the desktop both survive. Equal timestamps with different values fall
    /// back to "the larger value wins", which exists only to keep the function
    /// commutative and is never the interesting case.
    static func merge(_ a: SectionsTree, _ b: SectionsTree) throws -> SectionsTree {
        if version(a) > 1 || version(b) > 1 { throw SectionsError.unreadable }
        var d = map(a["d"])
        for (sid, ts) in map(b["d"]) { d[sid] = Swift.max(d[sid] ?? 0, ts) }

        var byID: [String: [String: Any]] = [:]
        for r in records(a) { byID[id(r)] = r }
        for r in records(b) {
            let k = id(r)
            byID[k] = byID[k].map { mergeRecord($0, r) } ?? r
        }

        // A tombstone only wins over a record nobody has touched since: a
        // section deleted here and renamed there comes back, named.
        var kept: [[String: Any]] = []
        for r in byID.values {
            if let dead = d[id(r)], dead >= newestStamp(r) { continue }
            kept.append(r)
        }

        // One chat lives in exactly one user section (§7). Two devices that
        // filed the same chat differently while offline are resolved here
        // rather than by whoever renders last: the larger add ts wins, ties go
        // to the smaller id, and the losers get a tombstone at the same ts so
        // the outcome survives the next merge from either side.
        var owner: [String: (id: String, ts: Int)] = [:]
        for r in kept where str(r, "k") != "d" {
            for (key, ts) in map(r["m"]) {
                if let cur = owner[key] {
                    if ts > cur.ts || (ts == cur.ts && utf8Less(id(r), cur.id)) {
                        owner[key] = (id(r), ts)
                    }
                } else {
                    owner[key] = (id(r), ts)
                }
            }
        }

        var out: [[String: Any]] = kept.map { r in
            guard str(r, "k") != "d" else { return r }
            var m = map(r["m"])
            var x = map(r["x"])
            var moved = false
            for (key, ts) in m {
                guard let own = owner[key], own.id != id(r) else { continue }
                moved = true
                m.removeValue(forKey: key)
                x[key] = Swift.max(x[key] ?? 0, ts)
            }
            guard moved else { return r }
            var copy = r
            copy["m"] = m
            copy["x"] = x
            return copy
        }
        out.sort { lhs, rhs in
            let lo = orderOf(lhs), ro = orderOf(rhs)
            if lo != ro { return lo < ro }
            return utf8Less(id(lhs), id(rhs))
        }

        var tree = mergeUnknown(a, b, known: ["v", "s", "d", "w"])
        tree["v"] = 1
        tree["s"] = out
        tree["d"] = d
        tree["w"] = Swift.max(num(a["w"]) ?? 0, num(b["w"]) ?? 0)
        return tree
    }

    /// The newest thing anyone claims to have USED this record for. A section
    /// tombstone older than this loses: somebody was working in the section
    /// after it was deleted, which is a resurrection on purpose.
    ///
    /// ⚠ Member TOMBSTONES (`x`) are deliberately not counted, and counting
    /// them was a real bug on the web: unticking one chat in a section's picker
    /// on an offline device stamps `x` and nothing else, so it read as "the
    /// section was touched" and brought a section deleted on the other device
    /// back from the dead, stably, carrying whatever was left in it. Emptying a
    /// section is not a reason to keep it. Adds (`m`) do count: filing a chat
    /// into a section is somebody using it, and the alternative loses their
    /// filing entirely.
    ///
    /// ⚠⚠ This is `max(t.*, m.*)` and the design doc (§2) says the same in the
    /// same words. Three clients each implement this line; two that disagree
    /// about one section do not merely render differently, they write the slot
    /// back and forth at each other until the island 429s.
    private static func newestStamp(_ r: [String: Any]) -> Int {
        let t = map(r["t"])
        var n = Swift.max(Swift.max(t["n"] ?? 0, t["o"] ?? 0), Swift.max(t["p"] ?? 0, t["h"] ?? 0))
        for ts in map(r["m"]).values { n = Swift.max(n, ts) }
        return n
    }

    private static func mergeRecord(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        let ta = map(a["t"]), tb = map(b["t"])
        // Unknown keys first, so the fields below always win over a same-named
        // stranger, and so a key only one side knows about survives untouched.
        var out = mergeUnknown(a, b, known: ["id", "k", "n", "o", "p", "h", "t", "m", "x"])
        out["id"] = id(a)
        if let k = present(pickLarger(a["k"], b["k"])) { out["k"] = k } else { out.removeValue(forKey: "k") }
        assignField(&out, "n", a["n"], b["n"], ta["n"] ?? 0, tb["n"] ?? 0)
        assignField(&out, "o", a["o"], b["o"], ta["o"] ?? 0, tb["o"] ?? 0)
        assignField(&out, "p", a["p"], b["p"], ta["p"] ?? 0, tb["p"] ?? 0)
        assignField(&out, "h", a["h"], b["h"], ta["h"] ?? 0, tb["h"] ?? 0)
        var t: [String: Int] = [:]
        for f in ["n", "o", "p", "h"] {
            let v = Swift.max(ta[f] ?? 0, tb[f] ?? 0)
            if v > 0 { t[f] = v }
        }
        out["t"] = t
        let merged = mergeMembers(map(a["m"]), map(a["x"]), map(b["m"]), map(b["x"]))
        if !merged.m.isEmpty || a["m"] != nil || b["m"] != nil { out["m"] = merged.m }
        if !merged.x.isEmpty || a["x"] != nil || b["x"] != nil { out["x"] = merged.x }
        return out
    }

    /// Add versus tombstone: the larger ts wins, and ON A TIE THE TOMBSTONE
    /// WINS. A removal racing an add leaves the chat out of the section, which
    /// the user can undo by adding it again; a chat resurrected into a section
    /// the user emptied is the version nobody can undo by hand.
    private static func mergeMembers(
        _ am: [String: Int], _ ax: [String: Int],
        _ bm: [String: Int], _ bx: [String: Int]
    ) -> (m: [String: Int], x: [String: Int]) {
        var adds = am
        for (k, ts) in bm { adds[k] = Swift.max(adds[k] ?? 0, ts) }
        var dels = ax
        for (k, ts) in bx { dels[k] = Swift.max(dels[k] ?? 0, ts) }
        var m: [String: Int] = [:]
        for (k, ts) in adds {
            if let gone = dels[k], gone >= ts { continue }
            m[k] = ts
        }
        return (m, dels)
    }

    private static func assignField(
        _ out: inout [String: Any], _ field: String,
        _ av: Any?, _ bv: Any?, _ at: Int, _ bt: Int
    ) {
        let v: Any? = at == bt ? pickLarger(av, bv) : (at > bt ? av : bv)
        // ⚠ `present`, not `if let`: a field that is `null` on the winning side
        // is a field that is NOT THERE, and writing the `null` back would leave
        // it on the record for the next merge to read as a value again.
        if let v = present(v) { out[field] = v } else { out.removeValue(forKey: field) }
    }

    /// Deterministic tie-break, identical on every client: numbers
    /// numerically, strings by UTF-8 byte order, 1 > 0, and anything else by
    /// its canonical JSON.
    ///
    /// ⚠⚠ A JSON `null` IS AN ABSENT VALUE HERE, on both sides, exactly like a
    /// key that is not there (design §2). It has to be spelled out because the
    /// platforms do not agree on their own, and because Swift is the one that
    /// gets it wrong for free: `NSNull` is a perfectly good NON-NIL `Any`, so
    /// `guard let` waves it through, `canonical` prints "null", and this client
    /// stores `"k": null` where the other two drop the key. `"null"` then beats
    /// almost every real value as well, since `n` (0x6e) is above every digit
    /// and above `"`. On `k`, which has NO timestamp and is therefore always
    /// decided right here, that silently deletes `k == "u"`: the section drops
    /// out of `userSections` and `memberIndex`, its filed chats fall back to
    /// their derived sections, and the client that kept the value and the one
    /// that kept the `null` disagree about the content of the tree forever,
    /// each concluding the island is missing something of its own and pushing,
    /// until the account's 240 puts an hour run out. Same on `n`/`o`/`p`/`h`
    /// when the stamps tie, and on every unknown key, which never has a stamp
    /// either.
    ///
    /// ⚠ Absent on BOTH sides still returns the other side rather than nil, so
    /// an unknown key that is `null` on both is carried through as `null` (§2.1:
    /// it is a stranger's value, not ours to delete). The two callers that own a
    /// FIELD drop it instead, through `present` below, which is what web's
    /// `if (v === undefined || v === null) delete out[field]` does.
    private static func pickLarger(_ a: Any?, _ b: Any?) -> Any? {
        guard let a = present(a) else { return b }
        guard let b = present(b) else { return a }
        // ⚠ Compared as Doubles, not through `num`: `num` truncates to Int,
        // and web compares JSON numbers as written, so 1.5 against 1 must
        // not tie here. Booleans are not numbers on either side and fall to
        // the canonical-JSON branch below, exactly as web's `JSON.stringify`
        // path does.
        if let x = jsonNumber(a), let y = jsonNumber(b) { return x >= y ? a : b }
        if let x = a as? String, let y = b as? String { return utf8Less(y, x) || x == y ? a : b }
        return utf8Less(canonical(b), canonical(a)) || canonical(a) == canonical(b) ? a : b
    }

    /// The value, or nil when it is not there: a missing key and a JSON `null`
    /// are the same thing to the merge. See `pickLarger`.
    private static func present(_ v: Any?) -> Any? {
        guard let v, !(v is NSNull) else { return nil }
        return v
    }

    /// One serialiser for both jobs, the blob (`encode`) and the tie-break
    /// (`pickLarger`), because they have to agree about what a tree says.
    ///
    /// A value this build does not own is its own text, member order and all
    /// (`SectionsRawJSON`); a dictionary this build built is sorted by UTF-8
    /// byte order, the same order the merge sorts ids and names in; everything
    /// else is printed by Foundation, which is where the spelling of a number
    /// and the escaping of a string come from.
    private static func canonical(_ v: Any) -> String {
        if let raw = v as? SectionsRawJSON { return raw.text }
        if let d = v as? [String: Any] {
            let body = d.keys.sorted(by: utf8Less).map { scalar($0) + ":" + canonical(d[$0]!) }
            return "{" + body.joined(separator: ",") + "}"
        }
        if let a = v as? [Any] { return "[" + a.map(canonical).joined(separator: ",") + "]" }
        return scalar(v)
    }

    /// One string, number, boolean or null, spelled the way Foundation spells
    /// it. Wrapped in an array and unwrapped again rather than asked for as a
    /// fragment, because that path is the one every OS this app runs on agrees
    /// about.
    private static func scalar(_ v: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [v], options: []),
              let s = String(data: data, encoding: .utf8), s.count >= 3 else { return "null" }
        return String(s.dropFirst().dropLast())
    }

    /// ⚠ UTF-8 byte order, NOT Swift's `<` on String, which compares by
    /// grapheme and disagrees with the other two clients about anything above
    /// the BMP. Section ids are ASCII, but section NAMES are not.
    static func utf8Less(_ a: String, _ b: String) -> Bool {
        var x = a.utf8.makeIterator()
        var y = b.utf8.makeIterator()
        while true {
            switch (x.next(), y.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let p?, let q?):
                if p != q { return p < q }
            }
        }
    }

    /// Keys neither this build nor the merge above knows about. They belong to
    /// a newer client and are carried through untouched (§2.1: patch, do not
    /// rebuild). A key both sides carry with different values is settled by the
    /// same deterministic tie-break the fields use, because an unknown key has
    /// no timestamp to compare and the merge still has to be commutative.
    private static func mergeUnknown(
        _ a: [String: Any], _ b: [String: Any], known: [String]
    ) -> [String: Any] {
        let skip = Set(known)
        var out: [String: Any] = [:]
        for (k, v) in a where !skip.contains(k) { out[k] = v }
        for (k, v) in b where !skip.contains(k) {
            out[k] = out[k].flatMap { pickLarger($0, v) } ?? v
        }
        return out
    }

    /// Do these two trees SAY the same thing? `merge(x, x)` is the identity on
    /// content and puts every record in the one order all merge output has, so
    /// this is a byte comparison with the serialisation noise taken out.
    ///
    /// ⚠ Use this, not a raw byte comparison, to decide whether to WRITE. A
    /// blob written by the desktop or by Android orders its JSON their way, and
    /// a byte comparison then says "different" about a tree that is identical:
    /// this client rewrites it in its own order, the other client rewrites it
    /// back, and two devices that both do that spend the account's 240 puts an
    /// hour telling each other nothing.
    static func sameContent(_ a: SectionsTree, _ b: SectionsTree) -> Bool {
        guard let na = try? merge(a, a), let nb = try? merge(b, b) else { return false }
        return encode(na) == encode(nb)
    }

    // MARK: - Writes. Every one returns a NEW tree and mutates nothing.

    /// ⚠ Clamp by SCALARS, not by UTF-16 units and not by bytes. The
    /// pinned-message 422 of 22.08 was exactly this: a slot measured in one
    /// unit and filled in another, on all three clients at once.
    static func clampName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = String.UnicodeScalarView()
        var n = 0
        for s in trimmed.unicodeScalars {
            if n >= maxNameScalars { break }
            out.append(s)
            n += 1
        }
        return String(out)
    }

    /// 8 lower-case hex from a CSPRNG.
    static func newSectionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<4).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// ⚠ The one place a record is edited. It copies the record and hands the
    /// copy to `edit`, so every key this build does not know about rides along.
    /// A record for a built-in that the slot has never carried is created here,
    /// which is how `sys.archive` gets a `p` without anybody seeding the tree.
    private static func patch(
        _ tree: SectionsTree, _ sid: String, _ now: Int,
        _ edit: ([String: Any]) -> [String: Any]
    ) -> SectionsTree {
        var found = false
        var s = records(tree).map { r -> [String: Any] in
            guard id(r) == sid else { return r }
            found = true
            return edit(r)
        }
        if !found { s.append(edit(["id": sid])) }
        var out = tree
        out["s"] = s
        out["w"] = now
        return out
    }

    /// ⚠ The cap counts the sections that EXIST, not the ones that ever
    /// existed. Counting tombstones too dead-ends the feature on pure churn:
    /// make and delete 64 sections while trying out names and the next "new
    /// section" is refused with "that is as many sections as one account can
    /// hold" while the screen shows none at all, on every device of the
    /// account, for 90 days, with no user action that clears it. Tombstones are
    /// bounded instead, by `dropExpired`, which keeps the newest 64 of them.
    static func createSection(_ tree: SectionsTree, name: String, now: Int = nowMs()) throws -> SectionsTree {
        if records(tree).count >= maxSections { throw SectionsError.tooManySections }
        let top = orderedSections(tree).reduce(0) { Swift.max($0, orderOf($1)) }
        let rec: [String: Any] = [
            "id": newSectionID(),
            "k": "u",
            "n": clampName(name),
            "o": top + orderStep,
            "t": ["n": now, "o": now],
            "m": [String: Int](),
            "x": [String: Int](),
        ]
        var out = tree
        out["s"] = records(tree) + [rec]
        out["w"] = now
        return out
    }

    static func renameSection(_ tree: SectionsTree, _ sid: String, name: String, now: Int = nowMs()) -> SectionsTree {
        patch(tree, sid, now) { r in
            var out = r
            out["n"] = clampName(name)
            var t = map(r["t"]); t["n"] = now
            out["t"] = t
            return out
        }
    }

    static func setPinned(_ tree: SectionsTree, _ sid: String, on: Bool, now: Int = nowMs()) -> SectionsTree {
        patch(tree, sid, now) { r in
            var out = r
            if out["k"] == nil { out["k"] = builtinIDs.contains(sid) ? "d" : "u" }
            out["p"] = on ? 1 : 0
            var t = map(r["t"]); t["p"] = now
            out["t"] = t
            return out
        }
    }

    /// Delete a user section. The chats are not touched: they fall back into
    /// their derived sections on the next render.
    static func deleteSection(_ tree: SectionsTree, _ sid: String, now: Int = nowMs()) -> SectionsTree {
        var d = map(tree["d"])
        d[sid] = now
        var out = tree
        out["s"] = records(tree).filter { id($0) != sid }
        out["d"] = d
        out["w"] = now
        return out
    }

    /// Apply a whole new order at once (a move, or a renormalise). Every
    /// section that MOVES gets `t.o = now`; the ones that did not move are left
    /// alone so they do not stamp over another device's reorder.
    static func setOrder(_ tree: SectionsTree, _ orders: [String: Int], now: Int = nowMs()) -> SectionsTree {
        var out = tree
        for (sid, o) in orders {
            if let cur = recordFor(out, sid), orderOf(cur) == o, cur["o"] != nil { continue }
            out = patch(out, sid, now) { r in
                var rec = r
                if rec["k"] == nil { rec["k"] = builtinIDs.contains(sid) ? "d" : "u" }
                rec["o"] = o
                var t = map(r["t"]); t["o"] = now
                rec["t"] = t
                return rec
            }
        }
        out["w"] = now
        return out
    }

    /// File chats into a section. One write for the whole picker sheet.
    ///
    /// A key that sits in another user section is moved: removed there with a
    /// tombstone at the same ts, added here. That is the same outcome `merge`
    /// would compute, done locally so the list does not flicker through a state
    /// where the chat is in two places.
    static func addMembers(_ tree: SectionsTree, _ sid: String, keys: [String], now: Int = nowMs()) throws -> SectionsTree {
        let cur = map(recordFor(tree, sid)?["m"])
        let fresh = keys.filter { cur[$0] == nil }
        if cur.count + fresh.count > maxMembersPerSection { throw SectionsError.sectionFull }
        if totalMembers(tree) + fresh.count > maxMembersTotal { throw SectionsError.tooManyMembers }
        var out = tree
        for key in fresh {
            if let holder = memberIndex(out)[key], holder != sid {
                out = removeMemberFrom(out, holder, key: key, now: now)
            }
        }
        return patch(out, sid, now) { r in
            var rec = r
            if rec["k"] == nil { rec["k"] = "u" }
            var m = map(r["m"])
            var x = map(r["x"])
            for key in keys {
                if m[key] == nil { m[key] = now }
                x.removeValue(forKey: key)
            }
            rec["m"] = m
            rec["x"] = x
            return rec
        }
    }

    static func removeMemberFrom(_ tree: SectionsTree, _ sid: String, key: String, now: Int = nowMs()) -> SectionsTree {
        patch(tree, sid, now) { r in
            var rec = r
            var m = map(r["m"])
            var x = map(r["x"])
            m.removeValue(forKey: key)
            x[key] = now
            rec["m"] = m
            rec["x"] = x
            return rec
        }
    }

    /// Take a chat out of whatever section holds it. This is the ONLY pruning
    /// there is, and it happens on an explicit local action: removing a
    /// contact, leaving a group, deleting a cross-island peer.
    ///
    /// ⚠ Never prune because a chat did not resolve while rendering. A second
    /// device that has not synced yet, or one failed roster fetch, would then
    /// delete the membership for the whole account. That is the hazard the
    /// contacts mirror was written around, and it is worse here: there is no
    /// server-side list to rebuild from.
    static func forgetMember(_ tree: SectionsTree, key: String, now: Int = nowMs()) -> SectionsTree? {
        guard let holder = memberIndex(tree)[key] else { return nil }
        return removeMemberFrom(tree, holder, key: key, now: now)
    }

    /// Stamp the tree as touched without changing anything anybody can see.
    /// See the write-timing note on `SectionsVault.forgetSectionMember`: it is
    /// not cosmetic.
    static func touchTree(_ tree: SectionsTree, now: Int = nowMs()) -> SectionsTree {
        var out = tree
        out["w"] = now
        return out
    }

    /// Drop expired tombstones. Called before every write, never on read: a
    /// read that pruned would fight with a device whose clock is behind.
    ///
    /// Age is not the only bound. Churn inside the 90 days is: a section whose
    /// membership is edited every day accumulates an `x` entry per removal, and
    /// a slot that grows past `maxWriteBytes` stops being writable at all,
    /// which is a worse failure than forgetting the oldest removal. So both
    /// maps are also capped by COUNT, newest kept.
    static func dropExpired(_ tree: SectionsTree, now: Int = nowMs()) -> SectionsTree {
        var out = tree
        out["d"] = newestFew(map(tree["d"]), now: now, cap: maxSections)
        out["s"] = records(tree).map { r -> [String: Any] in
            let x = map(r["x"])
            let keep = newestFew(x, now: now, cap: maxMembersPerSection)
            if keep.count == x.count { return r }
            var rec = r
            rec["x"] = keep
            return rec
        }
        return out
    }

    /// The `cap` newest entries of a tombstone map that are also inside the
    /// TTL. Ties by key, so every client drops the same ones.
    private static func newestFew(_ m: [String: Int], now: Int, cap: Int) -> [String: Int] {
        let live = m.filter { now - $0.value <= tombstoneTTLMs }
        guard live.count > cap else { return live }
        let ranked = live.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            return utf8Less(a.key, b.key)
        }
        var out: [String: Int] = [:]
        for (k, ts) in ranked.prefix(cap) { out[k] = ts }
        return out
    }

    /// The last gate before the seal. Refuse rather than truncate: a slot the
    /// island 413s is a slot that stops syncing for everyone.
    static func assertWritable(_ tree: SectionsTree) throws {
        if treeBytes(tree) > maxWriteBytes { throw SectionsError.tooLarge }
    }

    static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}

/// The sections slot: read it, merge it, write it back.
///
/// The transport is `VaultClient` and is not reinvented here; what this adds is
/// the two halves the read-merge-write loop takes: the merge (`Sections`, pure)
/// and the rollback floor (`VaultFloor`, keyed by slot name).
///
/// Both directions go through the SAME merge:
///   read   cache = merge(cache, remote)
///   write  next  = merge(remote, cache),  nothing to send when they agree
@MainActor
enum SectionsVault {
    private static let log = OSLog(subsystem: "app.rcq.client", category: "SectionsVault")

    /// A burst of edits ends in one write, not one per gesture. 240 puts an
    /// account per hour is the budget; a reorder is the only gesture that can
    /// produce a burst.
    private static let pushDebounce: TimeInterval = 0.8

    /// Set for the rest of the session when the island serves a version below
    /// the floor, or when another device retired this derivation
    /// (`vault_reset`). Keyed by account so an account switch clears it.
    ///
    /// ⚠ A String, not an `Optional<UUID>`. An install whose active account id
    /// is not set answers nil, and `nil == nil` would read as "this account is
    /// stopped" from the very first call.
    private static var stoppedFor: String?

    private static func accountKey() -> String {
        AppGroup.readActiveAccountID()?.uuidString ?? "none"
    }

    private static var pushTimer: Task<Void, Never>?
    private static var pushing = false
    private static var pushAgain = false

    /// Stop the slot for this session, from outside (`vault_reset`).
    static func retire() {
        stoppedFor = accountKey()
        pushTimer?.cancel()
        pushTimer = nil
    }

    /// Account switch inside one process.
    static func resetSyncState() {
        stoppedFor = nil
        pushTimer?.cancel()
        pushTimer = nil
    }

    private static func stopped() -> Bool { stoppedFor == accountKey() }

    /// Nothing about sections happens without a vault, and nothing at all
    /// happens in a decoy session.
    private static func identity() -> (ik: Data, slot: String)? {
        guard !PanicPINService.shared.isDecoy else { return nil }
        guard AppState.shared.serverCapabilities.vault else { return nil }
        guard !stopped() else { return nil }
        guard let ik = KeychainStore.data(KeychainStore.Keys.identityPriv) else { return nil }
        return (ik, Vault.slotId(identityPriv: ik, name: Vault.sections))
    }

    /// Read the island's copy and fold it into the cache. The read path: boot,
    /// a `vault_changed` nudge, and every socket reconnect (the nudge is
    /// pub/sub with no replay, so a device whose socket was down never hears
    /// it).
    ///
    /// Never throws. Returns the tree now in the cache, or nil when the slot
    /// was unreadable or the island has no vault.
    @discardableResult
    static func sync() async -> SectionsTree? {
        guard let (ik, slot) = identity() else { return nil }
        do {
            let cur = try await VaultClient.get(slot)
            if cur.version < VaultFloor.lastSeen(slot) {
                stoppedFor = accountKey()
                os_log("island served a version below the floor; sync stopped for this session", log: log, type: .error)
                return nil
            }
            var plain: Data?
            if let b64 = cur.blob, let raw = Data(base64Encoded: b64) {
                plain = try Vault.open(identityPriv: ik, slot: slot, version: cur.version, blob: raw)
            }
            guard let remote = Sections.decode(plain) else {
                // A newer format. Render the built-ins, write nothing, and do
                // not touch the cache: whatever is in there was written by this
                // build and is still the best it can show.
                os_log("slot is newer than this build; not syncing", log: log, type: .info)
                return nil
            }
            VaultFloor.remember(slot, cur.version)
            let next = try Sections.merge(SectionsStore.shared.tree, remote)
            SectionsStore.shared.save(next)
            migrateArchiveGate(next)
            // ⚠ AND THIS IS THE RETRY. A write that failed (offline, a 429
            // against the 240-an-hour budget, a 5xx, a conflict loop) leaves an
            // edit sitting in the cache and nothing else was ever going to send
            // it. The read path is the one thing that runs on boot, on the
            // nudge and on every reconnect, so it is where the outstanding
            // write belongs. The condition is the merge's own answer, not a
            // dirty flag: if folding the cache into what the island holds
            // changes what the island holds, the island is missing something of
            // ours.
            if !Sections.sameContent(next, remote) { Task { await push() } }
            return next
        } catch {
            os_log("sections read failed: %{public}@", log: log, type: .info, String(describing: error))
            return nil
        }
    }

    /// iOS gates Archive whenever a PIN is configured, and always has, with no
    /// flag behind it. On the first read of the slot, a client with a PIN
    /// configured and no OPINION about `sys.archive` writes `sys.archive` with
    /// `p:1`. That preserves today's behaviour on this device and propagates it
    /// to the other clients, which is the right answer and not an accident.
    ///
    /// ⚠⚠ The condition is the absent FLAG, not the absent RECORD, and the
    /// difference is a permanent disagreement about the same account. A record
    /// for Archive appears the moment anything writes an order for it, and
    /// `setOrder`/`placeSection` write `k`, `o` and `t.o` and no `p` at all: a
    /// drag of the Archive row on the web creates `sys.archive` with no
    /// opinion. Keyed on the record, the migration is then skipped forever
    /// exactly when it is needed, and this device reads the missing flag as
    /// GATED (`ContactListView.sectionPinned`) while the web and Android read
    /// it as open. Nothing in the UI can settle it either: a locked header
    /// shows no section menu.
    private static func migrateArchiveGate(_ tree: SectionsTree) {
        guard PanicPINService.shared.isConfigured, !PanicPINService.shared.isDecoy else { return }
        guard Sections.pinFlag(tree, Sections.sysArchive) == nil else { return }
        _ = try? mutate({ Sections.setPinned($0, Sections.sysArchive, on: true) }, deferred: true)
    }

    /// Apply a local edit and get it to the island.
    ///
    /// The cache is updated first and synchronously, because the list has to
    /// repaint at the speed of the tap; the write goes behind it. `deferred`
    /// coalesces a burst (moving sections about) into one put.
    ///
    /// Throws `SectionsError` from the caps before anything is saved, so the UI
    /// can say "this section is full" instead of writing a blob the island will
    /// refuse.
    @discardableResult
    static func mutate(_ edit: (SectionsTree) throws -> SectionsTree, deferred: Bool = false) throws -> SectionsTree {
        let next = try edit(SectionsStore.shared.tree)
        try Sections.assertWritable(next)
        SectionsStore.shared.save(next)
        SectionsStore.shared.markPending(true)
        if deferred { schedulePush() } else { Task { await push() } }
        return next
    }

    private static func schedulePush() {
        pushTimer?.cancel()
        pushTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pushDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            pushTimer = nil
            await push()
        }
    }

    /// One write in flight at a time. Two overlapping read-merge-write loops on
    /// the same slot are legal (the island's 409 sorts them out) but they burn
    /// the hourly budget for nothing. An edit that lands while a put is in the
    /// air queues exactly one more round behind it.
    static func push() async {
        if pushing { pushAgain = true; return }
        pushing = true
        repeat {
            pushAgain = false
            await pushOnce()
        } while pushAgain
        pushing = false
    }

    private static func pushOnce() async {
        guard let (ik, slot) = identity() else { return }
        let now = Sections.nowMs()
        var floor = VaultFloor.lastSeen(slot)
        do {
            for _ in 0..<5 {
                let cur = try await VaultClient.get(slot)
                if cur.version < floor {
                    stoppedFor = accountKey()
                    os_log("island served a version below the floor; sync stopped for this session", log: log, type: .error)
                    return
                }
                var plain: Data?
                if let b64 = cur.blob, let raw = Data(base64Encoded: b64) {
                    plain = try Vault.open(identityPriv: ik, slot: slot, version: cur.version, blob: raw)
                }
                guard let remote = Sections.decode(plain) else {
                    // Unreadable (a newer `v`, or bytes that are not the tree):
                    // writing would erase whatever wrote it.
                    os_log("slot is newer than this build; not writing", log: log, type: .info)
                    return
                }
                let folded = try Sections.merge(remote, SectionsStore.shared.tree)
                let next = Sections.dropExpired(folded, now: now)
                if Sections.sameContent(next, remote) {
                    VaultFloor.remember(slot, cur.version)
                    let settled = try Sections.merge(SectionsStore.shared.tree, remote)
                    SectionsStore.shared.save(settled)
                    SectionsStore.shared.markPending(false)
                    return
                }
                try Sections.assertWritable(next)
                let sealed = try Vault.seal(
                    identityPriv: ik, slot: slot, version: cur.version + 1,
                    plaintext: Sections.encode(next)
                )
                let w = try await VaultClient.put(slot, blob: sealed.base64EncodedString(), basedOn: cur.version)
                if let v = w.version {
                    VaultFloor.remember(slot, v)
                    // The island's copy now includes ours, so the cache becomes
                    // the merged tree rather than the local one. Fold rather
                    // than replace: a tap that landed while the put was in the
                    // air must not be thrown away.
                    let settled = try Sections.merge(SectionsStore.shared.tree, next)
                    SectionsStore.shared.save(settled)
                    SectionsStore.shared.markPending(false)
                    return
                }
                // Stale: somebody else's write landed between our read and ours.
                floor = Swift.max(floor, w.current)
            }
            os_log("conflict loop", log: log, type: .error)
        } catch let e as SectionsError {
            os_log("refused to write: %{public}@", log: log, type: .error, e.code)
        } catch {
            // Offline, or the island is unhappy (a 5xx, or a 429 against the
            // 240-an-hour put budget). The cache keeps the edit and `sync()`
            // sends it: it runs on boot, on the `vault_changed` nudge and on
            // every socket reconnect, and it pushes whenever folding the cache
            // into the island's copy would change the island's copy.
            os_log("write failed; the next sync will send it", log: log, type: .info)
        }
    }

    /// Take a chat out of whatever section holds it, because it is going away
    /// on THIS device on purpose: a contact removed, a group left, a
    /// cross-island peer deleted. Writes the member tombstone in the same
    /// operation.
    ///
    /// ⚠ This is the only pruning there is. Nothing prunes because a chat
    /// failed to render: one failed roster fetch would then empty the account's
    /// sections everywhere.
    ///
    /// ⚠⚠ WRITE TIMING IS THE SIDE CHANNEL HERE, not the blob. This runs
    /// directly after `DELETE /contacts/{uin}`, `POST /groups/{id}/leave` and
    /// the cross-island equivalent. If it wrote the slot ONLY when the chat
    /// turned out to be filed, the island could read its own request log: a
    /// delete followed within a moment by a put on this account's second,
    /// rarely-written slot says "that uin was in one of their sections", and a
    /// delete followed by nothing says the opposite. For the common account
    /// whose only user section is the PIN-gated one, that reconstructs the
    /// hidden membership one removal at a time, which is exactly what sealing
    /// it was for.
    ///
    /// So the write is unconditional whenever the account has any user section
    /// at all: a removal that changed nothing still stamps `w` and still puts.
    /// It is deferred as well, so the put does not sit against the API call in
    /// the log. An account with no user sections writes nothing and has nothing
    /// to hide.
    static func forgetSectionMember(_ key: String?) {
        guard let key else { return }
        guard !Sections.userSections(SectionsStore.shared.tree).isEmpty else { return }
        _ = try? mutate({ tree in
            Sections.forgetMember(tree, key: key) ?? Sections.touchTree(tree)
        }, deferred: true)
    }
}
