import Foundation

/// Turning a verified bundle into ONE self-contained document, with everything
/// that could reach the network or run taken out.
///
/// ⚠⚠ On the web this is the second of two locks: the frame's CSP is the
/// browser's promise and the sanitiser is ours. On a phone the CSP is a `<meta>`
/// inside a `WKWebView` that may or may not honour it, so THIS half is the one
/// that has to be right on its own. Every removal below stands without help.
///
/// There is no DOM on iOS, so this file carries a small tolerant HTML tokeniser,
/// a tree builder and a serialiser. They exist because the pipeline parses once
/// and the web view parses again: anything the two disagree about is a mutation
/// bug, which is why raw-text elements, foreign content and text escaping are
/// handled explicitly rather than approximated with string surgery.

// MARK: - Tree

final class SiteHTMLNode {
    enum Kind {
        case element(String)
        case text(String)
    }

    var kind: Kind
    /// Ordered, because the serialised attribute order is part of what the
    /// conformance corpus reads.
    var attributes: [(name: String, value: String)] = []
    var children: [SiteHTMLNode] = []

    init(element tag: String) { kind = .element(tag) }
    init(text: String) { kind = .text(text) }

    var tag: String? {
        if case .element(let t) = kind { return t }
        return nil
    }

    var text: String? {
        if case .text(let t) = kind { return t }
        return nil
    }

    func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    func setAttribute(_ name: String, _ value: String) {
        if let i = attributes.firstIndex(where: { $0.name == name }) {
            attributes[i].value = value
        } else {
            attributes.append((name, value))
        }
    }

    func removeAttributes(where predicate: (String) -> Bool) {
        attributes.removeAll { predicate($0.name) }
    }

    /// Every text descendant, joined. Used for `<style>`, whose content is CSS.
    var textContent: String {
        switch kind {
        case .text(let t): return t
        case .element: return children.map(\.textContent).joined()
        }
    }
}

// MARK: - Tokeniser

private enum SiteHTMLToken {
    case text(String)
    case start(tag: String, attributes: [(name: String, value: String)], selfClosing: Bool)
    case end(String)
}

private struct SiteHTMLTokenizer {
    /// Content model "raw text" (and RCDATA, which we treat the same because we
    /// re-escape on the way out): the parser has already decided this content
    /// is not markup, so it must reach the serialiser as TEXT or the web view
    /// will parse what we merely moved.
    static let rawTextTags: Set<String> = [
        "script", "style", "xmp", "iframe", "noembed", "noframes", "noscript",
        "title", "textarea",
    ]

