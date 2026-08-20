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

    /// 20 extra hand-picked koloboks (founder's selection) the user can add to
    /// their composer panel / reactions via the customise sheet, on top of the
    /// default palette below. Asset names are the `:code:` wire form and MUST be
    /// bundled identically on iOS + Android (matches Emoticon.kt `extraKoloboks`).
    static let extraKoloboks: [String] = [
        "Cherna_01", "FinouCat_02", "Koshechka_06", "Laie_74", "Mauridia_02",
        "Rulezzz_03", "WhiteVoid_1", "d_clock", "kirtsun_05", "l_girl_kiss",
        "l_lovers", "l_teddy", "snoozer_likelinux_man", "viannen_03", "viannen_06",
        "viannen_09", "viannen_35", "viannen_48", "viannen_76", "viannen_88",
    ]

    /// The "standart" Kolobok set (258 glyphs), bundled on every client.
    ///
    /// Kept as a plain list rather than 258 hand-written rows because the display
    /// name is mechanical (`to_pick_ones_nose` → "To pick ones nose") and because
    /// the three clients MUST agree on it exactly: a `:code:` this list is missing
    /// renders as raw text on that platform and nowhere else.
    ///
    /// ⚠ Additive on purpose. The older set stays bundled even where this one
    /// carries no replacement: those codes are already sitting in people's
    /// history, and dropping an asset turns a smiley they sent last week into
    /// `:smile:`.
    static let standardPack: [String] = [
        "acute", "aggressive", "agree", "aikido", "air_kiss", "alcoholic", "angel",
        "assassin", "bad", "banned", "beach", "beee", "beta", "big_boss", "black_eye",
        "blind", "blum2", "blum3", "blush2", "boast", "boredom", "brunette", "buba",
        "buba_phone", "butcher", "censored", "clapping", "comando", "cray", "cray2",
        "crazy", "crazy_pilot", "curtsey", "dance", "dance2", "dance3", "dance4",
        "dash1", "dash2", "dash3", "declare", "ded_moroz", "ded_snegurochka",
        "ded_snegurochka2", "dinamo", "dirol", "dntknw", "don-t_mention", "download",
        "drinks", "dwarf", "elf", "facepalm", "fan_1", "fans", "feminist",
        "feminist_en", "first_move", "flirt", "focus", "fool", "friends", "gamer1",
        "gamer2", "gamer3", "gamer4", "girl_blum", "girl_blum2", "girl_cray",
        "girl_cray2", "girl_cray3", "girl_crazy", "girl_dance", "girl_drink1",
        "girl_drink2", "girl_drink3", "girl_drink4", "girl_haha", "girl_hide",
        "girl_hospital", "girl_impossible", "girl_in_love", "girl_mad",
        "girl_prepare_fish", "girl_sad", "girl_sigh", "girl_smile",
        "girl_to_take_umbrage", "girl_to_take_umbrage2", "girl_wacko", "girl_werewolf",
        "girl_wink", "girl_witch", "give_heart", "give_rose", "good", "good2", "good3",
        "heat", "help", "hi", "hunter", "hysteric", "i-m_so_happy", "ireful1",
        "ireful2", "ireful3", "jester", "king", "king2", "kiss", "kiss2", "kiss3",
        "laugh1", "laugh2", "laugh3", "lazy", "lazy2", "lazy3", "locomotive", "mail1",
        "mamba", "man_in_love", "mda", "meeting", "moil", "morpheus", "mosking",
        "music", "music2", "nea", "negative", "neo", "new_russian", "nhl", "nhl2",
        "nhl3", "nhl_checking", "nhl_crach", "nhl_fight", "no2", "offtopic", "ok",
        "on_the_quiet", "on_the_quiet2", "orc", "padonak", "paint", "paint2", "paint3",
        "paladin", "pardon", "parting", "parting2", "party", "patsak", "phi", "pilot",
        "pioneer", "pioneer_smoke", "pleasantry", "pogranichnik", "polling", "popcorm1",
        "popcorm2", "prankster", "prankster2", "preved", "protest", "punish", "punish2",
        "queen", "rabbi", "rap", "read", "resent", "rofl", "russian", "sad", "santa",
        "santa2", "santa3", "sarcasm", "sarcastic", "sarcastic_blum", "sarcastic_hand",
        "scare", "scare2", "scenic", "sclerosis", "scout", "scout_en",
        "scratch_one-s_head", "search", "secret", "shablon_01", "shablon_02", "shablon_03",
        "shablon_04", "shout", "slow", "slow_en", "smile3", "smoke", "snegurochka",
        "snooks", "sorry", "sorry2", "spartak", "spruce_up", "stinker", "stop",
        "sun_bespectacled", "superman", "superman2", "superstition", "swoon", "swoon2",
        "take_example", "taunt", "tease", "telephone", "tender", "thank_you",
        "thank_you2", "this", "to_babruysk", "to_become_senile", "to_clue",
        "to_keep_order", "to_pick_ones_nose", "to_pick_ones_nose2",
        "to_pick_ones_nose3", "to_pick_ones_nose_eat", "to_take_umbrage", "tommy",
        "training1", "triniti", "umnik", "umnik2", "vampire", "victory", "vinsent",
        "wacko", "wacko2", "warning", "warning2", "whistle", "whistle2", "whistle3",
        "wild", "wink3", "wizard", "yahoo", "yes2", "yes3", "yes4", "yu"
    ]

    /// "to_pick_ones_nose" → "To pick ones nose". Only for the standard pack;
    /// the curated set below keeps its hand-written names.
    private static func displayName(for asset: String) -> String {
        let words = asset.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
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

        // Extra koloboks — added to the entry table (not just a side list) so a
        // peer's `:viannen_03:` tokenizes + renders here too, not just shows as
        // text. They also become pickable in the customise sheet via `fullSet`.
        for extra in Emoticons.extraKoloboks { add(extra, extra) }
        // Appended last so a name the curated set already spells out wins.
        for asset in Emoticons.standardPack where !raw.contains(where: { $0.asset == asset }) {
            add(asset, displayName(for: asset))
        }

        return raw.sorted { $0.code.count > $1.code.count }
    }()

    /// Distinct emoticons offered in the picker grid — the CURRENT pack, and
    /// only it.
    ///
    /// The older set stays bundled and stays tokenizable (see `allEntries`), but
    /// it is not offered any more: those assets exist so a `:smile:` somebody
    /// sent last week still renders as a smiley instead of turning into raw
    /// text. Deleting them would rewrite history; showing them would mean two
    /// drawing styles in one grid.
    static var paletteAssets: [(asset: String, name: String, primaryCode: String)] {
        standardPack.map { ($0, displayName(for: $0), ":\($0):") }
    }

    /// Every bundled emoticon asset (palette + extra koloboks), in asset order —
    /// the full pickable set the customise sheet offers. Extras are already part
    /// of `entries`, so `paletteAssets` covers them.
    static var fullSet: [String] { paletteAssets.map { $0.asset } }

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

    /// Table pre-compiled for matching: codes as `[Character]`, bucketed by
    /// first character. Bucket order must preserve table order — longest code
    /// first — so the first hit is still the longest match.
    private struct MatchTable {
        let buckets: [Character: [(chars: [Character], code: String, asset: String)]]

        init(_ table: [Entry]) {
            var buckets: [Character: [(chars: [Character], code: String, asset: String)]] = [:]
            for entry in table {
                let cc = Array(entry.code)
                guard let first = cc.first else { continue }
                buckets[first, default: []].append((cc, entry.code, entry.asset))
            }
            self.buckets = buckets
        }
    }

    private static let allMatchTable = MatchTable(allEntries)

    static func tokenize(_ text: String) -> [Token] {
        return tokenize(text, table: allMatchTable)
    }

    static func tokenize(_ text: String, table: [Entry]) -> [Token] {
        return tokenize(text, table: MatchTable(table))
    }

    private static func tokenize(_ text: String, table: MatchTable) -> [Token] {
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
            if let candidates = table.buckets[chars[idx]] {
                for entry in candidates {
                    if matchesAt(chars: chars, idx: idx, code: entry.chars) {
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

    private static func matchesAt(chars: [Character], idx: Int, code: [Character]) -> Bool {
        guard idx + code.count <= chars.count else { return false }
        for k in 0..<code.count where chars[idx + k] != code[k] { return false }
        return true
    }
}
