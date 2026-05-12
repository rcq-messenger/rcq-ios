import SwiftUI

/// KOLOBOK emoticon table. Only `:asset:` codes — short text shortcuts
/// like `:)` or `8-)` are intentionally NOT parsed (they tripped on
/// legit text contexts: `8-)` in math, `:/` in URLs, etc). Picker
/// inserts the `:asset:` form directly so users still get visual
/// emoticons without typing-time auto-replace.
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

        add("smile",      "Happy")
        add("sad",        "Sad")
        add("wink",       "Winking")
        add("blum",       "Tongue")
        add("tease",      "Joking")
        add("cray",       "Crying")
        add("air_kiss",   "Kissed")
        add("kiss2",      "Kiss")
        add("blush",      "Embarrassed")
        add("angel",      "Angel")
        add("secret",     "Silent")
        add("wacko",      "Confused")
        add("aggressive", "Angry")
        add("biggrin",    "Laughing")
        add("nea",        "Pensive")
        add("shok",       "Shocked")
        add("dirol",      "Cool")
        add("dance",      "Headphones")
        add("boredom",    "Yawning")
        add("bad",        "Sick")
        add("stop",       "Stop")
        add("kissing",    "Two Kissing")
        add("diablo",     "Devil")
        add("give_rose",  "Red Rose")
        add("bomb",       "Bomb")
        add("good",       "Thumbs Up")
        add("drinks",     "Drink")
        add("heart",      "In Love")

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
