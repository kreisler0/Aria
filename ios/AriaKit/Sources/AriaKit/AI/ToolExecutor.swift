import Foundation

/// The data operations the AI tools are allowed to perform. `SupabaseClient` is the real
/// implementation; tests use an in-memory fake.
public protocol PlannerDataSource: Sendable {
    func createTask(_ task: NewTask) async throws -> TaskItem
    func setTaskCompleted(id: UUID, completed: Bool) async throws -> TaskItem?
    func deleteTask(id: UUID) async throws -> TaskItem?
    func fetchTasks(_ query: TaskQuery) async throws -> [TaskItem]
    func createEvent(_ event: NewEvent) async throws -> EventItem
    func fetchEvent(id: UUID) async throws -> EventItem?
    func updateEvent(id: UUID, _ update: EventUpdate) async throws -> EventItem?
    func deleteEvent(id: UUID) async throws -> EventItem?
    func fetchEvents(overlapping interval: DateInterval, calendar: Calendar) async throws -> [EventItem]
}

extension SupabaseClient: PlannerDataSource {}

/// A data change made by a tool call, so the UI, widgets, Live Activity and calendar
/// sync can react without refetching everything.
public enum PlannerMutation: Hashable, Sendable {
    case taskCreated(TaskItem)
    case taskUpdated(TaskItem)
    case taskDeleted(TaskItem)
    case eventCreated(EventItem)
    case eventUpdated(EventItem)
    case eventDeleted(EventItem)
}

/// The result of one tool call: `output` goes back to the model, `summary` is shown in
/// the chat as an action chip.
public struct ToolOutcome: Hashable, Sendable {
    public var callId: String
    public var name: String
    public var succeeded: Bool
    public var output: JSONValue
    public var summary: String
    public var mutation: PlannerMutation?

    public init(callId: String, name: String, succeeded: Bool, output: JSONValue, summary: String,
                mutation: PlannerMutation? = nil) {
        self.callId = callId
        self.name = name
        self.succeeded = succeeded
        self.output = output
        self.summary = summary
        self.mutation = mutation
    }
}

struct ToolArgumentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Validated access to a tool call's JSON arguments.
struct ToolArguments {
    let values: [String: JSONValue]

    init(json: String) throws {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            values = [:]
            return
        }
        guard let parsed = try? JSONValue.parse(trimmed) else {
            throw ToolArgumentError("The arguments are not valid JSON.")
        }
        if parsed.isNull {
            values = [:]
        } else if let object = parsed.objectValue {
            values = object
        } else {
            throw ToolArgumentError("The arguments must be a JSON object.")
        }
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let text = value.stringValue else { throw ToolArgumentError("'\(key)' must be a string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func requiredString(_ key: String) throws -> String {
        guard let text = try string(key) else { throw ToolArgumentError("'\(key)' is required.") }
        return text
    }

    func date(_ key: String, timeZone: TimeZone) throws -> Date? {
        guard let text = try string(key) else { return nil }
        guard let date = AriaDate.parseTimestamp(text, defaultTimeZone: timeZone) else {
            throw ToolArgumentError("'\(key)' must be an ISO 8601 date-time such as 2026-10-02T17:00:00-04:00 (got \"\(text)\").")
        }
        return date
    }

    func requiredDate(_ key: String, timeZone: TimeZone) throws -> Date {
        guard let date = try date(key, timeZone: timeZone) else { throw ToolArgumentError("'\(key)' is required.") }
        return date
    }

    func day(_ key: String) throws -> DayKey? {
        guard let text = try string(key) else { return nil }
        guard let day = DayKey(text) else {
            throw ToolArgumentError("'\(key)' must be a date in the form YYYY-MM-DD (got \"\(text)\").")
        }
        return day
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        if let number = value.doubleValue, number.rounded() == number, abs(number) < 1_000_000 {
            return Int(number)
        }
        if let text = value.stringValue, let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            return number
        }
        throw ToolArgumentError("'\(key)' must be an integer.")
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key], !value.isNull else { return nil }
        if let flag = value.boolValue { return flag }
        switch value.stringValue?.lowercased() {
        case "true": return true
        case "false": return false
        default: throw ToolArgumentError("'\(key)' must be true or false.")
        }
    }

    func id(_ key: String, kind: String) throws -> UUID {
        let text = try requiredString(key)
        guard let id = UUID(uuidString: text) else {
            throw ToolArgumentError("'\(text)' is not a valid \(kind) id. Use an id from the lists or a list tool.")
        }
        return id
    }
}