    /// Foreign content: a second grammar inside the first, with case-sensitive
    /// names, self-closing tags and URL attributes that are not `src`. We do
    /// not parse it — the whole subtree is captured opaquely and the removal
    /// list drops it, text and all.
    static let foreignTags: Set<String> = ["svg", "math"]

    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr",
    ]

    let src: [Character]
    var i = 0
    var tokens: [SiteHTMLToken] = []

    /// ⚠⚠ CRLF is normalised away before the document becomes Characters, and
    /// that is not tidiness. In Swift `"\r\n"` is ONE Character - a grapheme
    /// cluster - so it equals neither `"\r"` nor `"\n"`, and every whitespace
    /// test in this parser said no to it. A tag whose attributes were split
    /// across lines, which is every line a word processor exports, then had the
    /// rest of the line swallowed into the previous attribute's unquoted value:
    /// `<img width=623 height=623CRLFsrc="01.png">` lost its `src` and the
    /// picture with it, on a page that rendered correctly in every other
    /// client (founder, 02.09, `main.rcq`). Windows line endings are the norm
    /// in exactly the pages this reader exists for.
    init(_ html: String) {
        src = Array(html.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    static func tokenize(_ html: String) -> [SiteHTMLToken] {
        var t = SiteHTMLTokenizer(html)
        t.run()
        return t.tokens
    }

    private mutating func run() {
        var pending = ""
        func flush() {
            if !pending.isEmpty { tokens.append(.text(pending)); pending = "" }
        }
        while i < src.count {
            let c = src[i]
            guard c == "<" else { pending.append(c); i += 1; continue }
            let next = i + 1 < src.count ? src[i + 1] : " "
            if next == "!" {
                flush()
                // ⚠ Comments are DROPPED, not passed through. Build tooling
                // leaves absolute paths, usernames and tool versions in them,
                // and conditional/bogus comments are a classic place for two
                // HTML parsers to disagree about where the comment ends — and
                // this pipeline runs two.
                skipMarkupDeclaration()
                continue
            }
            if next == "?" {
                flush()
                skipTo(">")
                continue
            }
            if next == "/" {
                let after = i + 2 < src.count ? src[i + 2] : " "
                if !Self.isLetter(after) { flush(); skipTo(">"); continue }
                flush()
                let tag = readTag()
                tokens.append(.end(tag.name))
                continue
            }
            if Self.isLetter(next) {
                flush()
                let tag = readTag()
                emitStart(tag)
                continue
            }
            pending.append(c)
            i += 1
        }
        flush()
    }

    private mutating func emitStart(_ tag: (name: String, attributes: [(name: String, value: String)], selfClosing: Bool, isEnd: Bool)) {
        // `<image>` is renamed to `img` by every HTML parser. A port that
        // skipped this would leave an element our image pass never inspects and
        // the web view then treats as an img and fetches.
        var name = tag.name
        if name == "image" { name = "img" }
        tokens.append(.start(tag: name, attributes: tag.attributes, selfClosing: tag.selfClosing))
        if Self.voidTags.contains(name) { return }
        if tag.selfClosing && Self.foreignTags.contains(name) { return }

        if name == "plaintext" {
            // Swallows the rest of the document as text and has no closing form.
            tokens.append(.text(String(src[i...])))
            i = src.count
            tokens.append(.end(name))
            return
        }
        if Self.foreignTags.contains(name) {
            captureForeign(name)
            return
        }
        if Self.rawTextTags.contains(name) {
            captureRawText(name)
            return
        }
    }

    /// Everything up to the matching `</svg>` / `</math>`, as one opaque text
    /// node. Nested foreign elements are counted, and a `/>`-closed one does
    /// not open a level — which HTML elements never get, but foreign ones do.
    private mutating func captureForeign(_ name: String) {
        let start = i
        var depth = 1
        var contentEnd = src.count
        var resume = src.count
        while i < src.count {
            guard src[i] == "<" else { i += 1; continue }
            let next = i + 1 < src.count ? src[i + 1] : " "
            let after = i + 2 < src.count ? src[i + 2] : " "
            guard Self.isLetter(next) || (next == "/" && Self.isLetter(after)) else { i += 1; continue }
            let mark = i
            let tag = readTag()
            if Self.foreignTags.contains(tag.name) {
                if tag.isEnd {
                    depth -= 1
                    if depth == 0 { contentEnd = mark; resume = i; break }
                } else if !tag.selfClosing {
                    depth += 1
                }
            }
        }
        tokens.append(.text(String(src[start..<contentEnd])))
        tokens.append(.end(name))
        i = resume
    }

    /// Everything up to `</name`, as text. The end tag itself is left for the
    /// main loop.
    private mutating func captureRawText(_ name: String) {
        let start = i
        let want = Array(name)
        var contentEnd = src.count
        var resume = src.count
        var j = i
        outer: while j < src.count {
            if src[j] == "<", j + 1 < src.count, src[j + 1] == "/" {
                var k = j + 2
                var m = 0
                while k < src.count, m < want.count, Self.lower(src[k]) == want[m] { k += 1; m += 1 }
                if m == want.count, k >= src.count || Self.isSpace(src[k]) || src[k] == ">" || src[k] == "/" {
                    contentEnd = j
                    resume = j
                    break outer
                }
            }
            j += 1
        }
        tokens.append(.text(String(src[start..<contentEnd])))
        i = resume
    }

    /// Reads one tag starting at `<`, leaving `i` past its `>`.
    private mutating func readTag() -> (name: String, attributes: [(name: String, value: String)], selfClosing: Bool, isEnd: Bool) {
        i += 1 // '<'
        var isEnd = false
        if i < src.count, src[i] == "/" { isEnd = true; i += 1 }
        var name = ""
        while i < src.count, !Self.isSpace(src[i]), src[i] != ">", src[i] != "/" {
            name.append(Self.lower(src[i]))
            i += 1
        }
        var attributes: [(name: String, value: String)] = []
        var selfClosing = false
        while i < src.count {
            skipSpace()
            if i >= src.count { break }
            if src[i] == ">" { i += 1; break }
            if src[i] == "/" {
                if i + 1 < src.count, src[i + 1] == ">" { selfClosing = true; i += 2; break }
                i += 1
                continue
            }
            var attrName = ""
            while i < src.count, !Self.isSpace(src[i]), src[i] != "=", src[i] != ">", src[i] != "/" {
                attrName.append(Self.lower(src[i]))
                i += 1
            }
            skipSpace()
            var value = ""
            if i < src.count, src[i] == "=" {
                i += 1
                skipSpace()
                if i < src.count, src[i] == "\"" || src[i] == "'" {
                    let quote = src[i]
                    i += 1
                    while i < src.count, src[i] != quote { value.append(src[i]); i += 1 }
                    if i < src.count { i += 1 }
                } else {
                    while i < src.count, !Self.isSpace(src[i]), src[i] != ">" { value.append(src[i]); i += 1 }
                }
            }
            // Attribute values are DECODED here and re-escaped on the way out,
            // so a target hidden behind `&#117;rl(` cannot walk past the tests
            // below. First occurrence wins, like every HTML parser.
            if !attrName.isEmpty, !attributes.contains(where: { $0.name == attrName }) {
                attributes.append((attrName, SiteHTMLEntities.decode(value)))
            }
        }
        return (name, attributes, selfClosing, isEnd)
    }

    private mutating func skipMarkupDeclaration() {
        if matches("<!--") {
            i += 4
            while i < src.count {
                if src[i] == "-", i + 2 < src.count, src[i + 1] == "-", src[i + 2] == ">" { i += 3; return }
                if src[i] == "-", i + 3 < src.count, src[i + 1] == "-", src[i + 2] == "!", src[i + 3] == ">" { i += 4; return }
                i += 1
            }
            return
        }
        skipTo(">") // doctype, CDATA, bogus comment
    }

    private mutating func skipTo(_ c: Character) {
        while i < src.count, src[i] != c { i += 1 }
        if i < src.count { i += 1 }
    }

    private mutating func skipSpace() {
        while i < src.count, Self.isSpace(src[i]) { i += 1 }
    }

    private func matches(_ s: String) -> Bool {
        let want = Array(s)
        guard i + want.count <= src.count else { return false }
        for (k, ch) in want.enumerated() where src[i + k] != ch { return false }
        return true
    }

    static func isSpace(_ c: Character) -> Bool {
        // "\r\n" is here as its own case as well: the initialiser folds it
        // away, and a caller that builds a parser some other way should still
        // not be caught by the grapheme.
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" || c == "\r\n"
    }

    static func isLetter(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    static func lower(_ c: Character) -> Character {
        (c >= "A" && c <= "Z") ? Character(UnicodeScalar(c.asciiValue! + 32)) : c
    }
}

// MARK: - Tree builder

private enum SiteHTMLTreeBuilder {
    /// Elements that belong in `<head>` while nothing has started the body yet.
    static let headTags: Set<String> = [
        "base", "basefont", "bgsound", "link", "meta", "title", "style",
        "script", "noscript", "template",
    ]

    /// Enough implied-end-tag handling that ordinary prose nests the way a real
    /// parser nests it. Not the full algorithm — this is fidelity, not safety.
    static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hr", "main", "menu", "nav", "ol", "p",
        "pre", "section", "table", "ul", "li", "dd", "dt",
    ]

    static func build(_ tokens: [SiteHTMLToken]) -> SiteHTMLNode {
        let html = SiteHTMLNode(element: "html")
        let head = SiteHTMLNode(element: "head")
        let body = SiteHTMLNode(element: "body")
        html.children = [head, body]

        var stack: [SiteHTMLNode] = [html, head]
        var inHead = true

        func merge(_ node: SiteHTMLNode, _ attributes: [(name: String, value: String)]) {
            for a in attributes where node.attribute(a.name) == nil {
                node.attributes.append(a)
            }
        }
        func enterBody() {
            if inHead { stack = [html]; inHead = false }
            if stack.count == 1 { stack.append(body) }
        }
        func append(_ node: SiteHTMLNode) {
            stack[stack.count - 1].children.append(node)
        }

        for token in tokens {
            switch token {
            case .start(let tag, let attributes, _):
                switch tag {
                case "html": merge(html, attributes); continue
                case "head": if inHead { merge(head, attributes) }; continue
                case "body": enterBody(); merge(body, attributes); continue
                case "frameset", "frame": continue
                default: break
                }
                if inHead {
                    // ⚠ `stack.count > 2` means a head element is still OPEN,
                    // and content belongs INSIDE it rather than starting the
                    // body. Without that test a `<p>` inside `<template>` broke
                    // out of it here while a real parser kept it in — and
                    // `template` is dropped WITH its children, so the paragraph
                    // a browser never shows was the one this reader showed
                    // (docs/rcq-sites-conformance.json, sanitiser[3]).
                    if !headTags.contains(tag) && stack.count <= 2 { enterBody() }
                } else {
                    enterBody()
                }
                while stack.count > 2, let open = stack.last?.tag, implies(tag, closes: open) {
                    stack.removeLast()
                }
                let node = SiteHTMLNode(element: tag)
                node.attributes = attributes
                append(node)
                if !SiteHTMLTokenizer.voidTags.contains(tag) { stack.append(node) }

            case .end(let tag):
                switch tag {
                case "html", "body":
                    stack = [html]
                    inHead = false
                    continue
                case "head":
                    if inHead { stack = [html]; inHead = false }
                    continue
                default: break
                }
                if let idx = stack.lastIndex(where: { $0.tag == tag }), idx >= 1 {
                    stack.removeSubrange(idx...)
                }

            case .text(let t):
                if inHead {
                    if stack.count > 2 {
                        append(SiteHTMLNode(text: t))
                    } else if !t.allSatisfy(SiteHTMLTokenizer.isSpace) {
                        enterBody()
                        append(SiteHTMLNode(text: t))
                    }
                } else {
                    enterBody()
                    append(SiteHTMLNode(text: t))
                }
            }
        }
        return html
    }

    private static func implies(_ tag: String, closes open: String) -> Bool {
        if open == "p" { return closesParagraph.contains(tag) }
        if open == "li" { return tag == "li" }
        if open == "dt" || open == "dd" { return tag == "dt" || tag == "dd" }
        if open == "td" || open == "th" { return tag == "td" || tag == "th" || tag == "tr" }
        if open == "tr" { return tag == "tr" }
        if open == "option" { return tag == "option" }
        return false
    }
}

// MARK: - Entities

enum SiteHTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "shy": "\u{00AD}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "bull": "•", "middot": "·",
        "times": "×", "divide": "÷", "deg": "°", "plusmn": "±",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sect": "§",
        "para": "¶", "dagger": "†", "permil": "‰", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "larr": "←", "rarr": "→",
        "uarr": "↑", "darr": "↓", "harr": "↔", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}",
    ]

    /// Decodes what we can and leaves the rest verbatim. An unknown reference
    /// stays as source text and the serialiser recognises it as one, so it
    /// round-trips instead of being escaped twice.
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            guard c[i] == "&", let end = c[i...].firstIndex(of: ";"), end - i <= 32 else {
                out.append(c[i])
                i += 1
                continue
            }
            let body = String(c[(i + 1)..<end])
            if body.hasPrefix("#") {
                let digits = String(body.dropFirst())
                let value: UInt32?
                if digits.lowercased().hasPrefix("x") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits, radix: 10)
                }
                if let v = value, let scalar = Unicode.Scalar(v) {
                    out.unicodeScalars.append(scalar)
                    i = end + 1
                    continue
                }
            } else if let replacement = named[body] {
                out += replacement
                i = end + 1
                continue
            }
            out.append(c[i])
            i += 1
        }
        return out
    }

    /// True when `chars[i] == "&"` starts something the web view will read as a
    /// character reference.
    static func looksLikeReference(_ chars: [Character], _ i: Int) -> Bool {
        var j = i + 1
        guard j < chars.count else { return false }
        if chars[j] == "#" {
            j += 1
            if j < chars.count, chars[j] == "x" || chars[j] == "X" { j += 1 }
            var digits = 0
            while j < chars.count, chars[j].isHexDigit { j += 1; digits += 1 }
            return digits > 0 && j < chars.count && chars[j] == ";"
        }
        guard SiteHTMLTokenizer.isLetter(chars[j]) else { return false }
        var length = 0
        while j < chars.count, chars[j].isLetter || chars[j].isNumber, length < 32 { j += 1; length += 1 }
        return j < chars.count && chars[j] == ";"
    }
}

