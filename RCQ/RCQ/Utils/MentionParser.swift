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

    /// Scan `text` for `@<member nick>` mentions by ROSTER longest-match, not a
    /// fixed char-class regex: at each `@`, take the LONGEST member nickname that
    /// is a case-insensitive prefix of the following text. This makes nicks with
    /// spaces or punctuation (e.g. "JO f3 JO", ".:example") clickable — the old
    /// `@([\p{L}\p{N}_.-]+)` regex stopped at the first space/colon, so those
    /// mentions never linkified. Unmatched `@foo` stays plain text.
    static func mentions(in text: String, members: [RCQGroupMember]) -> [Match] {
        guard !text.isEmpty, !members.isEmpty else { return [] }
        // Longest nickname first, so the first prefix hit is the longest match.
        let sorted = members
            .filter { !$0.nickname.isEmpty }
            .sorted { $0.nickname.count > $1.nickname.count }
        let ns = text as NSString
        let len = ns.length
        var out: [Match] = []
        var i = 0
        while i < len {
            let atRange = ns.range(of: "@", options: [], range: NSRange(location: i, length: len - i))
            if atRange.location == NSNotFound { break }
            let at = atRange.location
            let afterStart = at + 1
            let afterLower = (afterStart < len ? ns.substring(from: afterStart) : "").lowercased()
            var hit: (uin: Int, nickLen16: Int, nick: String)?
            for mem in sorted {
                if afterLower.hasPrefix(mem.nickname.lowercased()) {
                    let nickLen16 = (mem.nickname as NSString).length
                    // Boundary so "@bob" doesn't match inside "@bobsled".
                    let tailIdx = afterStart + nickLen16
                    let boundaryOk: Bool
                    if tailIdx >= len {
                        boundaryOk = true
                    } else {
                        let c = ns.substring(with: NSRange(location: tailIdx, length: 1)).first
                        boundaryOk = !(c?.isLetter ?? false) && !(c?.isNumber ?? false)
                    }
                    if boundaryOk {
                        hit = (mem.uin, nickLen16, mem.nickname)
                        break
                    }
                }
            }
            if let hit {
                out.append(Match(range: NSRange(location: at, length: 1 + hit.nickLen16),
                                 nickname: hit.nick, uin: hit.uin))
                i = at + 1 + hit.nickLen16
            } else {
                i = at + 1
            }
        }
        return out
    }
}
