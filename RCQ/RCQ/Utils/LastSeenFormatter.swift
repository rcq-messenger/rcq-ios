import Foundation

/// Cheap relative-time renderer for the "Last seen X" UserInfoView
/// subtitle. Resolves to coarse buckets ("just now", "5 minutes ago",
/// "yesterday", "Mar 12") instead of an exact timestamp — that way
/// the field doesn't double as a precise activity tracker for
/// stalkers, even when visibility is set to `everyone`.
final class LastSeenFormatter: @unchecked Sendable {
    static let shared = LastSeenFormatter()

    private let medium: DateFormatter

    private init() {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        self.medium = f
    }

    /// Returns a coarse human label routed through the localization
    /// table. Bucket boundaries:
    ///   - <1 min  → "только что" / "just now"
    ///   - <60 min → "N минут назад"
    ///   - <24 h   → "N часов назад"
    ///   - yesterday calendar-day → "вчера"
    ///   - <7 days → "N дней назад"
    ///   - older   → medium dateStyle (locale-aware via DateFormatter)
    ///
    /// Earlier version hard-coded English plurals — RU users saw
    /// "1 hour ago" instead of "1 час назад". DateFormatter's
    /// `medium` style already locales correctly; only the relative
    /// strings needed routing through `.localized`.
    func relative(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "last_seen.just_now".localized
        }
        if interval < 60 * 60 {
            let mins = Int(interval / 60)
            return String(format: pluralKey(prefix: "last_seen.minute", n: mins).localized, mins)
        }
        if interval < 24 * 60 * 60 {
            let hrs = Int(interval / 3600)
            return String(format: pluralKey(prefix: "last_seen.hour", n: hrs).localized, hrs)
        }
        let cal = Calendar.current
        if cal.isDateInYesterday(date) { return "last_seen.yesterday".localized }
        if interval < 7 * 24 * 60 * 60 {
            let days = Int(interval / 86_400)
            return String(format: pluralKey(prefix: "last_seen.day", n: days).localized, days)
        }
        return medium.string(from: date)
    }

    /// Russian-grammar-aware plural picker. The standard CLDR rule
    /// for ru: ONE for n%10==1 except teens (11), FEW for n%10 in
    /// 2…4 except teens (12-14), MANY for everything else (0, 5-20,
    /// 25, 30, etc.). English collapses to one/few since there are
    /// only 2 plural forms; the EN strings table reuses keys.
    private func pluralKey(prefix: String, n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return prefix + "_one" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return prefix + "_few" }
        return prefix + "_many"
    }
}
