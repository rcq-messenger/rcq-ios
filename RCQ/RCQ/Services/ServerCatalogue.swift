import Foundation

// The public RCQ island catalogue: its shape, where it is read from, and the
// rules for reading a file somebody edits by hand.
//
// ⚠ Foundation only, on purpose, like CrossIslandLogic.swift. No URLSession,
// no UserDefaults, no main actor: the bytes come in as a value and the answer
// goes out as a value. The app has no unit-test target, so this file is the
// part Tools/ServerCatalogueCheck compiles on its own and drives case by case;
// keep anything that touches the app in ServerDirectoryService instead.
//
// ⚠ DISPLAY ONLY. Nothing here is a trust decision. The file says which
// islands to DRAW in the picker and what to write under their names; it never
// says which island to register on, which certificate to accept, or which
// relay to dial. The list the backup toggle walks is a separate Ed25519-signed
// file with its own key role (Multihome.autoIslandsURL), precisely because
// that one steers a silent registration and this one does not.

/// One entry in the public RCQ instance directory. Schema mirrors
/// `servers.json` in `rcq-messenger/rcq-servers`, which is also what
/// `rcq.app/servers.json` serves. Don't add fields here without bumping the
/// schema version on the directory side too.
///
/// ⚠⚠ ONLY `url` AND `name` ARE REQUIRED, and every other field has a
/// default, because this file is edited by hand and a missing key used to cost
/// the WHOLE catalogue: `operator_contact` was declared non-optional here, the
/// Falcon island landed on 15.09 without one, `JSONDecoder` rejected the file
/// whole, and the service silently kept its cached list, so the island the
/// team had just published never appeared in any picker on iOS. Tolerance is
/// per entry (see `ServerDirectory`): one unreadable row is dropped and named
/// in the log, the rest of the deck still draws.
struct ServerEntry: Codable, Identifiable, Hashable {
    let url: String
    let name: String
    let description: String
    let region: String
    let operatorContact: String
    let addedAt: String
    /// The island's logo, MIRRORED ON THE SITE rather than read from the island
    /// itself. An operator's logo lives at `<island>/server/logo`, and fetching
    /// it from there would hand this device's address to every island in the
    /// catalogue the moment the picker opened, including the ones somebody
    /// scrolls past and never joins. The catalogue and the paintings already
    /// come from rcq.app; one more file from that host says nothing new.
    /// Absent for an island whose operator never set one, which is normal.
    let logo: String?

    var id: String { url }

    /// Best-effort hostname for compact display ("api.rcq.app" from the
    /// full URL). Falls back to the raw URL if the parser can't make
    /// sense of it, which only happens on a malformed catalogue entry.
    var displayHost: String {
        URL(string: url)?.host ?? url
    }

    enum CodingKeys: String, CodingKey {
        case url
        case name
        case description
        case region
        case operatorContact = "operator_contact"
        case addedAt = "added_at"
        case logo
    }
}

// The tolerant reader for one entry. In an EXTENSION on purpose: an
// initializer written inside the struct would suppress the memberwise one,
// which `AddAccountSheet.typedEntry` and `ServerDirectoryService.flagship`
// both build entries with.
extension ServerEntry {
    /// Reads one row of the catalogue.
    ///
    /// `url` and `name` must be present, be strings and be non-blank: a row
    /// with no address is not an island, and a row with no name draws a blank
    /// card nobody can tell apart from a loading one. Everything else is
    /// best-effort, and absent, null and wrong-typed all land on the same
    /// default, because the failure this guards against is a hand-edited file
    /// and not a hostile one (the file is display-only, see the file header).
    ///
    /// Throws only for the two required fields, so the caller can drop this
    /// row alone and keep the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let url = Self.text(c, .url)
        guard !url.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .url, in: c, debugDescription: "url missing or blank"
            )
        }
        // A row with no name is KEPT and named by its host, the way Android
        // (IslandCatalog.kt) and web (island-catalog.ts) do. Dropping it would
        // repeat, one field over, the bug this file exists to end: an island
        // the catalogue lists never reaching the picker.
        var name = Self.text(c, .name)
        if name.isEmpty { name = URL(string: url)?.host ?? url }
        self.url = url
        self.name = name
        self.description = Self.text(c, .description)
        self.region = Self.text(c, .region)
        self.operatorContact = Self.text(c, .operatorContact)
        self.addedAt = Self.text(c, .addedAt)
        // An empty logo string is no logo, not a URL of length zero: it would
        // reach `IslandArtView(logoURL:)` as a request for a blank address.
        let logo = Self.text(c, .logo)
        self.logo = logo.isEmpty ? nil : logo
    }

    /// One string field, trimmed, with absent, null and wrong-typed all
    /// reading as "". `try?` covers all three on purpose: see above.
    private static func text(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        guard let raw = try? c.decode(String.self, forKey: key) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Top-level shape of the catalogue file. `version` lets us evolve the
/// schema without breaking older clients; clients pinning to schema=1
/// can ignore unknown fields gracefully.
///
/// Decodable only, never encoded: the cache keeps the bytes the source served,
/// not a re-serialization of this.
struct ServerDirectory: Decodable {
    let version: Int
    let updatedAt: String
    let servers: [ServerEntry]
    /// One line per entry this read had to drop, in file order, for the log.
    /// NOT a field of the file: a byproduct of reading it, and empty on a
    /// clean one, which is the normal case. The service logs these so a
    /// picker that is one island short says why in Console rather than
    /// looking like a network problem.
    let skipped: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case servers
    }

    /// Reads the file. Throws only when the top level is unusable: not a JSON
    /// object, or no `servers` array in it. A missing `version` or
    /// `updated_at` is a default, and an unreadable ENTRY is a skip, never a
    /// throw.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        self.updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""

        var rows = try c.nestedUnkeyedContainer(forKey: .servers)
        var kept: [ServerEntry] = []
        var dropped: [String] = []
        var index = 0
        while !rows.isAtEnd {
            index += 1
            // ⚠ A null element has to be taken off the container with
            // `decodeNil`. Decoding it as a type throws WITHOUT advancing the
            // container's index, and the `while` above would then spin
            // forever on it.
            if try rows.decodeNil() {
                dropped.append("entry \(index): null")
                continue
            }
            do {
                let row = try rows.decode(CatalogueRow.self)
                if let entry = row.entry {
                    kept.append(entry)
                } else {
                    dropped.append("entry \(index)\(row.label): \(row.why)")
                }
            } catch {
                // `CatalogueRow` catches its own failures, so nothing should
                // reach here. If something does, the index has not advanced
                // and the loop cannot continue: losing the tail beats
                // spinning. Belt and braces.
                dropped.append("entry \(index) and the rest of the file: unreadable")
                break
            }
        }
        self.servers = kept
        self.skipped = dropped
    }
}

