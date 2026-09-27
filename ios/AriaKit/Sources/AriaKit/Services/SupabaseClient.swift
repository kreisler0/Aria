import Foundation

/// Which tasks to fetch.
public struct TaskQuery: Hashable, Sendable {
    /// Only tasks due in `[start, end)`.
    public var dueRange: DateInterval?
    /// With `dueRange`: also include tasks that have no due date.
    public var includeUndated: Bool
    /// Only tasks that are not completed.
    public var openOnly: Bool
    /// When not `openOnly`: completed tasks are included only if completed at/after this date.
    public var completedSince: Date?
    public var limit: Int?

    public init(dueRange: DateInterval? = nil, includeUndated: Bool = false, openOnly: Bool = false,
                completedSince: Date? = nil, limit: Int? = nil) {
        self.dueRange = dueRange
        self.includeUndated = includeUndated
        self.openOnly = openOnly
        self.completedSince = completedSince
        self.limit = limit
    }

    /// Every task that is still open.
    public static let allOpen = TaskQuery(openOnly: true)

    /// What the app keeps loaded: every open task plus anything completed in the last week.
    public static func workingSet(now: Date = Date()) -> TaskQuery {
        TaskQuery(completedSince: now.addingTimeInterval(-7 * 86_400))
    }

    /// PostgREST query parameters (filters are ANDed together).
    func queryItems() -> [(String, String)] {
        var conditions: [String] = []
        if openOnly {
            conditions.append("completed.eq.false")
        } else if let completedSince {
            conditions.append("or(completed.eq.false,completed_at.gte.\(AriaDate.formatUTC(completedSince)))")
        }
        if let dueRange {
            let inRange = "and(due_at.gte.\(AriaDate.formatUTC(dueRange.start)),due_at.lt.\(AriaDate.formatUTC(dueRange.end)))"
            conditions.append(includeUndated ? "or(due_at.is.null,\(inRange))" : inRange)
        }
        var items: [(String, String)] = [("select", "*")]
        if !conditions.isEmpty {
            items.append(("and", "(" + conditions.joined(separator: ",") + ")"))
        }
        items.append(("order", "due_at.asc.nullslast,priority.desc,created_at.asc"))
        if let limit { items.append(("limit", String(limit))) }
        return items
    }
}

/// Supabase REST (PostgREST) client for Aria's tables. Every request carries the
/// signed-in user's JWT, so Row-Level Security scopes it to that user's rows.
public final class SupabaseClient: @unchecked Sendable {
    public let config: SupabaseConfig
    public let auth: SupabaseAuth
    private let transport: HTTPTransport

    public init(config: SupabaseConfig, sessionStore: SessionStore, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
        self.auth = SupabaseAuth(config: config, transport: transport, store: sessionStore)
    }

    // MARK: Tasks

    public func fetchTasks(_ query: TaskQuery) async throws -> [TaskItem] {
        try await get("tasks", query: query.queryItems())
    }

    public func fetchTask(id: UUID) async throws -> TaskItem? {
        let rows: [TaskItem] = try await get("tasks", query: [("select", "*"), ("id", "eq.\(id.lowercasedString)")])
        return rows.first
    }

    public func createTask(_ task: NewTask) async throws -> TaskItem {
        try await insertOne("tasks", body: task)
    }

    /// Returns `nil` when no such task exists (or it belongs to someone else).
    public func updateTask(id: UUID, _ update: TaskUpdate) async throws -> TaskItem? {
        try await updateOne("tasks", id: id, body: update)
    }

    public func setTaskCompleted(id: UUID, completed: Bool) async throws -> TaskItem? {
        try await updateTask(id: id, TaskUpdate(completed: completed))
    }

    /// Returns the deleted row, or `nil` when there was nothing to delete.
    @discardableResult
    public func deleteTask(id: UUID) async throws -> TaskItem? {
        try await deleteOne("tasks", id: id)
    }

    // MARK: Events

    /// Rows whose `[start_at, end_at]` touches the given instants, unfiltered — what the
    /// calendar sync works on.
    public func fetchEventRows(from start: Date, to end: Date) async throws -> [EventItem] {
        try await get("events", query: [
            ("select", "*"),
            ("start_at", "lt.\(AriaDate.formatUTC(end))"),
            ("or", "(end_at.gt.\(AriaDate.formatUTC(start)),start_at.gte.\(AriaDate.formatUTC(start)))"),
            ("order", "start_at.asc"),
        ])
    }