// MARK: - Serialiser

enum SiteHTMLSerializer {
    static func document(_ html: SiteHTMLNode) -> String {
        "<!doctype html>" + serialize(html, parent: nil)
    }

    static func serialize(_ node: SiteHTMLNode, parent: String?) -> String {
        switch node.kind {
        case .text(let t):
            // ⚠ `<style>` is a RAW TEXT element: there is no escaping inside
            // one, so its content is written verbatim and the neutralising has
            // to have happened in the CSS cleaner. Everywhere else text is
            // escaped, which is what keeps an unwrapped `<xmp>` from handing
            // the web view a live element.
            return parent == "style" ? t : escapeText(t)
        case .element(let tag):
            var out = "<" + tag
            for a in node.attributes {
                out += " \(a.name)=\"\(escapeAttribute(a.value))\""
            }
            out += ">"
            if SiteHTMLTokenizer.voidTags.contains(tag) { return out }
            for child in node.children { out += serialize(child, parent: tag) }
            return out + "</" + tag + ">"
        }
    }

    static func escapeText(_ s: String) -> String {
        let c = Array(s)
        var out = ""
        for i in 0..<c.count {
            switch c[i] {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += SiteHTMLEntities.looksLikeReference(c, i) ? "&" : "&amp;"
            default: out.append(c[i])
            }
        }
        return out
    }

