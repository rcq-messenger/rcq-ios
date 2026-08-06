import Foundation

enum DateFormatters {
    /// `2026-08-07`, fixed locale on purpose: this names a file, so it has to
    /// sort and read the same on every device rather than follow the region.
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayDivider: DateFormatter = {
        let f = DateFormatter()
        // Compact divider format: "Mon, 29 Apr". Year is dropped — chat history
        // rarely needs it and it keeps the line short.
        f.dateFormat = "EEE, d MMM"
        return f
    }()

    static let receivedWhileAway: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()
}

enum DayKey: Hashable {
    case day(year: Int, month: Int, dayOfYear: Int)

    static func from(_ date: Date) -> DayKey {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return .day(year: comps.year ?? 0, month: comps.month ?? 0, dayOfYear: comps.day ?? 0)
    }
}
