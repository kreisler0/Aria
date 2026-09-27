import Foundation

/// Date parsing/formatting that behaves identically on iOS, macOS and Linux.
///
/// Supabase returns timestamps like `2026-09-27T06:58:28.594913+00:00` (microseconds),
/// GoTrue uses nanoseconds, and language models send anything from
/// `2026-10-02T17:00:00-04:00` to `2026-10-02 17:00`. `ISO8601DateFormatter` rejects
/// several of those, so this is a small hand-written RFC 3339 parser instead.
public enum AriaDate {
    /// Parses an ISO 8601 / RFC 3339 timestamp. Accepts fractional seconds of any
    /// precision, `Z`, `±HH:MM`, `±HHMM` or `±HH` offsets, `T` or a space as separator,
    /// optional seconds, and bare dates. Values without an offset are interpreted in
    /// `defaultTimeZone` (bare dates become local midnight).
    public static func parseTimestamp(_ text: String, defaultTimeZone: TimeZone = .current) -> Date? {
        let bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            index += count
            return value
        }
        func consume(_ character: Character) -> Bool {
            guard index < bytes.count, bytes[index] == character.asciiValue! else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), consume("-"), let month = digits(2), consume("-"), let day = digits(2) else {
            return nil
        }
        var hour = 0, minute = 0, second = 0, nanosecond = 0
        var offsetSeconds: Int?

        if index < bytes.count {
            let separator = bytes[index]
            guard separator == Character("T").asciiValue! || separator == Character("t").asciiValue!
                || separator == Character(" ").asciiValue! else { return nil }
            index += 1
            guard let parsedHour = digits(2), consume(":"), let parsedMinute = digits(2) else { return nil }
            hour = parsedHour
            minute = parsedMinute
            if consume(":") {
                guard let parsedSecond = digits(2) else { return nil }
                second = parsedSecond
            }
            if index < bytes.count, bytes[index] == Character(".").asciiValue! || bytes[index] == Character(",").asciiValue! {
                index += 1
                var fraction = 0, count = 0
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                    if count < 9 {
                        fraction = fraction * 10 + Int(bytes[index] - 48)
                        count += 1
                    }
                    index += 1
                }
                guard count > 0 else { return nil }
                for _ in count..<9 { fraction *= 10 }
                nanosecond = fraction
            }
            if index < bytes.count {
                let marker = bytes[index]
                if marker == Character("Z").asciiValue! || marker == Character("z").asciiValue! {
                    offsetSeconds = 0
                    index += 1
                } else if marker == Character("+").asciiValue! || marker == Character("-").asciiValue! {
                    let sign = marker == Character("-").asciiValue! ? -1 : 1
                    index += 1
                    guard let offsetHours = digits(2) else { return nil }
                    var offsetMinutes = 0
                    if index < bytes.count {
                        _ = consume(":")
                        guard let parsedMinutes = digits(2) else { return nil }
                        offsetMinutes = parsedMinutes
                    }
                    guard offsetHours <= 23, offsetMinutes <= 59 else { return nil }
                    offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
                } else {
                    return nil
                }
            }
            guard index == bytes.count else { return nil }
        }

        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        // Reject impossible dates such as 2026-02-30.
        let roundTrip = civilFromDays(days)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        let clampedSecond = min(second, 59) // leap seconds collapse onto :59

        if let offsetSeconds {
            let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + clampedSecond) - Double(offsetSeconds)
            return Date(timeIntervalSince1970: seconds + Double(nanosecond) / 1_000_000_000)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = defaultTimeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                        second: clampedSecond, nanosecond: nanosecond)
        return calendar.date(from: components)
    }

    /// UTC with millisecond precision, e.g. `2026-09-27T06:58:28.594Z` — what we send to Supabase.
    public static func formatUTC(_ date: Date) -> String {
        let parts = utcParts(date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second, parts.millisecond)
    }

    /// Local wall-clock time with an explicit offset and second precision, e.g.
    /// `2026-10-02T17:00:00-04:00` — what we show the language model.
    public static func formatLocal(_ date: Date, timeZone: TimeZone) -> String {
        let offset = timeZone.secondsFromGMT(for: date)
        let parts = utcParts(date.addingTimeInterval(TimeInterval(offset)))
        let absolute = abs(offset)
        let wallClock = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                               parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second)
        let zone = String(format: "%02d:%02d", absolute / 3600, (absolute % 3600) / 60)
        return wallClock + (offset < 0 ? "-" : "+") + zone
    }

    /// Human-friendly form for prompts: `Friday, 2 October 2026 17:00`.
    public static func formatReadable(_ date: Date, timeZone: TimeZone, includeTime: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = includeTime ? "EEEE, d MMMM yyyy HH:mm" : "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: Civil calendar arithmetic (Howard Hinnant's algorithms, proleptic Gregorian)

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (month <= 2 ? yearOfEra + era * 400 + 1 : yearOfEra + era * 400, month, day)
    }

    private static func utcParts(_ date: Date)
        -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int) {
        var milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let dayMillis: Int64 = 86_400_000
        var days = milliseconds / dayMillis
        milliseconds -= days * dayMillis
        if milliseconds < 0 {
            milliseconds += dayMillis
            days -= 1
        }
        let civil = civilFromDays(Int(days))
        let totalSeconds = Int(milliseconds / 1000)
        return (civil.year, civil.month, civil.day, totalSeconds / 3600, (totalSeconds % 3600) / 60,
                totalSeconds % 60, Int(milliseconds % 1000))
    }
}

/// A calendar day (`yyyy-MM-dd`) independent of time zone — the `planner_days.date`
/// column, tool-call date ranges, and all-day events all use this.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        let days = AriaDate.daysFromCivil(year: year, month: month, day: day)
        let check = AriaDate.civilFromDays(days)
        guard (1...12).contains(month), check.year == year, check.month == month, check.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-MM-dd`. A full timestamp is also accepted; its date part is used as written.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let datePart = String(trimmed.prefix(10))
        let pieces = datePart.split(separator: "-")
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else { return nil }
        if trimmed.count > 10 {
            let separator = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 10)]
            guard separator == "T" || separator == "t" || separator == " " else { return nil }
        }
        self.init(year: year, month: month, day: day)
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = components.year!
        self.month = components.month!
        self.day = components.day!
    }

    /// The day `date` falls on in UTC (all-day events are stored as UTC midnights).
    public init(utc date: Date) {
        let days = Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
        let civil = AriaDate.civilFromDays(days)
        self.year = civil.year
        self.month = civil.month
        self.day = civil.day
    }

    private init(daysSinceEpoch: Int) {
        let civil = AriaDate.civilFromDays(daysSinceEpoch)
        self.year = civil.year
        self.month = civil.month
        self.day = civil.day
    }

    public var daysSinceEpoch: Int { AriaDate.daysFromCivil(year: year, month: month, day: day) }

    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { string }

    public func adding(days: Int) -> DayKey { DayKey(daysSinceEpoch: daysSinceEpoch + days) }

    /// Midnight at the start of this day in `calendar`'s time zone.
    public func startDate(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// `[start of this day, start of next day)` in `calendar`'s time zone.
    public func interval(in calendar: Calendar) -> DateInterval {
        DateInterval(start: startDate(in: calendar), end: adding(days: 1).startDate(in: calendar))
    }

    /// Midnight UTC at the start of this day.
    public var utcMidnight: Date { Date(timeIntervalSince1970: TimeInterval(daysSinceEpoch) * 86_400) }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool { lhs.daysSinceEpoch < rhs.daysSinceEpoch }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let key = DayKey(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