    /// Attribute values were decoded at parse time, so `&` is always escaped
    /// here — the same round trip a DOM serialiser does. `<` and `>` are NOT
    /// escaped, because inside an attribute value they are text to every
    /// parser; whatever native chrome reads `data-rcq-external` has to treat it
    /// as text, never as markup.
    static func escapeAttribute(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - CSS

/// Author CSS is kept, but never anything that fetches.
///
/// ⚠⚠ Written as a tokeniser rather than as the reference's regular
/// expressions, and the corpus is the argument: `\75 rl(` is `url(` to a
/// conforming CSS parser, `image-set()` takes bare strings with no `url()` in
/// sight, a `}` inside a string ends a naive `@font-face` match early, and an
/// `@import` with no semicolon runs to the next block. Expressions miss all
/// four. On the web the frame's `default-src 'none'` catches what slips
/// through; here nothing does.
/// Text out of a bundle, read the way its author declared it.
///
/// ⚠ The first site anybody published on this network was a 2000s page in
/// windows-1251, and that is not an accident: a format with no scripts and no
/// tracking attracts exactly the people whose pages predate UTF-8. Decoded as
/// UTF-8 their Russian came out as mojibake on iOS while the same page read
/// correctly on the desktop, which already sniffed the label (founder, 02.09,
/// `main.rcq`). The label is read out of the first kilobyte, the way a browser
/// does it, and the whole `<meta charset>` / `<meta http-equiv>` argument is
/// settled by one regular expression because a page cannot lie about its own
/// bytes in a way that hurts anybody but itself.
enum SiteText {

    /// The labels worth carrying, mapped to what CoreFoundation calls them.
    /// Anything not here falls back to UTF-8, which at least renders the ASCII.
    private static let known: [String: CFStringEncodings] = [
        "windows-1251": .windowsCyrillic, "cp1251": .windowsCyrillic,
        "windows-1250": .windowsLatin2, "windows-1254": .windowsLatin5,
        "koi8-r": .KOI8_R, "koi8-u": .KOI8_U,
        "iso-8859-5": .isoLatinCyrillic, "iso-8859-2": .isoLatin2,
        "iso-8859-7": .isoLatinGreek, "iso-8859-9": .isoLatin5,
        "cp866": .dosRussian, "ibm866": .dosRussian,
        "gb2312": .GB_18030_2000, "gbk": .GB_18030_2000, "gb18030": .GB_18030_2000,
        "big5": .big5, "shift_jis": .shiftJIS, "sjis": .shiftJIS, "euc-jp": .EUC_JP,
        "euc-kr": .EUC_KR, "windows-1256": .windowsArabic, "windows-1255": .windowsHebrew,
    ]

    static func decode(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        let head = String(decoding: bytes.prefix(1024), as: UTF8.self)
            .isEmpty ? "" : String(data: data.prefix(1024), encoding: .isoLatin1) ?? ""
        if let label = charsetLabel(in: head) {
            if label == "utf-8" || label == "utf8" {
                return String(decoding: bytes, as: UTF8.self)
            }
            if label == "iso-8859-1" || label == "latin1" {
                return String(data: data, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
            }
            if label == "windows-1252" || label == "cp1252" {
                return String(data: data, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
            }
            if let cf = known[label] {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decode(_ data: Data) -> String { decode([UInt8](data)) }

    private static func charsetLabel(in head: String) -> String? {
        guard let r = head.range(of: "charset\\s*=\\s*[\"']?[A-Za-z0-9_-]+", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let piece = head[r]
        guard let eq = piece.firstIndex(of: "=") else { return nil }
        return piece[piece.index(after: eq)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            .lowercased()
    }
}

enum SiteCSS {
    private enum Token {
        case atKeyword(raw: String, name: String)
        case function(raw: String, name: String, inner: String)
        case string(String)
        case whitespace(String)
        case symbol(Character)
        case other(String)

        var raw: String {
            switch self {
            case .atKeyword(let raw, _): return raw
            case .function(let raw, _, let inner): return raw + "(" + inner + ")"
            case .string(let s), .whitespace(let s), .other(let s): return s
            case .symbol(let c): return String(c)
            }
        }

        var isWhitespace: Bool {
            if case .whitespace = self { return true }
            return false
        }

        var isOpenBrace: Bool {
            if case .symbol("{") = self { return true }
            return false
        }
    }

    /// Functions that name something to fetch. `url()` keeps its data: URIs;
    /// the rest are replaced whole, because the fetching surface of CSS is not
    /// the `url()` token, it is every place a URL may be spelled — and that set
    /// grows.
    private static let urlBearing: Set<String> = ["image-set", "image", "src", "cross-fade"]

    static func clean(_ css: String) -> String {
        let cleaned = rebuild(tokenize(Array(css)))
        // ⚠⚠ A stylesheet in a bundle may contain `</style>`. It is set as the
        // text of a raw-text element, so the serialiser cannot escape it and
        // the web view would end the element early and read the rest as live
        // markup. The author of the CSS is the site owner, who is NOT trusted —
        // anyone with an island account can publish a site — so this is
        // reachable by design. A CSS escape means the same thing to a CSS
        // parser and nothing at all to an HTML one.
        return cleaned.replacingOccurrences(of: "<", with: "\\3c ")
    }

    // MARK: Tokenising

    private static func tokenize(_ c: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i = min(i + 2, c.count)
                // A comment separates tokens; dropping it outright would splice
                // two idents into one.
                tokens.append(.whitespace(" "))
                continue
            }
            if ch == "\"" || ch == "'" {
                tokens.append(.string(readString(c, &i)))
                continue
            }
            if ch == "@", i + 1 < c.count, isIdentStart(c, i + 1) {
                var j = i + 1
                let ident = readIdent(c, &j)
                tokens.append(.atKeyword(raw: "@" + ident.raw, name: ident.value.lowercased()))
                i = j
                continue
            }
            if isIdentStart(c, i) {
                let ident = readIdent(c, &i)
                if i < c.count, c[i] == "(" {
                    let inner = readBalanced(c, &i)
                    tokens.append(.function(raw: ident.raw, name: ident.value.lowercased(), inner: inner))
                } else {
                    tokens.append(.other(ident.raw))
                }
                continue
            }
            if ch == "{" || ch == "}" || ch == ";" || ch == "(" || ch == ")" || ch == "[" || ch == "]" {
                tokens.append(.symbol(ch))
                i += 1
                continue
            }
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{0C}" {
                var ws = ""
                while i < c.count, c[i] == " " || c[i] == "\t" || c[i] == "\n" || c[i] == "\r" || c[i] == "\u{0C}" {
                    ws.append(c[i])
                    i += 1
                }
                tokens.append(.whitespace(ws))
                continue
            }
            tokens.append(.other(String(ch)))
            i += 1
        }
        return tokens
    }

    private static func isIdentStart(_ c: [Character], _ i: Int) -> Bool {
        guard i < c.count else { return false }
        let ch = c[i]
        if ch == "\\" { return true }
        if ch == "-" || ch == "_" { return true }
        if SiteHTMLTokenizer.isLetter(ch) { return true }
        return (ch.unicodeScalars.first?.value ?? 0) >= 0x80
    }

    private static func isIdentChar(_ ch: Character) -> Bool {
        if ch == "-" || ch == "_" { return true }
        if SiteHTMLTokenizer.isLetter(ch) { return true }
        if ch.isNumber { return true }
        return (ch.unicodeScalars.first?.value ?? 0) >= 0x80
    }

    /// Reads an identifier, returning both its source and its DECODED value.
    /// The decoded value is what the name tests use: `\75 rl` is `url` to a
    /// browser, and matching on the source would miss it.
    private static func readIdent(_ c: [Character], _ i: inout Int) -> (raw: String, value: String) {
        var raw = "", value = ""
        while i < c.count {
            if c[i] == "\\" {
                let escape = readEscape(c, &i)
                raw += escape.raw
                value += escape.value
                continue
            }
            guard isIdentChar(c[i]) else { break }
            raw.append(c[i])
            value.append(c[i])
            i += 1
        }
        return (raw, value)
    }

    private static func readEscape(_ c: [Character], _ i: inout Int) -> (raw: String, value: String) {
        var raw = "\\"
        i += 1
        guard i < c.count else { return (raw, "") }
        if c[i].isHexDigit {
            var hex = ""
            while i < c.count, c[i].isHexDigit, hex.count < 6 {
                hex.append(c[i])
                raw.append(c[i])
                i += 1
            }
            if i < c.count, c[i] == " " || c[i] == "\t" || c[i] == "\n" || c[i] == "\r" || c[i] == "\u{0C}" {
                raw.append(c[i])
                i += 1
            }
            if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                return (raw, String(Character(scalar)))
            }
            return (raw, "")
        }
        raw.append(c[i])
        let literal = String(c[i])
        i += 1
        return (raw, literal)
    }

    private static func readString(_ c: [Character], _ i: inout Int) -> String {
        let quote = c[i]
        var out = String(quote)
        i += 1
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count {
                out.append(c[i])
                out.append(c[i + 1])
                i += 2
                continue
            }
            out.append(c[i])
            if c[i] == quote { i += 1; return out }
            i += 1
        }
        return out
    }

    /// From an opening `(` to its match, strings and escapes respected.
    /// Returns the contents without the parentheses.
    private static func readBalanced(_ c: [Character], _ i: inout Int) -> String {
        var depth = 1
        var inner = ""
        i += 1
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                let escape = readEscape(c, &i)
                inner += escape.raw
                continue
            }
            if ch == "\"" || ch == "'" {
                inner += readString(c, &i)
                continue
            }
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { i += 1; break }
            }
            inner.append(ch)
            i += 1
        }
        return inner
    }

    // MARK: Rebuilding

    private static func rebuild(_ tokens: [Token]) -> String {
        var out = ""
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case .atKeyword(_, let name):
                if name == "import" {
                    // A request wearing a stylesheet's clothes. The rule runs to
                    // its `;`, or to the end of the block it opens — an
                    // `@import` with no semicolon must not survive because the
                    // next `{` happened to arrive first.
                    i = skipStatement(tokens, from: i + 1)
                    continue
                }
                if name == "font-face" {
                    // A webfont is a request with a shape all its own, and the
                    // one an author has the best excuse for.
                    i = skipAtRuleBlock(tokens, from: i + 1)
                    continue
                }
                out += tokens[i].raw
                i += 1

            case .function(let raw, let name, let inner):
                let base = withoutVendorPrefix(name)
                if base == "url" {
                    // The only URL form that cannot leave the device survives
                    // untouched, quotes and padding or not.
                    out += isDataURI(inner) ? raw + "(" + inner + ")" : "none"
                } else if urlBearing.contains(base) {
                    out += "none"
                } else {
                    out += raw + "(" + rebuild(tokenize(Array(inner))) + ")"
                }
                i += 1

            default:
                out += tokens[i].raw
                i += 1
            }
        }
        return out
    }

    private static func skipStatement(_ tokens: [Token], from: Int) -> Int {
        var i = from
        var depth = 0
        while i < tokens.count {
            if case .symbol(let c) = tokens[i] {
                if c == ";", depth == 0 { return i + 1 }
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth <= 0 { return i + 1 }
                }
            }
            i += 1
        }
        return i
    }

    private static func skipAtRuleBlock(_ tokens: [Token], from: Int) -> Int {
        var i = from
        while i < tokens.count, tokens[i].isWhitespace { i += 1 }
        guard i < tokens.count, tokens[i].isOpenBrace else {
            return skipStatement(tokens, from: from)
        }
        var depth = 0
        while i < tokens.count {
            if case .symbol(let c) = tokens[i] {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
            }
            i += 1
        }
        return i
    }

    private static func withoutVendorPrefix(_ name: String) -> String {
        guard name.hasPrefix("-") else { return name }
        let rest = name.dropFirst()
        guard let dash = rest.firstIndex(of: "-") else { return name }
        return String(rest[rest.index(after: dash)...])
    }

    /// The reference decides with a negative lookahead that backtracks, so any
    /// whitespace before the URI silently costs a legal inlined image. Decide on
    /// the captured contents instead.
    private static func isDataURI(_ inner: String) -> Bool {
        var s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\"") || s.hasPrefix("'") { s = String(s.dropFirst()) }
        return s.lowercased().hasPrefix("data:")
    }

    /// The style ATTRIBUTE test, deliberately WIDER than the cleaner above:
    /// `url` followed by whitespace and a parenthesis, or `@import`, either
    /// case. An attribute that matches is dropped whole rather than cleaned —
    /// there is no author structure in an attribute worth preserving, and one
    /// test is cheaper to get right than one cleaner.
    static func attributeFetches(_ value: String) -> Bool {
        let c = Array(value.lowercased())
        var i = 0
        while i < c.count {
            if c[i] == "@", matches(c, i, "@import") { return true }
            if c[i] == "u", matches(c, i, "url") {
                var j = i + 3
                while j < c.count, c[j].isWhitespace { j += 1 }
                if j < c.count, c[j] == "(" { return true }
            }
            i += 1
        }
        return false
    }

    private static func matches(_ c: [Character], _ i: Int, _ s: String) -> Bool {
        let want = Array(s)
        guard i + want.count <= c.count else { return false }
        for (k, ch) in want.enumerated() where c[i + k] != ch { return false }
        return true
    }
}

