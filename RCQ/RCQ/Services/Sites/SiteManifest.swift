import CryptoKit
import Foundation

/// The signed description of a `.rcq` bundle, and everything needed to check
/// it. Mirrors `web-chat/src/lib/sites.ts`.
///
/// ⚠⚠ The island is not trusted with the bytes. Every bundle carries a manifest
/// signed by the OWNER's key with a hash per file; the signature is checked
/// here and each fetched file is checked against that hash. The island can
/// refuse to serve a site, it cannot alter one.
struct SiteManifest {
    let v: Int
    let name: String
    let version: Int
    /// Ed25519 public key (base64) the bundle is signed under.
    let key: String
    /// path → sha256 hex of the file's bytes.
    let files: [String: String]
    let sig: String
    let title: String?
    /// The site's mark, a path inside the bundle. Inside the SIGNATURE on
    /// purpose: this is what a site looks like in a list of sites, and an
    /// island that could choose it could dress one site up as another.
    let icon: String?

    /// What a bundle may call its mark when the manifest does not say.
    static let iconNames = ["icon.png", "icon.webp", "favicon.png"]

    /// ⚠⚠ RASTER ONLY, and that is a network-wide decision rather than this
    /// screen's taste. A mark is drawn by OUR chrome, OUTSIDE the locked web
    /// view: on a phone an SVG would be handed to a native decoder with no
    /// sandbox around it and no sanitiser in front of it, and iOS has no native
    /// SVG renderer at all. PNG and WebP are decoded by the same code that
    /// draws every avatar in the app already.
    ///
    /// The reference returns `manifest.icon` with no extension check; the
    /// corpus calls that a gap and requires an SVG mark to resolve to nothing.
    ///
    /// ⚠ `png` and `webp` and nothing else, which is narrower than the image
    /// types a PAGE may inline (`SiteBytes.imageTypes`) and narrower than
    /// Android's list. The reference draws the line here
    /// (`/\.(png|webp)$/i`), and a mark that resolves on one client and not on
    /// another is a site that looks like two different sites in two catalogues.
    static let rasterIconExtensions: Set<String> = ["png", "webp"]

    /// Which file in this bundle is the site's mark, if any.
    var iconPath: String? {
        if let icon, files[icon] != nil, Self.rasterIconExtensions.contains(Self.ext(of: icon)) {
            return icon
        }
        return Self.iconNames.first { files[$0] != nil }
    }

    /// Every `.html` in the bundle: index.html first, the rest alphabetically,
    /// because the front page is the front page whatever it sorts as.
    ///
    /// The reference finishes with `localeCompare`, which is locale-dependent
    /// and would make the page list differ between two phones in the same
    /// household. Case-insensitive first, byte-wise to break ties: total,
    /// deterministic, and the same list everywhere.
    var pages: [String] {
        files.keys
            .filter { $0.lowercased().hasSuffix(".html") }
            .sorted { a, b in
                if a == "index.html" { return b != "index.html" }
                if b == "index.html" { return false }
                let ca = a.lowercased(), cb = b.lowercased()
                if ca != cb { return ca < cb }
                return utf16Less(a, b)
            }
    }

    private static func ext(of path: String) -> String {
        guard let dot = path.lastIndex(of: ".") else { return "" }
        return String(path[path.index(after: dot)...]).lowercased()
    }

    // MARK: - Parse + verify

    /// Parse a manifest body and check the owner's signature over it.
    ///
    /// ⚠ The key comes from the MANIFEST, not from a set this build pins (that
    /// is `SigningKeys`, and it answers a different question). A signature that
    /// verifies proves only that whoever holds this key produced these bytes;
    /// what binds the key to the site is the TOFU pin in `SitePins`, the same
    /// rule as safety numbers.
    static func parseAndVerify(_ body: Data, expecting name: String) throws -> SiteManifest {
        guard let parsed = try? JSONSerialization.jsonObject(with: body),
              var doc = parsed as? [String: Any] else {
            throw SiteError.unsigned
        }
        guard let key = doc["key"] as? String,
              let sig = doc["sig"] as? String,
              doc["files"] != nil else {
            throw SiteError.unsigned
        }
        // Signed over "the manifest without `sig`" — including fields this
        // build does not know about, exactly like the reference's rest-spread.
        // A future field must not fall out of the signature just because an old
        // client cannot name it.
        doc.removeValue(forKey: "sig")
        guard let message = try? SiteCanonicalJSON.data(doc),
              let keyBytes = Data(base64Encoded: key),
              let sigBytes = Data(base64Encoded: sig),
              SigningKeys.verify(publicKey: keyBytes, message: message, signature: sigBytes) else {
            throw SiteError.unsigned
        }
        // The name is inside the signature too: without this check a manifest
        // signed for one site could be replayed under another name on the same
        // island.
        guard (doc["name"] as? String) == name else { throw SiteError.unsigned }

        var files: [String: String] = [:]
        if let raw = doc["files"] as? [String: Any] {
            for (k, v) in raw { if let hash = v as? String { files[k] = hash } }
        }
        return SiteManifest(
            v: intValue(doc["v"]),
            name: name,
            version: intValue(doc["version"]),
            key: key,
            files: files,
            sig: sig,
            title: doc["title"] as? String,
            icon: doc["icon"] as? String
        )
    }