/// Validates and executes tool calls against the data source. Every argument is checked
/// before anything is written; failures are reported back to the model as JSON so it can
/// correct itself.
public struct ToolExecutor: Sendable {
    public let data: PlannerDataSource
    public let calendar: Calendar
    public let formatter: ItemFormatter
    private let now: @Sendable () -> Date

    public init(data: PlannerDataSource, calendar: Calendar, locale: Locale = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.data = data
        self.calendar = calendar
        self.formatter = ItemFormatter(calendar: calendar, locale: locale)
        self.now = now
    }

    private var timeZone: TimeZone { calendar.timeZone }

    public func execute(_ call: ToolCall) async -> ToolOutcome {
        let name = call.function.name
        do {
            let arguments = try ToolArguments(json: call.function.arguments)
            switch name {
            case AriaTools.createTask: return try await createTask(call, arguments)
            case AriaTools.completeTask: return try await completeTask(call, arguments)
            case AriaTools.deleteTask: return try await deleteTask(call, arguments)
            case AriaTools.createEvent: return try await createEvent(call, arguments)
            case AriaTools.deleteEvent: return try await deleteEvent(call, arguments)
            case AriaTools.rescheduleEvent: return try await rescheduleEvent(call, arguments)
            case AriaTools.listTasksForRange: return try await listTasks(call, arguments)
            case AriaTools.listEventsForRange: return try await listEvents(call, arguments)
            default:
                return failure(call, "Unknown tool '\(name)'. Available tools: \(AriaTools.allNames.joined(separator: ", ")).")
            }
        } catch let error as ToolArgumentError {
            return failure(call, error.message)
        } catch {
            return failure(call, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    // MARK: Tools

    private func createTask(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        let title = try arguments.requiredString("title")
        guard title.count <= 500 else { throw ToolArgumentError("'title' must be at most 500 characters.") }
        let dueAt = try arguments.date("due_at", timeZone: timeZone)
        var priority = TaskPriority.none
        if let value = try arguments.int("priority") {
            guard let parsed = TaskPriority(rawValue: value) else { throw ToolArgumentError("'priority' must be 0, 1, 2 or 3.") }
            priority = parsed
        }
        let notes = try arguments.string("notes")
        let task = try await data.createTask(NewTask(title: title, notes: notes, dueAt: dueAt, priority: priority, source: .ai))
        var summary = "Added “\(task.title)”"
        if let due = task.dueAt { summary += " · due \(formatter.dayAndTime(due))" }
        return success(call, ["task": taskJSON(task)], summary: summary, mutation: .taskCreated(task))
    }

    private func completeTask(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        let id = try arguments.id("task_id", kind: "task")
        guard let task = try await data.setTaskCompleted(id: id, completed: true) else {
            return failure(call, "No task with id \(id.lowercasedString) exists.")
        }
        return success(call, ["task": taskJSON(task)], summary: "Completed “\(task.title)”", mutation: .taskUpdated(task))
    }

    private func deleteTask(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        let id = try arguments.id("task_id", kind: "task")
        guard let task = try await data.deleteTask(id: id) else {
            return failure(call, "No task with id \(id.lowercasedString) exists.")
        }
        return success(call, ["deleted_task": taskJSON(task)], summary: "Deleted “\(task.title)”", mutation: .taskDeleted(task))
    }

    private func createEvent(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        let title = try arguments.requiredString("title")
        guard title.count <= 500 else { throw ToolArgumentError("'title' must be at most 500 characters.") }
        var start = try arguments.requiredDate("start_at", timeZone: timeZone)
        var end = try arguments.requiredDate("end_at", timeZone: timeZone)
        let allDay = try arguments.bool("all_day") ?? false
        if allDay {
            (start, end) = AllDayRange.stored(start: start, end: end, calendar: calendar)
        } else {
            guard end >= start else { throw ToolArgumentError("'end_at' must not be before 'start_at'.") }
        }
        let event = try await data.createEvent(NewEvent(title: title, startAt: start, endAt: end, allDay: allDay, source: .ai))
        return success(call, ["event": eventJSON(event)],
                       summary: "Scheduled “\(event.title)” · \(formatter.eventTiming(event))", mutation: .eventCreated(event))
    }

    private func deleteEvent(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        let id = try arguments.id("event_id", kind: "event")
        guard let event = try await data.deleteEvent(id: id) else {
            return failure(call, "No event with id \(id.lowercasedString) exists.")
        }
        return success(call, ["deleted_event": eventJSON(event)], summary: "Deleted “\(event.title)”",
                       mutation: .eventDeleted(event))
    }

    private func rescheduleEvent(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        let id = try arguments.id("event_id", kind: "event")
        var start = try arguments.requiredDate("new_start_at", timeZone: timeZone)
        var end = try arguments.requiredDate("new_end_at", timeZone: timeZone)
        guard let existing = try await data.fetchEvent(id: id) else {
            return failure(call, "No event with id \(id.lowercasedString) exists.")
        }
        if existing.allDay {
            (start, end) = AllDayRange.stored(start: start, end: end, calendar: calendar)
        } else {
            guard end >= start else { throw ToolArgumentError("'new_end_at' must not be before 'new_start_at'.") }
        }
        guard let event = try await data.updateEvent(id: id, EventUpdate(startAt: start, endAt: end)) else {
            return failure(call, "No event with id \(id.lowercasedString) exists.")
        }
        return success(call, ["event": eventJSON(event)],
                       summary: "Moved “\(event.title)” to \(formatter.eventTiming(event))", mutation: .eventUpdated(event))
    }

    private func listTasks(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        let start = try arguments.day("start")
        let end = try arguments.day("end")
        if start == nil && end == nil {
            var query = TaskQuery.allOpen
            query.limit = 200
            let tasks = try await data.fetchTasks(query)
            return success(call, ["range": "all open tasks", "count": .number(Double(tasks.count)),
                                  "tasks": .array(tasks.map(taskJSON))],
                           summary: "Checked your open tasks")
        }
        let range = try dayRange(start: start, end: end)
        let interval = DateInterval(start: range.first.startDate(in: calendar),
                                    end: range.last.adding(days: 1).startDate(in: calendar))
        let tasks = try await data.fetchTasks(TaskQuery(dueRange: interval, limit: 200))
        return success(call, ["start": .string(range.first.string), "end": .string(range.last.string),
                              "count": .number(Double(tasks.count)), "tasks": .array(tasks.map(taskJSON))],
                       summary: "Checked tasks for \(formatter.dayRange(range.first, range.last))")
    }

    private func listEvents(_ call: ToolCall, _ arguments: ToolArguments) async throws -> ToolOutcome {
        var start = try arguments.day("start")
        var end = try arguments.day("end")
        if start == nil && end == nil {
            let today = DayKey(now(), calendar: calendar)
            start = today
            end = today.adding(days: 6)
        }
        let range = try dayRange(start: start, end: end)
        let interval = DateInterval(start: range.first.startDate(in: calendar),
                                    end: range.last.adding(days: 1).startDate(in: calendar))
        let events = try await data.fetchEvents(overlapping: interval, calendar: calendar)
        return success(call, ["start": .string(range.first.string), "end": .string(range.last.string),
                              "count": .number(Double(events.count)), "events": .array(events.map(eventJSON))],
                       summary: "Checked your calendar for \(formatter.dayRange(range.first, range.last))")
    }

    // MARK: Helpers

    private func dayRange(start: DayKey?, end: DayKey?) throws -> (first: DayKey, last: DayKey) {
        let first = start ?? end!
        let last = end ?? start!
        guard first <= last else { throw ToolArgumentError("'start' must not be after 'end'.") }
        guard last.daysSinceEpoch - first.daysSinceEpoch <= 366 else {
            throw ToolArgumentError("The range can be at most one year long.")
        }
        return (first, last)
    }

    func taskJSON(_ task: TaskItem) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(task.id.lowercasedString),
            "title": .string(task.title),
            "completed": .bool(task.completed),
            "priority": .number(Double(task.priority.rawValue)),
            "due_at": task.dueAt.map { .string(AriaDate.formatLocal($0, timeZone: timeZone)) } ?? .null,
        ]
        if let notes = task.notes, !notes.isEmpty { object["notes"] = .string(notes) }
        return .object(object)
    }

    func eventJSON(_ event: EventItem) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(event.id.lowercasedString),
            "title": .string(event.title),
            "all_day": .bool(event.allDay),
        ]
        if event.allDay {
            object["start_date"] = .string(event.firstDay.string)
            object["end_date"] = .string(event.lastDay.string)
        } else {
            object["start_at"] = .string(AriaDate.formatLocal(event.startAt, timeZone: timeZone))
            object["end_at"] = .string(AriaDate.formatLocal(event.endAt, timeZone: timeZone))
        }
        if let notes = event.notes, !notes.isEmpty { object["notes"] = .string(notes) }
        return .object(object)
    }

    private func success(_ call: ToolCall, _ fields: [String: JSONValue], summary: String,
                         mutation: PlannerMutation? = nil) -> ToolOutcome {
        var output = fields
        output["ok"] = true
        return ToolOutcome(callId: call.id, name: call.function.name, succeeded: true, output: .object(output),
                           summary: summary, mutation: mutation)
    }

    private func failure(_ call: ToolCall, _ message: String) -> ToolOutcome {
        ToolOutcome(callId: call.id, name: call.function.name, succeeded: false,
                    output: ["ok": false, "error": .string(message)],
                    summary: "Couldn't \(Self.verb(for: call.function.name)): \(message)")
    }

    static func verb(for tool: String) -> String {
        switch tool {
        case AriaTools.createTask: return "add the task"
        case AriaTools.completeTask: return "complete the task"
        case AriaTools.deleteTask: return "delete the task"
        case AriaTools.createEvent: return "create the event"
        case AriaTools.deleteEvent: return "delete the event"
        case AriaTools.rescheduleEvent: return "move the event"
        case AriaTools.listTasksForRange: return "look up tasks"
        case AriaTools.listEventsForRange: return "look up events"
        default: return "run \(tool)"
        }
    }
}