// MARK: - The sanitiser

struct SiteSanitizer {
    /// Fetches one bundle file, hash-checked against the manifest. Throwing is
    /// how "not in the bundle" and "the island changed it" both arrive.
    typealias FileFetcher = (String) async throws -> Data

    /// What a page may contain. An ALLOW-LIST, not a list of things to remove:
    /// a deny-list is a promise that we thought of everything, and the web keeps
    /// inventing elements. Anything not named here is UNWRAPPED (its text stays,
    /// the element goes), so an unknown tag costs a page its styling and never
    /// its content.
    static let allowedTags: Set<String> = [
        "html", "head", "body", "title", "style", "meta",
        "div", "span", "p", "br", "hr", "section", "article", "main", "aside", "nav",
        "header", "footer", "figure", "figcaption", "blockquote", "pre", "code", "kbd", "samp",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col",
        "a", "img", "strong", "b", "em", "i", "u", "s", "small", "sub", "sup", "mark",
        "time", "abbr", "cite", "q", "ruby", "rt", "rp", "wbr", "details", "summary",
    ]

    /// Attributes that may survive on any element. Everything else goes, which
    /// covers `on*`, `ping`, `srcset`, `formaction`, `xlink:href`, `background`
    /// and whatever is invented next without us having to name it.
    static let allowedAttributes: Set<String> = [
        "class", "id", "title", "lang", "dir", "alt", "width", "height",
        "colspan", "rowspan", "headers", "scope", "span", "datetime", "cite", "open",
        "start", "reversed", "value", "charset",
    ]

