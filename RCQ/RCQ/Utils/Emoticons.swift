import SwiftUI

/// KOLOBOK emoticon table extracted from the Adium pack's Emoticons.plist.
/// Tokenizer matches longest shortcodes first, so entries sort by length at runtime.
enum Emoticons {
    struct Entry: Hashable {
        let code: String
        let asset: String
        let name: String
    }

    static let entries: [Entry] = {
        var raw: [Entry] = []
        func add(_ asset: String, _ name: String, _ codes: [String]) {
            for c in codes { raw.append(Entry(code: c, asset: asset, name: name)) }
        }

        add("smile",      "Happy",            [":-)", ":)", "=)", ":smile:"])
        add("sad",        "Sad",              [":-(", ":("])
        add("wink",       "Winking",          [";-)", ";)"])
        add("blum",       "Tongue",           [":-P", ":P", ":-p", ":p"])
        add("tease",      "Joking",           ["*JOKINGLY*"])
        add("cray",       "Crying",           [":'(", ":'((", ":(("])
        add("air_kiss",   "Kissed",           ["*KISSED*"])
        add("kiss2",      "Kiss",             [":-*", ":*"])
        add("blush",      "Embarrassed",      [":-[", ":["])
        add("angel",      "Angel",            ["O:-)", "O:)"])
        add("secret",     "Silent",           [":-X", ":X"])
        add("wacko",      "Confused",         [":-$", ":$"])
        add("aggressive", "Angry",            [">:o", ">:O"])
        add("biggrin",    "Laughing",         [":-D", ":D", ":))", ":-))"])
        add("nea",        "Pensive",          [":-\\", ":\\", ":/", ":-/"])
        add("shok",       "Shocked",          [":-O", ":O", ":-o", ":o", ":-0", ":0", "=-O"])
        add("dirol",      "Cool",             ["8-)", "8)", "B-)", "B)"])
        add("dance",      "Headphones",       ["[:-}", "[:-)", "[:}", "[:)"])
        add("boredom",    "Yawning",          ["*TIRED*"])
        add("bad",        "Sick",             [":-!", ":!"])
        add("stop",       "Stop",             ["*STOP*"])
        add("kissing",    "Two Kissing",      ["*KISSING*", ":**:"])
        add("diablo",     "Devil",            ["]:->", "]:>", ">:)", ">:-)", "}:->"])
        add("give_rose",  "Red Rose",         ["@}->--", "@>->--", "@>->-", "@}->-", "@}-:--"])
        add("bomb",       "Bomb",             ["@="])
        add("good",       "Thumbs Up",        ["*THUMBS UP*"])
        add("drinks",     "Drink",            ["*DRINK*"])
        add("heart",      "In Love",          ["*IN LOVE*", "<3"])

        // Longest first so a shorter prefix doesn't clip a longer shortcode.
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
            // Word-boundary gate so :/ in https:// doesn't tokenize as a frowny.
            let atBoundary = (idx == 0) || chars[idx - 1].isWhitespace
            if atBoundary {
                for entry in table {
                    if matchesAt(chars: chars, idx: idx, code: entry.code) {
                        matched = (entry.code, entry.asset)
                        break
                    }
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
