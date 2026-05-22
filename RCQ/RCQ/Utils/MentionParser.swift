import Foundation

/// Parser for `@nickname` mentions in group chat. Resolves nicknames
/// against the current group's member roster; unmatched `@foo` stays
/// as plain text.
enum MentionParser {
    struct Match {
        /// Byte range inside the source string (NSString-style for
        /// AttributedString interop).
        let range: NSRange
        let nickname: String
        let uin: Int
    }

    /// Scan `text` for `@<word>` tokens. A word is letters, digits, or
    /// underscore — matches Telegram's mention rules. Matches that
    /// don't resolve against `members` are dropped (they'll render as
    /// plain text).
    static func mentions(in text: String, members: [RCQGroupMember]) -> [Match] {
        guard !text.isEmpty, !members.isEmpty else { return [] }
        let lookup = Dictionary(
            members.map { ($0.nickname.lowercased(), $0.uin) },
            uniquingKeysWith: { first, _ in first }
        )
        let ns = text as NSString
        var out: [Match] = []
        let pattern = try? NSRegularExpression(pattern: "@([\\p{L}\\p{N}_-]+)")
        pattern?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            let nickRange = m.range(at: 1)
            let nick = ns.substring(with: nickRange)
            if let uin = lookup[nick.lowercased()] {
                out.append(Match(range: m.range, nickname: nick, uin: uin))
            }
        }
        return out
    }
}