    private static func intValue(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
}

// MARK: - Hashes and data: URIs

enum SiteBytes {
    /// Lowercase hex, the form `manifest.files` uses.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
    ]

    /// A `data:` URI for verified bytes, or nil when the path is not an image
    /// this reader inlines.
    ///
    /// `svg` is here and deliberately NOT in `SiteManifest.rasterIconExtensions`:
    /// inside the locked web view an `<img>` renders SVG with scripting
    /// disabled by the image sandbox, the same as on the web. A MARK is drawn
    /// by native chrome with no such sandbox, which is why that path is raster
    /// only.
    static func dataURI(path: String, bytes: Data) -> String? {
        let ext = (path.components(separatedBy: ".").last ?? "").lowercased()
        guard let type = imageTypes[ext] else { return nil }
        return "data:\(type);base64,\(bytes.base64EncodedString())"
    }
}

// MARK: - Canonical JSON

/// Canonical JSON for site manifests: object keys sorted recursively, compact
/// separators, `/` and non-ASCII left unescaped, integers in shortest form,
/// UTF-8. Byte-identical to `JSON.stringify` over a pre-sorted object, which is
/// what the web reference signs against and what the signer produces.
///
/// ⚠⚠ NOT `JSONSerialization` with `.sortedKeys`, and this is the whole reason
/// this type exists. Foundation's "lexicographic" order folds case and reads
/// digit runs as numbers, so it sorts `{a_b, alpha, aXb, Beta, x2, x10}` where
/// JavaScript, Kotlin and Python all produce `{Beta, aXb, a_b, alpha, x10, x2}`
/// — a completely different byte string. Manifest keys include every FILE PATH
/// in the bundle, so mixed case and digits are the normal case, not the exotic
/// one: reusing `RcqFederation.canonicalData` here would have made every
/// manifest with a `Photo2.png` in it fail to verify on iOS alone.
///
/// (`RcqFederation`'s own keys are all lowercase and digit-free, so that
/// call site is accidentally safe and is left alone.)
enum SiteCanonicalJSON {
    static func data(_ value: Any) throws -> Data {
        var out = ""
        try write(value, into: &out)
        guard let d = out.data(using: .utf8) else { throw SiteError.unsigned }
        return d
    }

    private static func write(_ value: Any, into out: inout String) throws {
        if value is NSNull { out += "null"; return }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out += n.boolValue ? "true" : "false"
            } else {
                out += number(n)
            }
            return
        }
        if let s = value as? String { out += string(s); return }
        if let a = value as? [Any] {
            out += "["
            for (i, item) in a.enumerated() {
                if i > 0 { out += "," }
                try write(item, into: &out)
            }
            out += "]"
            return
        }
        if let o = value as? [String: Any] {
            out += "{"
            var first = true
            for k in o.keys.sorted(by: utf16Less) {
                if !first { out += "," }
                first = false
                out += string(k)
                out += ":"
                try write(o[k] as Any, into: &out)
            }
            out += "}"
            return
        }
        throw SiteError.unsigned
    }

    /// JavaScript has one number type, so `1.0` stringifies as `1`. Any value
    /// that is integral is written as an integer for that reason, not as a
    /// convenience.
    private static func number(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d.rounded() == d, abs(d) < 9_007_199_254_740_992 {
            return String(Int64(d))
        }
        return "\(d)"
    }

    /// `JSON.stringify`'s escaping: quote, backslash and the C0 controls, and
    /// nothing else. `/` stays a slash and non-ASCII stays itself.
    private static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

/// UTF-16 code-unit order — what `Array.prototype.sort()` and Kotlin's
/// `compareTo` do. Swift's own `<` on String collates by grapheme and would
/// order keys differently from every other client.
func utf16Less(_ a: String, _ b: String) -> Bool {
    let ua = Array(a.utf16), ub = Array(b.utf16)
    for i in 0..<min(ua.count, ub.count) where ua[i] != ub[i] {
        return ua[i] < ub[i]
    }
    return ua.count < ub.count
}
