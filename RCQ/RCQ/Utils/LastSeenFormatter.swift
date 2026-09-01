import Foundation

/// "Last seen" in WORDS, and the only place that answers the question.
///
/// ⚠⚠ Why words. The island coarsens `last_seen` to the HOUR before it serves
/// it (A7, `coarse_last_seen`), so printing "47 минут назад" hands the reader a
/// precision the number does not have. Buckets say exactly as much as we know.
///
/// ⚠⚠ Why ONE copy. This started as a numeric formatter here plus two identical
/// word-based copies pasted into ContactListView and ChatView. On 31.08 the two
/// copies were updated and this one was missed, so the contact list and the
/// chat header spoke in words while the PROFILE page kept printing a clock
/// (founder, 01.09). Before that, in the same week, a change to one of the two
/// copies left the other printing raw localization keys. Two misses in a row
/// from the same shape, so there is now one function and the views call it.
/// Do not paste a fourth.
///
/// Calendar days, not 24-hour blocks: "yesterday" has to mean yesterday to a
/// person, not "between 24 and 48 hours ago".
enum LastSeenText {

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 3600 { return "contact.last_seen.recently".localized }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "contact.last_seen.today".localized }
        if cal.isDateInYesterday(date) { return "contact.last_seen.yesterday".localized }
        let midnight = cal.startOfDay(for: now)
        if date >= cal.date(byAdding: .day, value: -6, to: midnight) ?? midnight {
            return "contact.last_seen.this_week".localized
        }
        if date >= cal.date(byAdding: .day, value: -29, to: midnight) ?? midnight {
            return "contact.last_seen.this_month".localized
        }
        return "contact.last_seen.long_ago".localized
    }
}
