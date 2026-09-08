import Foundation

extension Int {
    /// Compact short-form representation for counters where the raw integer
    /// would dominate the layout (founder item 27: a room of 12 480 printed in
    /// full is nine characters of noise in a row that is mostly a name).
    ///
    /// ⚠ This is a MIRROR, not an independent implementation. The canonical
    /// rules live in `web-chat/src/lib/format-count.ts` and every client is
    /// expected to follow them to the character, so the same room never reads
    /// "9,999" in a browser and "10K" on a phone. In full:
    ///   • below 1000          → the exact number. 999 is "999", not "1K".
    ///   • 1000 and above      → thousands with ONE decimal, and the decimal is
    ///                           dropped when it is zero: 1000 → "1K",
    ///                           1100 → "1.1K", 12 480 → "12.5K".
    ///   • 1 000 000 and above → the same shape on "M": 1 500 000 → "1.5M".
    ///
    /// ⚠⚠ TRUNCATED, never rounded, and this file said the opposite for a
    /// fortnight. The rule was settled on 23.08 in
    /// `web-chat/src/lib/format-count.ts`: a count that reads HIGHER than the
    /// room actually is claims people who are not in it, so 1999 members is
    /// "1.9K" and never "2K". The web and Android were changed then; this was
    /// not, and it kept rounding while its own comment insisted it was the
    /// mirror. RCQ Beta at 2273 members therefore read "2.3K" on an iPhone and
    /// "2.2K" on the same account's Android, which is exactly how the tester
    /// found it (report #956, vss, 08.09).
    ///
    /// The arithmetic below is now the web's, line for line, in integer
    /// division only: there is no floating-point rounding mode left for two
    /// clients to disagree about.
    ///
    ///     tenths = n * 10 / unit      // integer division, truncating
    ///     whole  = tenths / 10
    ///     frac   = tenths % 10
    ///
    /// Boundaries all three clients must agree on: 999 → "999", 1000 → "1K",
    /// 1999 → "1.9K", 9999 → "9.9K", 999999 → "999.9K", 1000000 → "1M".
    ///
    /// ⚠ The suffixes are NOT translated, the way a unit symbol is not: they
    /// are the same letters in every language we ship, so a localised "тыс."
    /// here would disagree with the browser on the same screen. There is no "B"
    /// branch for the same reason: the web has none, so 1 500 000 000 reads
    /// "1500M" on every client rather than "1.5B" on one of them.
    ///
    /// Zero and anything below it read "0": a member count is never negative,
    /// and a stray minus in a header is worse than a zero.
    var compactCount: String {
        if self <= 0 { return "0" }
        if self < 1_000 { return "\(self)" }
        if self < 1_000_000 {
            let s = Self.short(self, unit: 1_000, suffix: "K")
            // Kept from the rounding era, where 999 950 scaled to "1000K".
            // Truncation cannot reach it, and the web keeps the same guard:
            // a branch that can no longer fire is cheaper than one client
            // quietly losing a rule the others still have.
            return s == "1000K" ? Self.short(self, unit: 1_000_000, suffix: "M") : s
        }
        return Self.short(self, unit: 1_000_000, suffix: "M")
    }

    /// Divide, keep one rounded decimal, drop it when it is zero. Locale-
    /// agnostic on purpose: `String(format:)` honours the C locale ("." for
    /// the decimal point), which is what the web prints and what keeps the
    /// badge identical across RU + EN so the layout doesn't shift.
    private static func short(_ n: Int, unit: Int, suffix: String) -> String {
        // Integer arithmetic only, in the web's order: `n * 10 / unit` on two
        // whole numbers, not `(n / unit) * 10` on a Double.
        let tenths = n * 10 / unit
        let whole = tenths / 10
        let frac = tenths % 10
        return frac == 0 ? "\(whole)\(suffix)" : "\(whole).\(frac)\(suffix)"
    }
}

/// The label a group's member count wears wherever one is printed: the chat
/// header, the list row, the search result, the join sheet, the forward picker.
///
/// One helper rather than the same ternary copy-pasted at nine call sites,
/// which is how the tree ended up with a hardcoded English "member(s)" in the
/// forward picker and a raw five-digit count in the header.
///
/// Below a thousand it stays exact and keeps the singular/plural forms the
/// translations already carry. From a thousand up it switches to the compact
/// form (`contact_list.members_compact`, "%@ members"), because that is the
/// point where the number starts fighting the name next to it for the row.
enum MemberCountLabel {
    static func text(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "contact_list.members_compact".localized, count.compactCount)
        }
        return String(
            format: (count == 1 ? "contact_list.members_one" : "contact_list.members_many").localized,
            count
        )
    }
}
