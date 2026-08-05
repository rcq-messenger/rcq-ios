import Foundation

/// Reading a signed payload out of a DNS TXT record over DoH. Mirrors Android
/// `DnsTxt.kt`.
///
/// The relay list reaches clients over exactly two names. Block both and no push
/// of ours arrives again — including the one that would hand out a working
/// mirror. A TXT record read over DoH does not depend on either name: it rides a
/// resolver that is reachable because half the internet needs it to be.
///
/// A resolver cannot forge what it serves. The payload is signed, so a hostile
/// or compelled resolver can only withhold it or replay an old one, and replay
/// is what the version floor in `RelayConfigStore` refuses. That is what makes
/// it reasonable to ask a DOMESTIC resolver, which is often the only one
/// answering on the networks this exists for. What it does leak is that this
/// device asked for our name, so the query rides the tunnel when one is up,
/// exactly like the HTTPS mirrors do.
///
/// Wire format is RFC 8484 rather than any resolver's JSON API, because the JSON
/// one is Cloudflare's and Google's alone — and those two are the most likely to
/// be unreachable precisely where this matters.
enum DnsTxt {

    /// Records we published carry this, so a name that also holds SPF or a
    /// verification string yields ours without guessing.
    private static let prefix = "rcq1:"

    private static let typeTXT = 16
    private static let classIN = 1

    /// A DNS answer is small; anything larger is not one.
    private static let maxResponse = 64 * 1024

    /// DoH endpoints, tried in order, addressed by IP.
    ///
    /// By IP on purpose. Asking a resolver by NAME means resolving that name
    /// through ordinary DNS first — the very thing being tampered with on the
    /// networks this channel exists for. Their certificates carry the addresses
    /// in the SAN, so verification is unaffected.
    ///
    /// ⚠ This list first read `common.dns.yandex.net`, which does not exist:
    /// the one resolver included because it answers inside RU would never have
    /// returned anything. All four below were checked live against a published
    /// record.
    ///
    /// A resolver cannot forge a signed payload, so one that answers beats one
    /// that does not — hence the domestic entry, and four jurisdictions.
    static let resolvers = [
        "https://1.1.1.1/dns-query",      // Cloudflare
        "https://77.88.8.8/dns-query",    // Yandex — answers inside RU
        "https://8.8.8.8/dns-query",      // Google
        "https://9.9.9.9/dns-query",      // Quad9
    ]

    /// Fetch and reassemble the payload published at `name`, or nil.
    ///
    /// A single record's character-strings arrive in order, which is why the
    /// whole payload goes in ONE record: order ACROSS records is not guaranteed
    /// by DNS, so a payload split over several could reassemble into garbage.
    static func fetch(name: String, session: URLSession) async -> String? {
        guard let query = buildQuery(name) else { return nil }
        for resolver in resolvers {
            guard let url = URL(string: resolver) else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            req.httpMethod = "POST"
            req.httpBody = query
            req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: req),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= maxResponse
            else { continue }
            if let value = parseTxt([UInt8](data)) { return value }
        }
        return nil
    }

    /// A minimal query: one question, recursion desired, ID zero as RFC 8484
    /// asks (a cached DoH response must not be keyed on a random id).
    static func buildQuery(_ name: String) -> Data? {
        let labels = name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return nil }
        var out = [UInt8]()
        func u16(_ v: Int) { out.append(UInt8(v >> 8 & 0xFF)); out.append(UInt8(v & 0xFF)) }
        u16(0)          // ID
        u16(0x0100)     // RD
        u16(1)          // QDCOUNT
        u16(0); u16(0); u16(0)
        for label in labels {
            guard let bytes = label.data(using: .ascii) else { return nil }
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
        u16(typeTXT)
        u16(classIN)
        return Data(out)
    }

    /// Pull our payload out of a DNS response, or nil when it is not there.
    ///
    /// Every failure is a nil rather than a thrown error: this parses bytes from
    /// a resolver we do not control, on a path whose whole purpose is to be
    /// tried when other things are already broken, and the caller's next move is
    /// the next source.
    static func parseTxt(_ msg: [UInt8]) -> String? {
        guard msg.count >= 12 else { return nil }
        func u16(_ at: Int) -> Int {
            guard at + 1 < msg.count else { return -1 }
            return Int(msg[at]) << 8 | Int(msg[at + 1])
        }
        let answers = u16(6)
        guard answers > 0 else { return nil }

        var pos = 12
        let questions = u16(4)
        guard questions >= 0 else { return nil }
        for _ in 0..<questions {
            guard let next = skipName(msg, pos) else { return nil }
            pos = next + 4
        }

        for _ in 0..<answers {
            guard let next = skipName(msg, pos) else { return nil }
            pos = next
            guard pos + 10 <= msg.count else { return nil }
            let type = u16(pos)
            let rdLength = u16(pos + 8)
            pos += 10
            guard rdLength >= 0, pos + rdLength <= msg.count else { return nil }
            if type == typeTXT {
                // Character-strings, each length-prefixed, concatenated in the
                // order the record carries them.
                var text = ""
                var p = pos
                let end = pos + rdLength
                while p < end {
                    let len = Int(msg[p])
                    guard p + 1 + len <= end else { return nil }
                    guard let chunk = String(bytes: msg[(p + 1)..<(p + 1 + len)], encoding: .ascii) else { return nil }
                    text += chunk
                    p += 1 + len
                }
                if text.hasPrefix(prefix) { return String(text.dropFirst(prefix.count)) }
            }
            pos += rdLength
        }
        return nil
    }

    /// Advance past a NAME, which may end in a compression pointer. Returns nil
    /// on a malformed one rather than following it, since a pointer chain from
    /// an untrusted response is a loop waiting to happen.
    private static func skipName(_ msg: [UInt8], _ start: Int) -> Int? {
        var pos = start
        while true {
            guard pos < msg.count else { return nil }
            let len = Int(msg[pos])
            if len == 0 { return pos + 1 }
            if len & 0xC0 == 0xC0 { return pos + 2 <= msg.count ? pos + 2 : nil }
            if len > 63 { return nil }
            pos += 1 + len
        }
    }
}
