import Foundation

/// Day/hour bucketing must happen in the stats timezone, not the machine's.
///
/// `packages/core/src/timezone.ts` defaults to `Asia/Shanghai`, and every daily
/// and hourly row the API returns is already keyed by a local date in that zone.
/// Range windows therefore have to be computed the same way or a day would be
/// dropped at the boundary.
enum StatsClock {
    static let defaultTimeZone = "Asia/Shanghai"

    static func zone(_ identifier: String?) -> TimeZone {
        guard let identifier, let zone = TimeZone(identifier: identifier) else {
            return TimeZone(identifier: defaultTimeZone) ?? .gmt
        }
        return zone
    }

    private static func calendar(_ identifier: String?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone(identifier)
        return calendar
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `localDateNow()` — today in the stats timezone, `YYYY-MM-DD`.
    static func today(_ identifier: String? = nil) -> String {
        let formatter = dateFormatter
        formatter.timeZone = zone(identifier)
        return formatter.string(from: Date())
    }

    /// `localDateDaysAgo(days)` — inclusive window start, so `days = 1` is today
    /// and `days = 7` is today-6 … today.
    static func windowStart(days: Int, _ identifier: String? = nil) -> String {
        let span = max(1, days)
        guard let todayDate = dateFormatter.date(from: today(identifier)) else {
            return today(identifier)
        }
        let calendar = calendar(identifier)
        let start = calendar.date(byAdding: .day, value: -(span - 1), to: todayDate) ?? todayDate
        let formatter = dateFormatter
        formatter.timeZone = zone(identifier)
        return formatter.string(from: start)
    }

    /// Shifts a `YYYY-MM-DD` string by whole days (pure calendar arithmetic).
    static func addDays(_ days: Int, to date: String, _ identifier: String? = nil) -> String {
        let formatter = dateFormatter
        formatter.timeZone = zone(identifier)
        guard let parsed = formatter.date(from: date) else { return date }
        let calendar = calendar(identifier)
        let shifted = calendar.date(byAdding: .day, value: days, to: parsed) ?? parsed
        return formatter.string(from: shifted)
    }

    /// Hour of day (0…23) for an ISO instant in the stats timezone.
    static func hour(of iso: String, _ identifier: String? = nil) -> Int {
        guard let date = parseISO(iso) else { return 0 }
        let calendar = calendar(identifier)
        return calendar.component(.hour, from: date)
    }

    static func date(of iso: String, _ identifier: String? = nil) -> String {
        guard let date = parseISO(iso) else { return iso }
        let formatter = dateFormatter
        formatter.timeZone = zone(identifier)
        return formatter.string(from: date)
    }

    static func parseISO(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// `2026-10-07` → `10/07`-style axis label without a DateFormatter per call.
    static func axisLabel(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(parts[1])/\(parts[2])"
    }

    /// Weekday index with Monday = 0, matching `DASHBOARD_WEEKDAYS`.
    static func mondayFirstWeekday(_ date: String, _ identifier: String? = nil) -> Int {
        let formatter = dateFormatter
        formatter.timeZone = zone(identifier)
        guard let parsed = formatter.date(from: date) else { return 0 }
        let calendar = calendar(identifier)
        // Calendar weekday: 1 = Sunday … 7 = Saturday.
        let weekday = calendar.component(.weekday, from: parsed)
        return (weekday + 5) % 7
    }

    /// Weekday index with Sunday = 0, matching the heatmap's `日一二三四五六` rows.
    static func sundayFirstWeekday(_ date: String, _ identifier: String? = nil) -> Int {
        let formatter = dateFormatter
        formatter.timeZone = zone(identifier)
        guard let parsed = formatter.date(from: date) else { return 0 }
        let calendar = calendar(identifier)
        return calendar.component(.weekday, from: parsed) - 1
    }

    /// Month number (1…12) for a `YYYY-MM-DD` string.
    static func month(_ date: String) -> Int {
        let parts = date.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return 1 }
        return month
    }
}
