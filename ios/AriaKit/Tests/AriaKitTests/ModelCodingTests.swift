import XCTest
@testable import AriaKit

final class ModelCodingTests: XCTestCase {
    let decoder = AriaJSON.makeDecoder()
    let encoder = AriaJSON.makeEncoder()

    func testDecodesPostgRESTTaskRow() throws {
        let body = """
        [{"id":"413962ee-971e-4141-9350-7a336eb31408","user_id":"11895ec2-4698-456d-b3fe-233836785d0b",
          "title":"Finish essay","notes":null,"due_at":"2026-10-02T21:00:00+00:00","completed":false,
          "completed_at":null,"priority":3,"source":"ai","created_at":"2026-09-27T06:58:28.594913+00:00",
          "updated_at":"2026-09-27T06:58:28.594913+00:00"}]
        """
        let tasks = try decoder.decode([TaskItem].self, from: Data(body.utf8))
        XCTAssertEqual(tasks.count, 1)
        let task = tasks[0]
        XCTAssertEqual(task.id, UUID(uuidString: "413962EE-971E-4141-9350-7A336EB31408"))
        XCTAssertEqual(task.title, "Finish essay")
        XCTAssertEqual(task.dueAt, date("2026-10-02T21:00:00Z"))
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.source, .ai)
        XCTAssertFalse(task.completed)
        XCTAssertNil(task.notes)
    }

    func testDecodesEventRowAndPlannerDay() throws {
        let events = try decoder.decode([EventItem].self, from: Data("""
        [{"id":"20000000-0000-4000-a000-000000000001","user_id":"00000000-0000-4000-a000-00000000000a","title":"Dentist",
          "notes":"Bring card","start_at":"2026-10-01T09:00:00-04:00","end_at":"2026-10-01T10:00:00-04:00","all_day":false,
          "ios_calendar_event_id":"EK-1","source":"user","created_at":"2026-09-27T06:58:28+00:00","updated_at":"2026-09-27T06:58:28+00:00"}]
        """.utf8))
        XCTAssertEqual(events[0].startAt, date("2026-10-01T13:00:00Z"))
        XCTAssertEqual(events[0].iosCalendarEventId, "EK-1")
        let days = try decoder.decode([PlannerDay].self, from: Data("""
        [{"id":"20000000-0000-4000-a000-000000000002","user_id":"00000000-0000-4000-a000-00000000000a","date":"2026-10-01",
          "notes":"Pack lunch","updated_at":"2026-09-27T06:58:28.1+00:00"}]
        """.utf8))
        XCTAssertEqual(days[0].date, DayKey("2026-10-01"))
    }

    func testDecodesConversationWithJSONB() throws {
        let rows = try decoder.decode([ConversationEntry].self, from: Data("""
        [{"id":"20000000-0000-4000-a000-000000000003","user_id":null,"role":"assistant","content":null,
          "tool_calls":[{"id":"call_1","type":"function","function":{"name":"create_task","arguments":"{}"}}],
          "created_at":"2026-09-27T06:58:28.000001+00:00"}]
        """.utf8))
        XCTAssertEqual(rows[0].role, .assistant)
        XCTAssertEqual(rows[0].toolCalls?.arrayValue?.first?["function"]?["name"], "create_task")
    }

    func testEncodesNewTaskWithoutNullsAndLowercaseId() throws {
        let task = NewTask(id: uuid(7), title: "Call mum", dueAt: date("2026-10-02T21:00:00Z"), priority: .medium, source: .ai)
        let text = String(decoding: try encoder.encode(task), as: UTF8.self)
        XCTAssertEqual(text, #"{"completed":false,"due_at":"2026-10-02T21:00:00.000Z","id":"00000000-0000-4000-8000-000000000007","priority":2,"source":"ai","title":"Call mum"}"#)
    }

    func testTaskUpdateDistinguishesUntouchedFromCleared() throws {
        XCTAssertEqual(String(decoding: try encoder.encode(TaskUpdate(completed: true)), as: UTF8.self), #"{"completed":true}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(TaskUpdate(notes: .some(nil), dueAt: .some(nil))), as: UTF8.self),
                       #"{"due_at":null,"notes":null}"#)
        XCTAssertTrue(TaskUpdate().isEmpty)
        let base = TaskItem(id: uuid(1), title: "A", notes: "n", dueAt: date("2026-10-02T21:00:00Z"))
        let changed = TaskUpdate(title: "B", notes: .some(nil), completed: true).applied(to: base, now: date("2026-09-27T12:00:00Z"))
        XCTAssertEqual(changed.title, "B")
        XCTAssertNil(changed.notes)
        XCTAssertEqual(changed.dueAt, base.dueAt)
        XCTAssertTrue(changed.completed)
        XCTAssertEqual(changed.completedAt, date("2026-09-27T12:00:00Z"))
        XCTAssertNil(TaskUpdate(completed: false).applied(to: changed).completedAt)
    }

    func testNewEventOmitsIdForUpserts() throws {
        var event = NewEvent(id: nil, title: "Standup", startAt: date("2026-10-01T13:00:00Z"), endAt: date("2026-10-01T13:15:00Z"),
                             iosCalendarEventId: "EK-2")
        var text = String(decoding: try encoder.encode(event), as: UTF8.self)
        XCTAssertFalse(text.contains("\"id\""))
        XCTAssertTrue(text.contains(#""ios_calendar_event_id":"EK-2""#))
        event.id = uuid(3)
        text = String(decoding: try encoder.encode(event), as: UTF8.self)
        XCTAssertTrue(text.contains(#""id":"00000000-0000-4000-8000-000000000003""#))
        XCTAssertEqual(String(decoding: try encoder.encode(EventUpdate(iosCalendarEventId: .some("X"))), as: UTF8.self),
                       #"{"ios_calendar_event_id":"X"}"#)
    }

    func testConversationEntriesAlwaysHaveTheSameKeys() throws {
        let entries = [
            NewConversationEntry(role: .user, content: "hi", createdAt: date("2026-09-27T12:00:00Z")),
            NewConversationEntry(role: .tool, content: "{}", toolCalls: ["tool_call_id": "c1"], createdAt: date("2026-09-27T12:00:00.001Z")),
        ]
        let array = try JSONDecoder().decode([JSONValue].self, from: try encoder.encode(entries))
        XCTAssertEqual(array.map { $0.objectValue.map { Set($0.keys) } }, Array(repeating: Set(["role", "content", "tool_calls", "created_at"]), count: 2))
        XCTAssertEqual(array[0]["tool_calls"], .null)
    }

    func testAllDayEventsAreTimeZoneIndependent() {
        let newYorkCalendar = calendar(newYork)
        let tokyoCalendar = calendar(TimeZone(identifier: "Asia/Tokyo")!)
        // The AI asks for an all-day event on 2 October, written in New York time.
        let stored = AllDayRange.stored(start: date("2026-10-02T04:00:00Z"), end: date("2026-10-03T04:00:00Z"), calendar: newYorkCalendar)
        XCTAssertEqual(stored.start, date("2026-10-02T00:00:00Z"))
        XCTAssertEqual(stored.end, date("2026-10-03T00:00:00Z"))
        let event = EventItem(title: "Holiday", startAt: stored.start, endAt: stored.end, allDay: true)
        XCTAssertEqual(event.firstDay, DayKey("2026-10-02"))
        XCTAssertEqual(event.lastDay, DayKey("2026-10-02"))
        for cal in [newYorkCalendar, tokyoCalendar] {
            XCTAssertTrue(event.overlaps(DayKey("2026-10-02")!.interval(in: cal), calendar: cal))
            XCTAssertFalse(event.overlaps(DayKey("2026-10-01")!.interval(in: cal), calendar: cal))
            XCTAssertFalse(event.overlaps(DayKey("2026-10-03")!.interval(in: cal), calendar: cal))
            XCTAssertEqual(event.displayStart(in: cal), DayKey("2026-10-02")!.startDate(in: cal))
        }
        // Start == end still means one day.
        let single = AllDayRange.stored(start: date("2026-10-02T04:00:00Z"), end: date("2026-10-02T04:00:00Z"), calendar: newYorkCalendar)
        XCTAssertEqual(single.end.timeIntervalSince(single.start), 86_400)
        // Multi-day, with an end inside the last day.
        let multi = AllDayRange.stored(start: date("2026-10-02T13:00:00Z"), end: date("2026-10-04T15:00:00Z"), calendar: newYorkCalendar)
        XCTAssertEqual(EventItem(title: "Trip", startAt: multi.start, endAt: multi.end, allDay: true).lastDay, DayKey("2026-10-04"))
    }

    func testTimedEventOverlap() {
        let cal = calendar(newYork)
        let day = DayKey("2026-10-01")!.interval(in: cal)
        let lateNight = EventItem(title: "Late", startAt: date("2026-10-02T03:00:00Z"), endAt: date("2026-10-02T04:00:00Z"))
        XCTAssertTrue(lateNight.overlaps(day, calendar: cal)) // 23:00–24:00 local on 1 Oct
        let endsAtMidnight = EventItem(title: "Ends", startAt: date("2026-10-01T03:00:00Z"), endAt: date("2026-10-01T04:00:00Z"))
        XCTAssertFalse(endsAtMidnight.overlaps(day, calendar: cal)) // 30 Sep 23:00 → 1 Oct 00:00
        let instant = EventItem(title: "Ping", startAt: day.start, endAt: day.start)
        XCTAssertTrue(instant.overlaps(day, calendar: cal))
    }

    func testJSONValueRoundTripAndNumbers() throws {
        let value: JSONValue = ["a": 1, "b": true, "c": [1.5, "x", nil], "d": ["e": "f"]]
        let text = value.jsonString()
        XCTAssertEqual(text, #"{"a":1,"b":true,"c":[1.5,"x",null],"d":{"e":"f"}}"#)
        XCTAssertEqual(try JSONValue.parse(text), value)
        XCTAssertEqual(try JSONValue.parse("1"), .number(1))
        XCTAssertEqual(try JSONValue.parse("true"), .bool(true))
        XCTAssertEqual(try JSONValue.parse("0"), .number(0))
        XCTAssertEqual(JSONValue.number(3).jsonString(), "3")
    }

    func testTaskQueryBuildsPostgRESTFilters() {
        let range = DateInterval(start: date("2026-09-27T04:00:00Z"), end: date("2026-09-28T04:00:00Z"))
        func params(_ query: TaskQuery) -> [String: String] {
            Dictionary(query.queryItems(), uniquingKeysWith: { $1 })
        }
        XCTAssertEqual(params(.allOpen)["and"], "(completed.eq.false)")
        XCTAssertEqual(params(TaskQuery(dueRange: range))["and"],
                       "(and(due_at.gte.2026-09-27T04:00:00.000Z,due_at.lt.2026-09-28T04:00:00.000Z))")
        XCTAssertEqual(params(TaskQuery(dueRange: range, includeUndated: true, completedSince: date("2026-09-20T00:00:00Z")))["and"],
                       "(or(completed.eq.false,completed_at.gte.2026-09-20T00:00:00.000Z),or(due_at.is.null,and(due_at.gte.2026-09-27T04:00:00.000Z,due_at.lt.2026-09-28T04:00:00.000Z)))")
        XCTAssertNil(params(TaskQuery())["and"])
        XCTAssertEqual(params(TaskQuery(limit: 5))["limit"], "5")
        XCTAssertEqual(params(TaskQuery())["order"], "due_at.asc.nullslast,priority.desc,created_at.asc")
    }

    func testQueryEncodingKeepsFiltersIntact() {
        XCTAssertEqual(QueryEncoding.queryString([("due_at", "gte.2026-09-27T04:00:00+05:00"), ("title", "eq.a b&c")]),
                       "due_at=gte.2026-09-27T04:00:00%2B05:00&title=eq.a%20b%26c")
        XCTAssertEqual(SupabaseClient.quoted(#"a"b\c"#), #""a\"b\\c""#)
    }

    func testSupabaseConfigValidation() {
        XCTAssertEqual(SupabaseConfig(urlString: " https://abc.supabase.co/ ", anonKey: " key ")?.url.absoluteString, "https://abc.supabase.co")
        XCTAssertEqual(SupabaseConfig(urlString: "https://abc.supabase.co", anonKey: "key")?.restURL.absoluteString,
                       "https://abc.supabase.co/rest/v1")
        XCTAssertNotNil(SupabaseConfig(urlString: "http://127.0.0.1:54321", anonKey: "key"))
        XCTAssertNil(SupabaseConfig(urlString: "http://abc.supabase.co", anonKey: "key"), "plain http only for local hosts")
        XCTAssertNil(SupabaseConfig(urlString: "https://abc.supabase.co", anonKey: "  "))
        XCTAssertNil(SupabaseConfig(urlString: "not a url", anonKey: "key"))
        XCTAssertTrue(SupabaseConfig(urlString: "https://a.co", anonKey: fakeJWT)!.anonKeyIsJWT)
        XCTAssertFalse(SupabaseConfig(urlString: "https://a.co", anonKey: "sb_publishable_123")!.anonKeyIsJWT)
    }
}
