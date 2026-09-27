import Foundation

/// A row of `public.events`.
///
/// All-day events are stored time-zone independently: `start_at` is midnight UTC of the
/// first day and `end_at` is midnight UTC after the last day, so an all-day event on
/// 2 October shows on 2 October on every device, whatever its time zone.
public struct EventItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: UUID?
    public var title: String
    public var notes: String?
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool
    public var iosCalendarEventId: String?
    public var source: ItemSource
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: UUID = UUID(), userId: UUID? = nil, title: String, notes: String? = nil, startAt: Date,
                endAt: Date, allDay: Bool = false, iosCalendarEventId: String? = nil, source: ItemSource = .user,
                createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.userId = userId
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.iosCalendarEventId = iosCalendarEventId
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case notes
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
        case iosCalendarEventId = "ios_calendar_event_id"
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// First day of an all-day event.
    public var firstDay: DayKey { DayKey(utc: startAt) }

    /// Last (inclusive) day of an all-day event.
    public var lastDay: DayKey {
        let last = DayKey(utc: endAt.addingTimeInterval(-1))
        return max(last, firstDay)
    }

    /// Start as shown on this device: local midnight for all-day events.
    public func displayStart(in calendar: Calendar) -> Date {
        allDay ? firstDay.startDate(in: calendar) : startAt
    }

    /// End as shown on this device: local midnight after the last day for all-day events.
    public func displayEnd(in calendar: Calendar) -> Date {
        allDay ? lastDay.adding(days: 1).startDate(in: calendar) : endAt
    }

    /// Whether the event touches `interval` (a span of local time, e.g. one day).
    public func overlaps(_ interval: DateInterval, calendar: Calendar) -> Bool {
        if allDay {
            let firstVisibleDay = DayKey(interval.start, calendar: calendar)
            let lastVisibleDay = DayKey(interval.end.addingTimeInterval(-0.001), calendar: calendar)
            return firstDay <= lastVisibleDay && lastDay >= firstVisibleDay
        }
        if endAt <= startAt {
            return interval.start <= startAt && startAt < interval.end
        }
        return startAt < interval.end && endAt > interval.start
    }

    /// Whether the event is happening at `date`.
    public func isInProgress(at date: Date, calendar: Calendar) -> Bool {
        displayStart(in: calendar) <= date && date < displayEnd(in: calendar)
    }
}

/// Converts arbitrary start/end instants into the stored all-day representation.
public enum AllDayRange {
    /// `start`/`end` interpreted in `calendar`'s time zone; `end` is exclusive, and an
    /// end at or before the start yields a single-day event.
    public static func stored(start: Date, end: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let first = DayKey(start, calendar: calendar)
        let last = max(DayKey(end.addingTimeInterval(-1), calendar: calendar), first)
        return stored(first: first, last: last)
    }

    /// Inclusive day range to stored UTC midnights.
    public static func stored(first: DayKey, last: DayKey) -> (start: Date, end: Date) {
        let inclusiveLast = max(first, last)
        return (first.utcMidnight, inclusiveLast.adding(days: 1).utcMidnight)
    }
}

/// Insert payload for `events`.
public struct NewEvent: Encodable, Hashable, Sendable {
    /// Leave `nil` for upserts keyed on the calendar identifier, so a conflicting row keeps its id.
    public var id: UUID?
    public var userId: UUID?
    public var title: String
    public var notes: String?
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool
    public var iosCalendarEventId: String?
    public var source: ItemSource

    public init(id: UUID? = UUID(), userId: UUID? = nil, title: String, notes: String? = nil, startAt: Date,
                endAt: Date, allDay: Bool = false, iosCalendarEventId: String? = nil, source: ItemSource = .user) {
        self.id = id
        self.userId = userId
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.iosCalendarEventId = iosCalendarEventId
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case notes
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
        case iosCalendarEventId = "ios_calendar_event_id"
        case source
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id?.lowercasedString, forKey: .id)
        try container.encodeIfPresent(userId?.lowercasedString, forKey: .userId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(startAt, forKey: .startAt)
        try container.encode(endAt, forKey: .endAt)
        try container.encode(allDay, forKey: .allDay)
        try container.encodeIfPresent(iosCalendarEventId, forKey: .iosCalendarEventId)
        try container.encode(source, forKey: .source)
    }

    /// The row this insert will produce (used for optimistic UI updates).
    public func makeItem(now: Date = Date()) -> EventItem {
        EventItem(id: id ?? UUID(), userId: userId, title: title, notes: notes, startAt: startAt, endAt: endAt,
                  allDay: allDay, iosCalendarEventId: iosCalendarEventId, source: source, createdAt: now,
                  updatedAt: now)
    }
}

/// PATCH payload for `events`; see `TaskUpdate` for the `nil` / `.some(nil)` convention.
public struct EventUpdate: Encodable, Hashable, Sendable {
    public var title: String?
    public var notes: String??
    public var startAt: Date?
    public var endAt: Date?
    public var allDay: Bool?
    public var iosCalendarEventId: String??

    public init(title: String? = nil, notes: String?? = nil, startAt: Date? = nil, endAt: Date? = nil,
                allDay: Bool? = nil, iosCalendarEventId: String?? = nil) {
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.iosCalendarEventId = iosCalendarEventId
    }

    enum CodingKeys: String, CodingKey {
        case title, notes
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
        case iosCalendarEventId = "ios_calendar_event_id"
    }

    public var isEmpty: Bool {
        title == nil && notes == nil && startAt == nil && endAt == nil && allDay == nil && iosCalendarEventId == nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        if let notes { try container.encode(notes, forKey: .notes) }
        try container.encodeIfPresent(startAt, forKey: .startAt)
        try container.encodeIfPresent(endAt, forKey: .endAt)
        try container.encodeIfPresent(allDay, forKey: .allDay)
        if let iosCalendarEventId { try container.encode(iosCalendarEventId, forKey: .iosCalendarEventId) }
    }

    public func applied(to event: EventItem, now: Date = Date()) -> EventItem {
        var copy = event
        if let title { copy.title = title }
        if let notes { copy.notes = notes }
        if let startAt { copy.startAt = startAt }
        if let endAt { copy.endAt = endAt }
        if let allDay { copy.allDay = allDay }
        if let iosCalendarEventId { copy.iosCalendarEventId = iosCalendarEventId }
        copy.updatedAt = now
        return copy
    }
}
