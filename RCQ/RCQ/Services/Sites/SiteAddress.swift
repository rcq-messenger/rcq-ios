import Foundation

/// Resolving `.rcq` addresses. The iOS half of `web-chat/src/lib/sites.ts`,
/// which is the normative reference for all three clients; the shared
/// conformance corpus is `docs/rcq-sites-conformance.json`.
///
/// ⚠⚠ There is no DNS anywhere in here, and that is the design rather than a
/// shortcut: `.rcq` is not a domain, it is a marker that says "this name is
/// resolved inside the network". The name is parsed on THIS device into an
/// island and a site, and the request goes straight to that island. Nothing
/// about what a person reads passes through a resolver, and their own island is
/// not asked either — proxying would hand its operator a journal of what its
/// users read elsewhere.

/// Errors this module reports, by name. The screen turns them into text; the
/// spellings are shared with the web and Android and must not drift.
enum SiteError: String, Error {
    case address
    case missing
    case frozen
    case unsigned
    case tampered
    case offline
}

struct SiteAddress: Equatable, Hashable {
    /// Site name inside the island's zone.
    let name: String
    /// Island host to ask, already resolved from the address.
    let host: String
    /// What to show in the address bar: `blog.is2.rcq`.
    let display: String

    /// The identity a pin belongs to: the site and the island that serves it,
    /// never the string somebody typed. `blog.rcq` on your own island and
    /// `blog.flagship.rcq` are one site; keyed by what was typed they would
    /// have been two pins, and a key change would have gone unseen on the
    /// other one.
    var pinKey: String { "\(name)@\(host)" }

    /// Everything is https except a developer's own machine: an island is a
    /// public host, and the one exception is spelled out rather than inferred.
    var origin: String { Self.origin(forHost: host) }

    /// Split out because the island CATALOGUE has a host and no site name, and
    /// a second copy of this rule there would be a second chance for a page
    /// request and a catalogue request to disagree about which scheme an island
    /// is spoken to over.
    ///
    /// ⚠ `blog.localhost.rcq` (no colon) is an ordinary unknown label and
    /// becomes the PUBLIC host `localhost.rcq.app`, so nothing here may match on
    /// the WORD localhost — only on the host this address actually resolved to.
    static func origin(forHost host: String) -> String {
        let local = host == "localhost" || host.hasPrefix("localhost:")
            || host == "127.0.0.1" || host.hasPrefix("127.0.0.1:")
        return "\(local ? "http" : "https")://\(host)"
    }
}

/// A site address and a page inside it, as written in a link: what
/// `SiteAddressParser.link(from:)` makes of `https://e2ee.rcq/en.html`.
struct SiteLink: Equatable {
    /// The host part, lowercased, scheme stripped: `e2ee.rcq`.
    let address: String
    /// The path, or `index.html` when there was none.
    let page: String
}

enum SiteAddressParser {

    /// `blog.is2.rcq` → { name: blog, host: is2.rcq.app }.
    ///
    /// A bare `blog.rcq` means "on my own island", which is what makes
    /// somebody's first site reachable before they know what an island is.
    /// Returns nil when the address cannot be parsed — the caller reports
    /// `address` and NEVER touches the network, because an address it cannot
    /// parse is an address it must not guess at.
    static func parse(_ raw: String, ownHost: String) -> SiteAddress? {
        let cleaned = stripTrailingSlashes(stripScheme(trim(raw).lowercased()))
        guard cleaned.hasSuffix(".rcq") else { return nil }
        let stem = String(cleaned.dropLast(4))
        // `.filter(Boolean)` in the reference: empty labels are dropped, so
        // `blog..rcq` and `..blog.rcq` are still one label.
        let parts = stem.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let name = parts[0]
        guard isValidName(name) else { return nil }
        let host = parts.count == 2 ? islandHost(fromLabel: parts[1], ownHost: ownHost) : ownHost
        return SiteAddress(name: name, host: host, display: cleaned)
    }

    /// The island label → host mapping. An unknown label is treated as a
    /// hostname so an operator can hand out an address before the clients know
    /// the island.
    static func islandHost(fromLabel label: String, ownHost: String) -> String {
        if label == "flagship" || label == "rcq" { return "api.rcq.app" }
        if label == "is2" { return "is2.rcq.app" }
        if label == "here" || label == "my" { return ownHost }
        return label.contains(".") || label.contains(":") ? label : "\(label).rcq.app"
    }

    /// The address to show or hand out for a site known as `name@host`, from
    /// the reader's own island: `blog.rcq` at home, `blog.is2.rcq` elsewhere.
    /// The inverse of `islandHost(fromLabel:)`, so what it produces parses back
    /// to the same pair: `api.rcq.app` goes out as `flagship`, an `x.rcq.app`
    /// island as its label, any other host as itself. A recent recorded under
    /// one account is drawn with this under another, which is why it takes the
    /// host and not a remembered string.
    static func display(name: String, host: String, ownHost: String) -> String {
        if host == ownHost { return "\(name).rcq" }
        var label = host
        if host == "api.rcq.app" {
            label = "flagship"
        } else if host.hasSuffix(".rcq.app") {
            let stem = String(host.dropLast(".rcq.app".count))
            // ⚠ `here.rcq.app` would go out as `here`, which reads as "my
            // island" on the way back in. A stem that is one of the reserved
            // words stays a full host.
            let reserved = ["flagship", "rcq", "here", "my"]
            if !stem.isEmpty, !stem.contains("."), !stem.contains(":"), !reserved.contains(stem) {
                label = stem
            }
        }
        return "\(name).\(label).rcq"
    }

