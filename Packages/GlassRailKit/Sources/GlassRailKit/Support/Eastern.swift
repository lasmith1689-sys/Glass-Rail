import Foundation

/// Every time in this app is an NJ Transit time, so it is always Eastern,
/// never the phone's own zone (a rider visiting California still wants
/// departures in New Jersey time). Port of the `America/New_York` handling
/// scattered through v4's lib/.
public enum Eastern {
    public static let timeZone: TimeZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Hour of day (0-23) in Eastern time, wherever this runs.
    public static func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }

    /// Year, month (1-12) and day of `date` in Eastern time.
    public static func ymd(of date: Date) -> (year: Int, month: Int, day: Int) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The instant at the given Eastern wall-clock time.
    public static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0) -> Date? {
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = timeZone
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return calendar.date(from: parts)
    }

    /// Formatter pinned to Eastern time and a fixed English locale.
    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        formatter.dateFormat = format
        return formatter
    }
}

/// ISO 8601 timestamps in the exact shape JavaScript's `toISOString()` writes
/// (`2026-08-04T14:12:00.000Z`), so stored pins and cached payloads read the
/// same way v4's did.
public enum ISOTime {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let lock = NSLock()

    public static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }
}

/// JavaScript's `Math.round`: halves round toward positive infinity.
func jsRound(_ value: Double) -> Int {
    Int((value + 0.5).rounded(.down))
}

extension Date {
    /// Milliseconds since the epoch, like JavaScript's `getTime()`.
    var epochMs: Double { timeIntervalSince1970 * 1000 }

    func adding(minutes: Int) -> Date { addingTimeInterval(Double(minutes) * 60) }
}