    /// Events visible in a span of local time (e.g. a day or a month) on this device.
    /// All-day events are stored as UTC days, so the query is padded and then filtered.
    public func fetchEvents(overlapping interval: DateInterval, calendar: Calendar) async throws -> [EventItem] {
        let rows = try await fetchEventRows(from: interval.start.addingTimeInterval(-86_400),
                                            to: interval.end.addingTimeInterval(86_400))
        return rows.filter { $0.overlaps(interval, calendar: calendar) }
    }

    /// Rows linked to any of the given device calendar identifiers.
    public func fetchEventRows(calendarIds: [String]) async throws -> [EventItem] {
        guard !calendarIds.isEmpty else { return [] }
        var rows: [EventItem] = []
        for chunk in stride(from: 0, to: calendarIds.count, by: 50).map({ Array(calendarIds[$0..<min($0 + 50, calendarIds.count)]) }) {
            let list = chunk.map(Self.quoted).joined(separator: ",")
            rows += try await get("events", query: [("select", "*"), ("ios_calendar_event_id", "in.(\(list))")])
        }
        return rows
    }

    /// Rows with the given ids (missing ids are simply absent from the result).
    public func fetchEvents(ids: [UUID]) async throws -> [EventItem] {
        guard !ids.isEmpty else { return [] }
        var rows: [EventItem] = []
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let list = chunk.map(\.lowercasedString).joined(separator: ",")
            rows += try await get("events", query: [("select", "*"), ("id", "in.(\(list))")])
        }
        return rows
    }

    /// PostgREST list values are double-quoted so commas, parentheses etc. are literal.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public func fetchEvent(id: UUID) async throws -> EventItem? {
        let rows: [EventItem] = try await get("events", query: [("select", "*"), ("id", "eq.\(id.lowercasedString)")])
        return rows.first
    }

    public func createEvent(_ event: NewEvent) async throws -> EventItem {
        try await insertOne("events", body: event)
    }

    /// Inserts or updates the row linked to `event.iosCalendarEventId` (two devices
    /// importing the same calendar event end up with one row).
    public func upsertEventByCalendarId(_ event: NewEvent) async throws -> EventItem {
        guard event.iosCalendarEventId != nil else {
            throw AriaError.invalidInput("An iOS calendar identifier is required for an upsert.")
        }
        var payload = event
        payload.id = nil
        if payload.userId == nil { payload.userId = await auth.currentUser?.id }
        let body = try AriaJSON.makeEncoder().encode(payload)
        let response = try await send("POST", "events", query: [("on_conflict", "user_id,ios_calendar_event_id")],
                                      body: body, prefer: "resolution=merge-duplicates,return=representation")
        let rows: [EventItem] = try decode(response)
        guard let row = rows.first else { throw AriaError.decoding("upsert returned no row") }
        return row
    }

    public func updateEvent(id: UUID, _ update: EventUpdate) async throws -> EventItem? {
        try await updateOne("events", id: id, body: update)
    }

    /// Returns the deleted row, or `nil` when there was nothing to delete.
    @discardableResult
    public func deleteEvent(id: UUID) async throws -> EventItem? {
        try await deleteOne("events", id: id)
    }

    // MARK: Planner days

    public func fetchPlannerDay(_ day: DayKey) async throws -> PlannerDay? {
        let rows: [PlannerDay] = try await get("planner_days", query: [("select", "*"), ("date", "eq.\(day.string)")])
        return rows.first
    }

    public func savePlannerDay(_ day: DayKey, notes: String?) async throws -> PlannerDay {
        guard let userId = await auth.currentUser?.id else { throw AriaError.notAuthenticated }
        let payload: JSONValue = [
            "user_id": .string(userId.lowercasedString),
            "date": .string(day.string),
            "notes": notes.map { JSONValue.string($0) } ?? .null,
        ]
        let response = try await send("POST", "planner_days", query: [("on_conflict", "user_id,date")],
                                      body: try JSONEncoder().encode(payload),
                                      prefer: "resolution=merge-duplicates,return=representation")
        let rows: [PlannerDay] = try decode(response)
        guard let row = rows.first else { throw AriaError.decoding("upsert returned no row") }
        return row
    }

    // MARK: Profile

    public func fetchProfile() async throws -> UserProfile? {
        guard let userId = await auth.currentUser?.id else { throw AriaError.notAuthenticated }
        let rows: [UserProfile] = try await get("users", query: [("select", "*"), ("id", "eq.\(userId.lowercasedString)")])
        return rows.first
    }

    public func updateModel(_ model: String) async throws {
        guard let userId = await auth.currentUser?.id else { throw AriaError.notAuthenticated }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AriaError.invalidInput("Model name can't be empty.") }
        let body = try JSONEncoder().encode(["openrouter_model": trimmed])
        _ = try await send("PATCH", "users", query: [("id", "eq.\(userId.lowercasedString)")], body: body,
                           prefer: "return=minimal")
    }

    // MARK: AI conversation log

    /// The most recent `limit` messages, oldest first.
    public func fetchConversation(limit: Int = 40) async throws -> [ConversationEntry] {
        let rows: [ConversationEntry] = try await get("ai_conversations", query: [
            ("select", "*"), ("order", "created_at.desc"), ("limit", String(limit)),
        ])
        return rows.reversed()
    }

    public func appendConversation(_ entries: [NewConversationEntry]) async throws {
        guard !entries.isEmpty else { return }
        let body = try AriaJSON.makeEncoder().encode(entries)
        _ = try await send("POST", "ai_conversations", body: body, prefer: "return=minimal")
    }

    public func clearConversation() async throws {
        guard let userId = await auth.currentUser?.id else { throw AriaError.notAuthenticated }
        _ = try await send("DELETE", "ai_conversations", query: [("user_id", "eq.\(userId.lowercasedString)")],
                           prefer: "return=minimal")
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ table: String, query: [(String, String)]) async throws -> T {
        try decode(try await send("GET", table, query: query))
    }

    private func insertOne<Body: Encodable, Row: Decodable>(_ table: String, body: Body) async throws -> Row {
        let data = try AriaJSON.makeEncoder().encode(body)
        let rows: [Row] = try decode(try await send("POST", table, body: data, prefer: "return=representation"))
        guard let row = rows.first else { throw AriaError.decoding("insert returned no row") }
        return row
    }

    private func updateOne<Body: Encodable, Row: Decodable>(_ table: String, id: UUID, body: Body) async throws -> Row? {
        let data = try AriaJSON.makeEncoder().encode(body)
        let rows: [Row] = try decode(try await send("PATCH", table, query: [("id", "eq.\(id.lowercasedString)")],
                                                    body: data, prefer: "return=representation"))
        return rows.first
    }

    private func deleteOne<Row: Decodable>(_ table: String, id: UUID) async throws -> Row? {
        let rows: [Row] = try decode(try await send("DELETE", table, query: [("id", "eq.\(id.lowercasedString)")],
                                                    prefer: "return=representation"))
        return rows.first
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws -> T {
        do {
            return try AriaJSON.makeDecoder().decode(T.self, from: response.body)
        } catch {
            throw AriaError.decoding("\(T.self): \(error)")
        }
    }

    private func send(_ method: String, _ table: String, query: [(String, String)] = [], body: Data? = nil,
                      prefer: String? = nil, isRetry: Bool = false) async throws -> HTTPResponse {
        let token = try await auth.accessToken()
        var urlString = config.restURL.appendingPathComponent(table).absoluteString
        if !query.isEmpty { urlString += "?" + QueryEncoding.queryString(query) }
        guard let url = URL(string: urlString) else { throw AriaError.invalidInput("Bad request URL") }
        var headers = [
            "apikey": config.anonKey,
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
        ]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let prefer { headers["Prefer"] = prefer }
        let response = try await transport.send(HTTPRequest(method: method, url: url, headers: headers, body: body))
        if response.status == 401 && !isRetry {
            // Expired or revoked JWT: refresh once and retry.
            try await auth.refreshSession()
            return try await send(method, table, query: query, body: body, prefer: prefer, isRetry: true)
        }
        guard response.isSuccess else {
            let parsed = AriaError.message(from: response.body, fallbackStatus: response.status)
            if response.status == 401 { throw AriaError.notAuthenticated }
            throw AriaError.server(status: response.status, code: parsed.code, message: parsed.message)
        }
        return response
    }
}