    /// A `.rcq` address the way it arrives in a chat or inside a page: bare,
    /// or dressed as a URL with a scheme and a path. Whatever the scheme, a
    /// host that ends in `.rcq` is a site address (founder, 02.09): the scheme
    /// is dropped, the host is the address and the path is the page. Returns
    /// nil for anything else, `https://chat.rcq.app/x` included. The address
    /// still has to go through `parse` — this only decides that it IS one.
    ///
    /// The whole path, not its first segment: a bundle may keep a page at
    /// `guide/intro.html`, and a link that named only `guide` would open
    /// nothing. Query and fragment are dropped; the frame acts on neither.
    static func link(from raw: String) -> SiteLink? {
        var s = trim(raw)
        if let scheme = s.range(of: "^[A-Za-z][A-Za-z0-9+.\\-]*://", options: .regularExpression) {
            s.removeSubrange(scheme)
        }
        let end = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? s.endIndex
        let authority = String(s[..<end]).lowercased()
        guard authority.hasSuffix(".rcq"), authority.count > 4 else { return nil }
        var page = "index.html"
        if end < s.endIndex, s[end] == "/" {
            let rest = s[s.index(after: end)...]
            let stop = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
            var path = String(rest[..<stop])
            while path.hasSuffix("/") { path.removeLast() }
            if !path.isEmpty { page = path.removingPercentEncoding ?? path }
        }
        return SiteLink(address: authority, page: page)
    }

    /// `link(from:)` for a URL the system already parsed.
    static func link(from url: URL) -> SiteLink? {
        link(from: url.absoluteString)
    }

    /// `^[a-z0-9][a-z0-9-]{0,31}$`, hand-rolled rather than an
    /// `NSRegularExpression`.
    ///
    /// ⚠ ICU's `$` matches before a trailing newline and JavaScript's does not,
    /// so the obvious translation of the reference's pattern would accept
    /// `blog\n` on this client alone and send a name no other client can
    /// resolve. Character-by-character there is nothing to get wrong.
    static func isValidName(_ s: String) -> Bool {
        var count = 0
        for u in s.unicodeScalars {
            count += 1
            if count > 32 { return false }
            let v = u.value
            let alnum = (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) // a-z 0-9
            if count == 1 {
                if !alnum { return false }
            } else if !(alnum || v == 0x2D) { // '-'
                return false
            }
        }
        return count > 0
    }

    // MARK: - The cleaning steps, in the reference's order

    /// JavaScript's `String.prototype.trim` set, written out.
    ///
    /// ⚠ Not `.whitespacesAndNewlines`: that set is missing U+FEFF (a BOM in
    /// front of a pasted address, which JS trims and the corpus requires us to
    /// trim) and it contains U+0085, which JS does not treat as whitespace.
    /// Either difference means one client resolves a shared address and
    /// another calls it unparseable.
    private static let trimmable: Set<UInt32> = {
        var s: Set<UInt32> = [
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, // tab, LF, VT, FF, CR, space
            0xA0,     // no-break space
            0x1680,   // ogham space mark
            0x2028, 0x2029, // line / paragraph separator
            0x202F, 0x205F, 0x3000,
            0xFEFF,   // zero-width no-break space (BOM)
        ]
        for v in UInt32(0x2000)...UInt32(0x200A) { s.insert(v) }
        return s
    }()

    private static func trim(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let f = scalars.first, trimmable.contains(f.value) { scalars.removeFirst() }
        while let l = scalars.last, trimmable.contains(l.value) { scalars.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    /// The reference lowercases BEFORE stripping `rcq://`, so its pattern only
    /// ever sees lowercase — which is why `RCQ://BLOG.RCQ` works there. Same
    /// order here.
    private static func stripScheme(_ s: String) -> String {
        s.hasPrefix("rcq://") ? String(s.dropFirst(6)) : s
    }

    /// One or more, not exactly one: a share sheet or a QR generator adds them
    /// by habit.
    private static func stripTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

/// Resolve `../a/b.png` against the page's own path, inside the bundle only.
///
/// ⚠⚠ The result is only ever a KEY into `manifest.files`. It is never a
/// filesystem path and never a URL built by concatenation: `..` pops an
/// already-empty stack and a leading slash means the bundle root, so a
/// reference cannot climb out — but the reason that holds is that nothing
/// downstream joins this onto a directory. On a phone, a reader that unpacked a
/// bundle into a cache directory and joined these onto it would be reading the
/// user's files.
func resolveBundlePath(from: String, ref: String) -> String? {
    if hasScheme(ref) || ref.hasPrefix("//") || ref.hasPrefix("#") { return nil }
    let base = from.components(separatedBy: "/").dropLast()
    var out: [String] = ref.hasPrefix("/") ? [] : Array(base)
    let body = ref.hasPrefix("/") ? String(ref.dropFirst()) : ref
    for seg in body.components(separatedBy: "/") {
        if seg.isEmpty || seg == "." { continue }
        if seg == ".." { if !out.isEmpty { out.removeLast() } } else { out.append(seg) }
    }
    let joined = out.joined(separator: "/")
    return joined.isEmpty ? nil : joined
}

/// `/^[a-z]+:/i` — anything with a scheme is outside the bundle, `javascript:`
/// and `data:` included.
private func hasScheme(_ s: String) -> Bool {
    var seen = 0
    for u in s.unicodeScalars {
        let v = u.value
        if (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) { seen += 1; continue }
        return v == 0x3A && seen > 0 // ':'
    }
    return false
}