/// One element of `servers`, read so that a failure is a value rather than a
/// thrown error: this is what makes the tolerance per entry.
private struct CatalogueRow: Decodable {
    let entry: ServerEntry?
    /// Why the entry is nil. Empty when it isn't.
    let why: String
    /// ` (https://host)` when the row at least carried a readable url, "" when
    /// it did not. "the entry for sslip.io" is a better bug report than "the
    /// sixth entry".
    let label: String

    init(from decoder: Decoder) throws {
        do {
            self.entry = try ServerEntry(from: decoder)
            self.why = ""
            self.label = ""
        } catch {
            self.entry = nil
            self.why = CatalogueRow.reason(error)
            let url = (try? decoder.container(keyedBy: ServerEntry.CodingKeys.self))
                .flatMap { try? $0.decode(String.self, forKey: .url) } ?? ""
            self.label = url.isEmpty ? "" : " (\(url))"
        }
    }

    /// A short sentence for the log. `ServerEntry` throws `dataCorrupted` with
    /// its own wording for the two required fields; the other cases can only
    /// come from asking a non-object for a keyed container.
    private static func reason(_ error: Error) -> String {
        switch error as? DecodingError {
        case .dataCorrupted(let ctx): return ctx.debugDescription
        case .typeMismatch: return "not a JSON object"
        case .valueNotFound: return "null"
        case .keyNotFound(let key, _): return "no \(key.stringValue)"
        default: return "unreadable"
        }
    }
}

/// Where the catalogue comes from and how its rows are ordered.
enum ServerCatalogue {
    /// Hardcoded last-resort entry. Used when neither network nor cache
    /// can produce a list. Has to match an actual reachable backend so
    /// a no-network fresh install still onboards successfully.
    static let flagship = ServerEntry(
        url: "https://api.rcq.app",
        name: "RCQ",
        description: "Default backend operated by the RCQ maintainer.",
        region: "EU",
        operatorContact: "hello@rcq.app",
        addedAt: "2026-05-28",
        logo: nil
    )

    /// The two places the catalogue is read from, tried in this order until
    /// one serves a usable list.
    ///
    /// ⚠ rcq.app FIRST and GitHub as the fallback, and the order is the whole
    /// point: `raw.githubusercontent.com` is blocked on exactly the networks
    /// where this screen matters most, because the picker is where a person
    /// finds the island that is NOT blocked. rcq.app is reachable there, and
    /// it is already the only source the web reads
    /// (web-chat/src/lib/island-catalog.ts) and the first one Android reads
    /// (IslandCatalog.kt), so iOS was the last client asking a blocked host
    /// first. GitHub stays as the second road for the hour after a site
    /// deploy, when the two copies can disagree.
    ///
    /// ⚠ The two copies DO disagree, which is why the tolerant reader above
    /// and this order had to land together: on 19.09 the GitHub copy carried
    /// the Falcon entry patched with an empty `operator_contact` while the
    /// site copy still had no such key at all, so a strict reader pointed at
    /// rcq.app would have dropped the entire catalogue.
    ///
    /// Neither host is an island: both are fetched with
    /// `allowTunnelFallback: false` (ride a tunnel that is already up, never
    /// raise one because a third party is unreachable) and without the island
    /// trust delegate, which `IslandTrust` explicitly excludes rcq.app from.
    static let sources: [URL] = [
        URL(string: "https://rcq.app/servers.json")!,
        URL(string: "https://raw.githubusercontent.com/rcq-messenger/rcq-servers/main/servers.json")!,
    ]

    /// Reads the catalogue bytes. Throws when the file as a whole is unusable;
    /// unreadable individual entries come back in `ServerDirectory.skipped`.
    static func parse(_ data: Data) throws -> ServerDirectory {
        try JSONDecoder().decode(ServerDirectory.self, from: data)
    }

    /// The catalogue with the flagship at the front.
    ///
    /// ⚠ The file's own order is whatever somebody last appended, so the
    /// island every build points at was landing third in the deck and the
    /// picker opened on a stranger's island (founder, 24.08). Android and the
    /// console keep the same invariant, and so does the website's hero.
    static func flagshipFirst(_ list: [ServerEntry]) -> [ServerEntry] {
        let flagshipURL = flagship.url
        guard let idx = list.firstIndex(where: {
            $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == flagshipURL
        })
        else { return list }
        var out = list
        let entry = out.remove(at: idx)
        out.insert(entry, at: 0)
        return out
    }
}