    /// Elements that carry executable or fetching content whatever we do with
    /// their attributes. Removed WITH their children, unlike the unwrap above:
    /// the text inside a `<script>` is code, not prose, and the text inside an
    /// `<svg>` is drawing instructions.
    static let removedTags: Set<String> = [
        "script", "iframe", "object", "embed", "form", "video", "audio",
        "source", "track", "base", "svg", "math", "canvas", "template",
        "noscript", "portal",
    ]

    static let policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'"

    let manifest: SiteManifest
    /// The page's own path inside the bundle, which relative references resolve
    /// against.
    let path: String
    let fetch: FileFetcher

    /// Turn the bundle's HTML into a single self-contained document.
    func inline(_ html: String) async -> String {
        let root = SiteHTMLTreeBuilder.build(SiteHTMLTokenizer.tokenize(html))
        _ = await prepare(root)
        Self.walk(root)
        Self.installPolicy(root)
        return SiteHTMLSerializer.document(root)
    }

    // MARK: The fetching passes, in the order the corpus pins

    /// Returns the node to keep in place of `node`, or nil to drop it with its
    /// children.
    ///
    /// ⚠ Order inside this pass is load bearing. The removal list runs before
    /// anything else — reverse it and `<template>`, not being an allowed tag,
    /// is UNWRAPPED by the walk below, which lifts its content into the
    /// document and hands the web view a live script. `data-rcq-*` is cleared
    /// before the anchor pass, so a page cannot forge the channel between this
    /// sanitiser and our own chrome. And the image pass runs before the walk's
    /// `src` rule, so the only `data:` URIs that reach it are the ones we built
    /// out of verified bytes.
    private func prepare(_ node: SiteHTMLNode) async -> SiteHTMLNode? {
        guard let tag = node.tag else { return node }
        if Self.removedTags.contains(tag) { return nil }

        var element = node
        if tag == "link" {
            guard let style = await inlineStylesheet(node) else { return nil }
            element = style
        } else {
            element.removeAttributes { $0.hasPrefix("data-rcq-") }
            if tag == "img" {
                guard await inlineImage(element) else { return nil }
            }
            if tag == "a" {
                markAnchor(element)
            }
        }

        var kept: [SiteHTMLNode] = []
        for child in element.children {
            if let node = await prepare(child) { kept.append(node) }
        }
        element.children = kept
        return element
    }

