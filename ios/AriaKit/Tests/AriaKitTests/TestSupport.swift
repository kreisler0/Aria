import Foundation
@testable import AriaKit

/// Scriptable HTTP transport that records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        return try await handler(request)
    }

    private func record(_ request: HTTPRequest) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
    }
}

func json(_ status: Int, _ body: String, headers: [String: String] = ["Content-Type": "application/json"]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
}

func bodyJSON(_ request: HTTPRequest) -> JSONValue? {
    guard let body = request.body else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: body)
}

func queryItems(_ request: HTTPRequest) -> [String: [String]] {
    var result: [String: [String]] = [:]
    let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
    for item in components?.queryItems ?? [] {
        result[item.name, default: []].append(item.value ?? "")
    }
    return result
}

let utc = TimeZone(identifier: "UTC")!
let newYork = TimeZone(identifier: "America/New_York")!

func calendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

/// `2026-09-27T09:41:00-04:00` style literal → Date (test helper; crashes on typos).
func date(_ text: String) -> Date {
    guard let value = AriaDate.parseTimestamp(text, defaultTimeZone: utc) else { fatalError("bad test date \(text)") }
    return value
}

func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
}

/// A fake JWT whose payload is irrelevant to these tests.
let fakeJWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"

func tokenBody(access: String, refresh: String, expiresAt: Date, userId: UUID = uuid(1), email: String = "alice@aria.test") -> String {
    """
    {"access_token":"\(access)","token_type":"bearer","expires_in":3600,"expires_at":\(Int(expiresAt.timeIntervalSince1970)),
     "refresh_token":"\(refresh)","user":{"id":"\(userId.lowercasedString)","email":"\(email)","user_metadata":{"full_name":"Alice"}}}
    """
}

/// Thread-safe mutable box for use inside `@Sendable` closures.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&_value)
    }
}

/// In-memory `PlannerDataSource` for tool/engine tests.
actor FakePlannerData: PlannerDataSource {
    var tasks: [TaskItem]
    var events: [EventItem]
    private(set) var calls: [String] = []

    init(tasks: [TaskItem] = [], events: [EventItem] = []) {
        self.tasks = tasks
        self.events = events
    }

    func createTask(_ task: NewTask) async throws -> TaskItem {
        calls.append("createTask")
        let item = task.makeItem(userId: uuid(1), now: date("2026-09-27T13:41:00Z"))
        tasks.append(item)
        return item
    }

    func setTaskCompleted(id: UUID, completed: Bool) async throws -> TaskItem? {
        calls.append("setTaskCompleted")
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        tasks[index] = TaskUpdate(completed: completed).applied(to: tasks[index], now: date("2026-09-27T13:41:00Z"))
        return tasks[index]
    }

    func deleteTask(id: UUID) async throws -> TaskItem? {
        calls.append("deleteTask")
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        return tasks.remove(at: index)
    }

    func fetchTasks(_ query: TaskQuery) async throws -> [TaskItem] {
        calls.append("fetchTasks")
        return tasks.filter { task in
            if query.openOnly && task.completed { return false }
            if let range = query.dueRange {
                guard let due = task.dueAt else { return query.includeUndated }
                return range.start <= due && due < range.end
            }
            return true
        }.sorted(by: Planner.taskOrder)
    }

    func createEvent(_ event: NewEvent) async throws -> EventItem {
        calls.append("createEvent")
        let item = event.makeItem(now: date("2026-09-27T13:41:00Z"))
        events.append(item)
        return item
    }

    func fetchEvent(id: UUID) async throws -> EventItem? {
        calls.append("fetchEvent")
        return events.first { $0.id == id }
    }

    func updateEvent(id: UUID, _ update: EventUpdate) async throws -> EventItem? {
        calls.append("updateEvent")
        guard let index = events.firstIndex(where: { $0.id == id }) else { return nil }
        events[index] = update.applied(to: events[index], now: date("2026-09-27T13:41:00Z"))
        return events[index]
    }

    func deleteEvent(id: UUID) async throws -> EventItem? {
        calls.append("deleteEvent")
        guard let index = events.firstIndex(where: { $0.id == id }) else { return nil }
        return events.remove(at: index)
    }

    func fetchEvents(overlapping interval: DateInterval, calendar: Calendar) async throws -> [EventItem] {
        calls.append("fetchEvents")
        return events.filter { $0.overlaps(interval, calendar: calendar) }.sorted { $0.startAt < $1.startAt }
    }
}

/// Scripted chat model: returns the queued completions in order and records requests.
final class ScriptedModel: ChatCompleting, @unchecked Sendable {
    struct Request {
        var model: String
        var messages: [ChatMessage]
        var tools: [JSONValue]?
        var toolChoice: String?
    }

    private let lock = NSLock()
    private var queue: [ChatCompletion]
    private(set) var requests: [Request] = []

    init(_ completions: [ChatCompletion]) {
        self.queue = completions
    }

    func complete(model: String, messages: [ChatMessage], tools: [JSONValue]?, toolChoice: String?) async throws -> ChatCompletion {
        next(Request(model: model, messages: messages, tools: tools, toolChoice: toolChoice))
    }

    private func next(_ request: Request) -> ChatCompletion {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !queue.isEmpty else { return ChatCompletion(message: .assistant("(script exhausted)")) }
        return queue.removeFirst()
    }
}

func toolCall(_ id: String, _ name: String, _ arguments: String) -> ToolCall {
    ToolCall(id: id, name: name, arguments: arguments)
}

extension String {
    /// ICU (and iOS 17+) put narrow/no-break spaces in formatted times ("5:00\u{202F}PM").
    var plainSpaces: String {
        replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
