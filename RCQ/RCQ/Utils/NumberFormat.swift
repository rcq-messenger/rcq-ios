import Foundation

extension Int {
    /// Compact short-form representation for counters where the
    /// raw integer would dominate the layout. Mirrors what users
    /// expect from social-style "1.2K" / "2.7M" badges:
    ///   • < 1_000        → exact ("0", "1", "999")
    ///   • 1_000 …        → "1.2K", trimming a trailing ".0K"
    ///   • 1_000_000 …    → "1.2M", same trim
    ///   • 1_000_000_000+ → "1.2B"
    /// Always positive at the call sites we use it for (reputation
    /// can't go negative), but we handle negatives defensively by
    /// prepending the sign and operating on the absolute value.
    var compactCount: String {
        let n = self
        let absVal = n < 0 ? -n : n
        let sign = n < 0 ? "-" : ""
        if absVal < 1_000 { return "\(sign)\(absVal)" }
        if absVal < 1_000_000 {
            return "\(sign)\(Self.formatScaled(absVal, divisor: 1_000))K"
        }
        if absVal < 1_000_000_000 {
            return "\(sign)\(Self.formatScaled(absVal, divisor: 1_000_000))M"
        }
        return "\(sign)\(Self.formatScaled(absVal, divisor: 1_000_000_000))B"
    }

    /// Divide, keep one decimal, drop a trailing `.0`. Locale-agnostic
    /// on purpose — the compact badge is identical across RU + EN so
    /// the layout doesn't shift between languages.
    private static func formatScaled(_ value: Int, divisor: Int) -> String {
        let scaled = Double(value) / Double(divisor)
        // `String(format:)` honours the C locale (`.` for decimal),
        // which matches what social apps display globally.
        let s = String(format: "%.1f", scaled)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
