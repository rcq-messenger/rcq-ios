import SwiftUI

/// KOLOBOK emoticon table. Only `:asset:` codes — short text shortcuts
/// like `:)` or `8-)` aren't parsed (they collide with legit text
/// contexts: `8-)` in math, `:/` in URLs, etc). Picker inserts the
/// `:asset:` form directly so users still get visual emoticons without
/// typing-time auto-replace.
enum Emoticons {
    struct Entry: Hashable {
        let code: String
        let asset: String
        let name: String
    }

    static let entries: [Entry] = {
        var raw: [Entry] = []
        func add(_ asset: String, _ name: String) {
            raw.append(Entry(code: ":\(asset):", asset: asset, name: name))
        }

        // Kolobok ICQ "set 14" — same names + order as the Android palette
        // (Emoticon.kt) so a :code: / reaction renders identically on both.
        add("smile",        "Happy")
        add("biggrin",      "Laughing")
        add("lol",          "LOL")
        add("rofl",         "ROFL")
        add("good",         "Thumbs Up")
        add("give_heart",   "Heart")
        add("man_in_love",  "In Love")
        add("give_rose",    "Rose")
        add("kiss",         "Kiss")
        add("kiss3",        "Smooch")
        add("air_kiss",     "Air Kiss")
        add("blush",        "Embarrassed")
        add("i_am_so_happy", "So Happy")
        add("dance",        "Dancing")
        add("music",        "Music")
        add("cool",         "Cool")
        add("gamer",        "Gamer")
        add("drinks",       "Cheers")
        add("hi",           "Hi")
        add("bye2",         "Bye")
        add("blum1",        "Tongue")
        add("mocking",      "Teasing")
        add("crazy",        "Crazy")
        add("wacko1",       "Wacko")
        add("nea",          "Pensive")
        add("scratch_one-s_head", "Thinking")
        add("unknown",      "Dunno")
        add("shok",         "Shocked")
        add("sad",          "Sad")
        add("cray",         "Crying")
        add("pardon",       "Pardon")
        add("sorry",        "Sorry")
        add("mad",          "Angry")
        add("ireful",       "Furious")
        add("shout",        "Shouting")
        add("bad",          "Sick")
        add("diablo",       "Devil")
        add("bomb",         "Bomb")
        add("girl_angel",   "Angel")
        add("hang1",        "Hang")

        return raw.sorted { $0.code.count > $1.code.count }
    }()

    /// Distinct default emoticons for the picker grid (one per asset).
    static var paletteAssets: [(asset: String, name: String, primaryCode: String)] {
        var seen = Set<String>()
        var out: [(String, String, String)] = []
        for e in entries {
            if seen.insert(e.asset).inserted {
                out.append((e.asset, e.name, e.code))
            }
        }
        return out
    }

    /// Default palette + every equipped cosmetic pack appended in equip order.
    static func paletteAssets(
        equippedKindIDs: [String],
    ) -> [(asset: String, name: String, primaryCode: String)] {
        var palette = paletteAssets
        var seenAssets = Set(palette.map { $0.asset })
        for kindID in equippedKindIDs {
            for entry in CosmeticPacks.entries(for: kindID) where seenAssets.insert(entry.asset).inserted {
                palette.append((entry.asset, entry.name, entry.primaryCode))
            }
        }
        return palette
    }

    enum Token: Hashable {
        case text(String)
        case emoticon(asset: String, code: String)
    }

    private static let allEntries: [Entry] = {
        let extras: [Entry] = CosmeticPacks.allKindIDs.flatMap { kindID in
            CosmeticPacks.entries(for: kindID).map {
                Entry(code: $0.primaryCode, asset: $0.asset, name: $0.name)
            }
        }
        return (entries + extras).sorted { $0.code.count > $1.code.count }
    }()

    static func tokenize(_ text: String) -> [Token] {
        return tokenize(text, table: allEntries)
    }

    static func tokenize(_ text: String, table: [Entry]) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        let chars = Array(text)
        var idx = 0
        while idx < chars.count {
            var matched: (code: String, asset: String)? = nil
            // Codes are all `:name:`-shaped (5+ chars), so checking only
            // at every position is unambiguous enough to drop the old
            // word-boundary gate — that gate predates the short-shortcut
            // removal (`:)`, `:/` etc.) and was the reason two picker
            // taps in a row produced `:smile:` rendered + literal
            // `:wink:` text. Now back-to-back inserts tokenize cleanly.
            // The leading `:` plus the closing `:` are enough boundary
            // — URL content like `https://...` never closes with the
            // exact asset name + `:`.
            for entry in table {
                if matchesAt(chars: chars, idx: idx, code: entry.code) {
                    matched = (entry.code, entry.asset)
                    break
                }
            }
            if let m = matched {
                if !buffer.isEmpty {
                    tokens.append(.text(buffer))
                    buffer = ""
                }
                tokens.append(.emoticon(asset: m.asset, code: m.code))
                idx += m.code.count
            } else {
                buffer.append(chars[idx])
                idx += 1
            }
        }
        if !buffer.isEmpty { tokens.append(.text(buffer)) }
        return tokens
    }

    private static func matchesAt(chars: [Character], idx: Int, code: String) -> Bool {
        let cc = Array(code)
        guard idx + cc.count <= chars.count else { return false }
        for k in 0..<cc.count where chars[idx + k] != cc[k] { return false }
        return true
    }
}