    /// A `<link>` is resolved into a `<style>` before the allow-list walk,
    /// which then treats it like any author style block. Only `rel="stylesheet"`
    /// pointing INTO the bundle survives; preload, prefetch, dns-prefetch and
    /// whatever `rel` is invented next are requests with no visible element and
    /// no user action, which is exactly the shape of a read receipt.
    private func inlineStylesheet(_ link: SiteHTMLNode) async -> SiteHTMLNode? {
        let rel = (link.attribute("rel") ?? "").lowercased()
        guard rel == "stylesheet",
              let href = resolveBundlePath(from: path, ref: link.attribute("href") ?? ""),
              manifest.files[href] != nil,
              let bytes = try? await fetch(href) else {
            return nil
        }
        let style = SiteHTMLNode(element: "style")
        style.children = [SiteHTMLNode(text: SiteCSS.clean(SiteText.decode(bytes)))]
        return style
    }

    /// An image is inlined from VERIFIED bytes or it is not shown. Remote is a
    /// request per reader with an IP and a timestamp, which is the metadata this
    /// whole design exists to avoid; anything not in the manifest is never
    /// fetched however ordinary the path looks.
    private func inlineImage(_ img: SiteHTMLNode) async -> Bool {
        guard let src = resolveBundlePath(from: path, ref: img.attribute("src") ?? ""),
              manifest.files[src] != nil,
              let bytes = try? await fetch(src),
              let uri = SiteBytes.dataURI(path: src, bytes: bytes) else {
            return false
        }
        img.setAttribute("src", uri)
        return true
    }