/// Short, localized descriptions of dates for chat summaries and widgets.
public struct ItemFormatter: Sendable {
    public let calendar: Calendar
    public let locale: Locale

    public init(calendar: Calendar, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    private func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// e.g. "Fri 2 Oct, 17:00" (or the locale's equivalent). Composed from the two parts
    /// so the output doesn't depend on the ICU version's date-time glue ("at", ",", …).
    public func dayAndTime(_ date: Date) -> String { "\(day(date)), \(time(date))" }

    /// e.g. "Fri 2 Oct".
    public func day(_ date: Date) -> String { format(date, template: "EEEdMMM") }

    /// e.g. "17:00" / "5:00 PM".
    public func time(_ date: Date) -> String { format(date, template: "jmm") }

    public func dayRange(_ first: DayKey, _ last: DayKey) -> String {
        let start = day(first.startDate(in: calendar))
        return first == last ? start : "\(start) – \(day(last.startDate(in: calendar)))"
    }

    /// "Fri 2 Oct, 09:00–10:00", "Fri 2 Oct (all day)", "Fri 2 Oct – Sun 4 Oct (all day)".
    public func eventTiming(_ event: EventItem) -> String {
        if event.allDay {
            return dayRange(event.firstDay, event.lastDay) + " (all day)"
        }
        if calendar.isDate(event.startAt, inSameDayAs: event.endAt) {
            return "\(dayAndTime(event.startAt))–\(time(event.endAt))"
        }
        return "\(dayAndTime(event.startAt)) – \(dayAndTime(event.endAt))"
    }
}
