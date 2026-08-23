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
    /// ⚠ Rounded, never truncated: 1949 is "1.9K" and 1950 is "2K". Truncating
    /// makes a room look smaller than it is at every boundary, which is the one
    /// direction a member count must not be wrong in. The arithmetic below is
    /// deliberately written in the same order as the web's
    /// `Math.round((n / unit) * 10) / 10` so both sides make the same IEEE-754
    /// rounding decision on the same input.
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
            // Rounding up can push a value into the next unit: 999 950 scales
            // to "1000K". Hand it to the M branch instead, exactly as the web
            // does, so no client ever prints a four-digit thousands figure.
            return s == "1000K" ? Self.short(self, unit: 1_000_000, suffix: "M") : s
        }
        return Self.short(self, unit: 1_000_000, suffix: "M")
    }

    /// Divide, keep one rounded decimal, drop it when it is zero. Locale-
    /// agnostic on purpose: `String(format:)` honours the C locale ("." for
    /// the decimal point), which is what the web prints and what keeps the
    /// badge identical across RU + EN so the layout doesn't shift.
    private static func short(_ n: Int, unit: Int, suffix: String) -> String {
        let scaled = ((Double(n) / Double(unit)) * 10).rounded() / 10
        let whole = Int(scaled)
        if scaled == Double(whole) { return "\(whole)\(suffix)" }
        return String(format: "%.1f", scaled) + suffix
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