    /// Every anchor loses its href. An internal one is marked with the bundle
    /// path it resolved to and its `title` is OVERWRITTEN with that path — the
    /// author does not get to write the tooltip, because the tooltip is how a
    /// reader checks where a link goes.
    ///
    /// ⚠ An outward target is kept as DATA and nothing else. A click out of the
    /// network is how a reader gets deanonymised; Tor's exit-node problem is one
    /// this design can simply not have.
    private func markAnchor(_ anchor: SiteHTMLNode) {
        let href = anchor.attribute("href") ?? ""
        if let inner = resolveBundlePath(from: path, ref: href), manifest.files[inner] != nil {
            anchor.setAttribute("data-rcq-page", inner)
            anchor.setAttribute("title", inner)
        } else {
            anchor.setAttribute("data-rcq-external", href)
            anchor.setAttribute("title", href)
        }
    }

    // MARK: The allow-list walk

    /// Depth first, so an element's children are already clean by the time the
    /// element itself is unwrapped and they move up a level. Unwrapping without
    /// re-walking would leave an `onmouseover` on whatever was just promoted.
    static func walk(_ element: SiteHTMLNode) {
        guard let tag = element.tag else { return }
        element.attributes = element.attributes.filter { keep(attribute: $0, on: tag) }
        if tag == "style" {
            element.children = [SiteHTMLNode(text: SiteCSS.clean(element.textContent))]
            return
        }
        var out: [SiteHTMLNode] = []
        for child in element.children {
            guard let childTag = child.tag else { out.append(child); continue }
            walk(child)
            if allowedTags.contains(childTag) {
                out.append(child)
            } else {
                out.append(contentsOf: child.children)
            }
        }
        element.children = out
    }

    private static func keep(attribute: (name: String, value: String), on tag: String) -> Bool {
        let name = attribute.name
        if allowedAttributes.contains(name) { return true }
        // The `src` we wrote ourselves, from bytes the manifest covers.
        if tag == "img", name == "src", attribute.value.hasPrefix("data:") { return true }
        if tag == "a", name == "data-rcq-page" || name == "data-rcq-external" { return true }
        // A style attribute may stay only once it can no longer fetch, and then
        // it stays VERBATIM.
        if name == "style" { return !SiteCSS.attributeFetches(attribute.value) }
        return false
    }

    /// Our own policy last, so it is not one of the attributes just stripped,
    /// and PREPENDED so it is the first thing the web view's parser reads.
    ///
    /// It is the second lock, not the first: a `WKWebView` may or may not honour
    /// a `<meta>` policy, which is why every removal above holds on its own.
    ///
    /// The viewport rides in behind it. `WKWebView` lays a document out at 980
    /// points wide when nothing declares a viewport — the desktop-site
    /// fallback Safari has always had — and the reader then gets a page in
    /// miniature it has to pinch at (founder, 02.09). The author's own
    /// `<meta name="viewport">` cannot save it: `name` and `content` are not
    /// allowed attributes, so it left the walk as an empty `<meta>`, exactly
    /// like a page-supplied policy would. Ours therefore always goes in.
    /// ⚠ After the policy, not before: the corpus pins the policy as the first
    /// child of `<head>`.
    static func installPolicy(_ root: SiteHTMLNode) {
        let meta = SiteHTMLNode(element: "meta")
        meta.attributes = [("http-equiv", "Content-Security-Policy"), ("content", policy)]
        let viewport = SiteHTMLNode(element: "meta")
        viewport.attributes = [("name", "viewport"), ("content", "width=device-width, initial-scale=1")]
        if let head = root.children.first(where: { $0.tag == "head" }) {
            head.children.insert(contentsOf: [meta, viewport], at: 0)
        } else {
            let head = SiteHTMLNode(element: "head")
            head.children = [meta, viewport]
            root.children.insert(head, at: 0)
        }
    }
}
