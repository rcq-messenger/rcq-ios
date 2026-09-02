import Foundation

/// The doors inside a page, and the only ones.
///
/// The sanitiser strips every `href`, and the corpus pins that
/// (`docs/rcq-sites-conformance.json`, sanitiser: `mustNotContain "href="`),
/// so the document it hands over refers to nothing. This is the reader's own
/// step on top, taken at load time and never inside the sanitiser: an anchor the
/// sanitiser marked as a page of the same bundle (`data-rcq-page`), or one whose
/// outward target is itself a `.rcq` address (`data-rcq-external`), is given an
/// `href` in a scheme nothing but our chrome answers. The navigation delegate
/// turns a tap on it into `open` and CANCELS the load, so the web view still
/// navigates nowhere. Every other anchor stays what the sanitiser made it: text
/// (founder, 02.09: external links are not opened anywhere, and not confirmed;
/// that decision has not been made).
///
/// ⚠ `rcq-reader:`, not `rcq:`. The app registers `rcq://`, and a navigation to
/// it that was ever ALLOWED would leave the web view for
/// `AppState.handle(deepLink:)`, which acts for the real account. This scheme is
/// registered nowhere, so even an allowed navigation would go nowhere.
///
/// ⚠ The payload is percent-encoded down to alphanumerics, so it survives
/// whatever WebKit normalises on the way from the attribute to the navigation
/// action, and it is read back off the string rather than through `URL.path`,
/// which decodes `%2F` into a separator.
enum SiteReaderLinks {
    static let scheme = "rcq-reader"

    enum Target: Equatable {
        /// Another page of the bundle being read.
        case page(String)
        /// Another site: the address and the page, as written by the author.
        case site(SiteLink)
    }

    private static let pagePrefix = "\(scheme)://page/"
    private static let sitePrefix = "\(scheme)://site/"

    private static let pageMark = try! NSRegularExpression(pattern: #"data-rcq-page="([^"]*)""#)
    private static let externalMark = try! NSRegularExpression(pattern: #"data-rcq-external="([^"]*)""#)

    /// The sanitised document with its in-network anchors made tappable.
    static func arm(_ html: String) -> String {
        var out = insert(into: html, at: pageMark) { inner in
            pagePrefix + encode(inner)
        }
        out = insert(into: out, at: externalMark) { raw in
            // The serialiser escaped `&` and the quote; nothing else.
            let target = raw.replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard SiteAddressParser.link(from: target) != nil else { return nil }
            return sitePrefix + encode(target)
        }
        return out
    }

    /// What a tapped `href` of ours means, or nil for anything else.
    static func target(of url: URL) -> Target? {
        let s = url.absoluteString
        if s.hasPrefix(pagePrefix) {
            guard let page = decode(String(s.dropFirst(pagePrefix.count))), !page.isEmpty else { return nil }
            return .page(page)
        }
        if s.hasPrefix(sitePrefix) {
            guard let raw = decode(String(s.dropFirst(sitePrefix.count))),
                  let link = SiteAddressParser.link(from: raw) else { return nil }
            return .site(link)
        }
        return nil
    }

    /// `href="…" ` goes in FRONT of the mark, so the mark itself is untouched and
    /// the attribute reads as ours in the source.
    private static func insert(
        into html: String,
        at regex: NSRegularExpression,
        href: (String) -> String?
    ) -> String {
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if let target = href(ns.substring(with: m.range(at: 1))) {
                out += "href=\"\(target)\" "
            }
            out += ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private static func decode(_ s: String) -> String? {
        s.removingPercentEncoding
    }
}
