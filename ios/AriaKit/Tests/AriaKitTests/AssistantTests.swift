import XCTest
@testable import AriaKit

final class ToolExecutorTests: XCTestCase {
    let cal = calendar(newYork)
    let now = date("2026-09-27T13:41:00Z") // Sunday 09:41 in New York

    func executor(_ data: FakePlannerData) -> ToolExecutor {
        let fixedNow = now
        return ToolExecutor(data: data, calendar: cal, locale: Locale(identifier: "en_US_POSIX"), now: { fixedNow })
    }

    func testSchemaMatchesTheSpec() {
        let names = AriaTools.definitions.compactMap { $0["function"]?["name"]?.stringValue }
        XCTAssertEqual(names, ["create_task", "complete_task", "delete_task", "create_event", "delete_event", "reschedule_event",
                               "list_tasks_for_range", "list_events_for_range"])
        let createTask = AriaTools.definitions[0]["function"]?["parameters"]
        XCTAssertEqual(createTask?["required"], ["title"])
        XCTAssertEqual(createTask?["properties"]?["priority"]?["enum"], [0, 1, 2, 3])
        XCTAssertEqual(AriaTools.definitions[5]["function"]?["parameters"]?["required"], ["event_id", "new_start_at", "new_end_at"])
        for definition in AriaTools.definitions {
            XCTAssertEqual(definition["type"], "function")
            XCTAssertEqual(definition["function"]?["parameters"]?["type"], "object")
        }
    }

    func testCreateTaskValidatesAndMarksSourceAI() async {
        let data = FakePlannerData()
        let outcome = await executor(data).execute(toolCall("c1", "create_task",
            #"{"title":" Finish essay ","due_at":"2026-10-02T17:00:00-04:00","priority":"3","notes":"5 pages"}"#))
        XCTAssertTrue(outcome.succeeded, outcome.summary)
        XCTAssertEqual(outcome.output["ok"], true)
        XCTAssertEqual(outcome.output["task"]?["title"], "Finish essay")
        XCTAssertEqual(outcome.output["task"]?["due_at"], "2026-10-02T17:00:00-04:00")
        XCTAssertEqual(outcome.output["task"]?["priority"], 3)
        XCTAssertEqual(outcome.summary.plainSpaces, "Added “Finish essay” · due Fri, Oct 2, 5:00 PM")
        let tasks = await data.tasks
        XCTAssertEqual(tasks.first?.source, .ai)
        XCTAssertEqual(tasks.first?.dueAt, date("2026-10-02T21:00:00Z"))
        if case .taskCreated(let task)? = outcome.mutation { XCTAssertEqual(task.title, "Finish essay") } else { XCTFail("mutation") }
    }

    func testInvalidArgumentsAreReportedWithoutWriting() async {
        let data = FakePlannerData()
        let cases: [(String, String, String)] = [
            ("create_task", #"{}"#, "'title' is required."),
            ("create_task", #"{"title":"   "}"#, "'title' is required."),
            ("create_task", #"{"title":"x","priority":7}"#, "'priority' must be 0, 1, 2 or 3."),
            ("create_task", #"{"title":"x","due_at":"next friday"}"#, "'due_at' must be an ISO 8601 date-time"),
            ("create_task", #"{"title":42}"#, "'title' must be a string."),
            ("create_task", "not json", "The arguments are not valid JSON."),
            ("create_task", "[1]", "The arguments must be a JSON object."),
            ("complete_task", #"{"task_id":"abc"}"#, "'abc' is not a valid task id"),
            ("create_event", #"{"title":"x","start_at":"2026-10-02T10:00:00Z","end_at":"2026-10-02T09:00:00Z"}"#,
             "'end_at' must not be before 'start_at'."),
            ("create_event", #"{"title":"x","start_at":"2026-10-02T10:00:00Z","end_at":"2026-10-02T11:00:00Z","all_day":"maybe"}"#,
             "'all_day' must be true or false."),
            ("list_tasks_for_range", #"{"start":"2026-10-05","end":"2026-10-01"}"#, "'start' must not be after 'end'."),
            ("list_events_for_range", #"{"start":"2026-01-01","end":"2028-01-01"}"#, "The range can be at most one year long."),
            ("drop_table", #"{}"#, "Unknown tool 'drop_table'"),
        ]
        for (name, arguments, message) in cases {
            let outcome = await executor(data).execute(toolCall("c", name, arguments))
            XCTAssertFalse(outcome.succeeded, "\(name) \(arguments)")
            XCTAssertEqual(outcome.output["ok"], false)
            XCTAssertTrue(outcome.output["error"]?.stringValue?.hasPrefix(message) ?? false,
                          "\(name) \(arguments): \(outcome.output["error"]?.stringValue ?? "nil")")
            XCTAssertNil(outcome.mutation)
        }
        let calls = await data.calls
        XCTAssertEqual(calls, [], "nothing may be written when validation fails")
    }

    func testCompleteAndDeleteTask() async {
        let task = TaskItem(id: uuid(1), title: "Call mum")
        let data = FakePlannerData(tasks: [task])
        let completed = await executor(data).execute(toolCall("c1", "complete_task", #"{"task_id":"00000000-0000-4000-8000-000000000001"}"#))
        XCTAssertTrue(completed.succeeded)
        XCTAssertEqual(completed.summary, "Completed “Call mum”")
        XCTAssertEqual(completed.output["task"]?["completed"], true)
        let deleted = await executor(data).execute(toolCall("c2", "delete_task", #"{"task_id":"00000000-0000-4000-8000-000000000001"}"#))
        XCTAssertTrue(deleted.succeeded)
        XCTAssertEqual(deleted.summary, "Deleted “Call mum”")
        let missing = await executor(data).execute(toolCall("c3", "delete_task", #"{"task_id":"00000000-0000-4000-8000-000000000001"}"#))
        XCTAssertFalse(missing.succeeded)
        XCTAssertEqual(missing.output["error"], "No task with id 00000000-0000-4000-8000-000000000001 exists.")
    }

    func testCreateEventNormalizesAllDay() async {
        let data = FakePlannerData()
        let timed = await executor(data).execute(toolCall("c1", "create_event",
            #"{"title":"Dentist","start_at":"2026-10-01T09:00:00-04:00","end_at":"2026-10-01T10:00:00-04:00"}"#))
        XCTAssertTrue(timed.succeeded)
        XCTAssertEqual(timed.summary.plainSpaces, "Scheduled “Dentist” · Thu, Oct 1, 9:00 AM–10:00 AM")
        XCTAssertEqual(timed.output["event"]?["start_at"], "2026-10-01T09:00:00-04:00")
        let allDay = await executor(data).execute(toolCall("c2", "create_event",
            #"{"title":"Holiday","start_at":"2026-10-02","end_at":"2026-10-02","all_day":true}"#))
        XCTAssertTrue(allDay.succeeded)
        XCTAssertEqual(allDay.output["event"]?["start_date"], "2026-10-02")
        XCTAssertEqual(allDay.output["event"]?["end_date"], "2026-10-02")
        XCTAssertEqual(allDay.summary.plainSpaces, "Scheduled “Holiday” · Fri, Oct 2 (all day)")
        let events = await data.events
        XCTAssertEqual(events.last?.startAt, date("2026-10-02T00:00:00Z"))
        XCTAssertEqual(events.last?.endAt, date("2026-10-03T00:00:00Z"))
        XCTAssertEqual(events.map(\.source), [.ai, .ai])
    }

    func testRescheduleEvent() async {
        let event = EventItem(id: uuid(2), title: "Standup", startAt: date("2026-09-28T13:00:00Z"), endAt: date("2026-09-28T13:15:00Z"))
        let data = FakePlannerData(events: [event])
        let outcome = await executor(data).execute(toolCall("c1", "reschedule_event",
            #"{"event_id":"00000000-0000-4000-8000-000000000002","new_start_at":"2026-09-28T10:00:00-04:00","new_end_at":"2026-09-28T10:15:00-04:00"}"#))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.summary.plainSpaces, "Moved “Standup” to Mon, Sep 28, 10:00 AM–10:15 AM")
        let stored = await data.events.first
        XCTAssertEqual(stored?.startAt, date("2026-09-28T14:00:00Z"))
        let missing = await executor(data).execute(toolCall("c2", "reschedule_event",
            #"{"event_id":"00000000-0000-4000-8000-000000000009","new_start_at":"2026-09-28T10:00:00Z","new_end_at":"2026-09-28T11:00:00Z"}"#))
        XCTAssertEqual(missing.output["error"], "No event with id 00000000-0000-4000-8000-000000000009 exists.")
    }

    func testListRanges() async {
        let data = FakePlannerData(
            tasks: [
                TaskItem(id: uuid(1), title: "Due Friday", dueAt: date("2026-10-02T21:00:00Z")),
                TaskItem(id: uuid(2), title: "Undated"),
                TaskItem(id: uuid(3), title: "Done", completed: true),
            ],
            events: [
                EventItem(id: uuid(4), title: "Today", startAt: date("2026-09-27T14:00:00Z"), endAt: date("2026-09-27T15:00:00Z")),
                EventItem(id: uuid(5), title: "Next month", startAt: date("2026-10-28T14:00:00Z"), endAt: date("2026-10-28T15:00:00Z")),
            ])
        let open = await executor(data).execute(toolCall("c1", "list_tasks_for_range", "{}"))
        XCTAssertEqual(open.output["tasks"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Due Friday", "Undated"])
        let friday = await executor(data).execute(toolCall("c2", "list_tasks_for_range", #"{"start":"2026-10-02"}"#))
        XCTAssertEqual(friday.output["count"], 1)
        XCTAssertEqual(friday.output["start"], "2026-10-02")
        XCTAssertEqual(friday.output["end"], "2026-10-02")
        let week = await executor(data).execute(toolCall("c3", "list_events_for_range", ""))
        XCTAssertEqual(week.output["events"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Today"])
        XCTAssertEqual(week.output["end"], "2026-10-03")
        XCTAssertNil(week.mutation)
        XCTAssertEqual(week.summary.plainSpaces, "Checked your calendar for Sun, Sep 27 – Sat, Oct 3")
    }

    func testDataSourceErrorsBecomeToolErrors() async {
        struct Failing: PlannerDataSource {
            func createTask(_ task: NewTask) async throws -> TaskItem {
                throw AriaError.server(status: 500, code: nil, message: "database unavailable")
            }
            func setTaskCompleted(id: UUID, completed: Bool) async throws -> TaskItem? { nil }
            func deleteTask(id: UUID) async throws -> TaskItem? { nil }
            func fetchTasks(_ query: TaskQuery) async throws -> [TaskItem] { [] }
            func createEvent(_ event: NewEvent) async throws -> EventItem { throw AriaError.notAuthenticated }
            func fetchEvent(id: UUID) async throws -> EventItem? { nil }
            func updateEvent(id: UUID, _ update: EventUpdate) async throws -> EventItem? { nil }
            func deleteEvent(id: UUID) async throws -> EventItem? { nil }
            func fetchEvents(overlapping interval: DateInterval, calendar: Calendar) async throws -> [EventItem] { [] }
        }
        let outcome = await ToolExecutor(data: Failing(), calendar: cal).execute(toolCall("c", "create_task", #"{"title":"x"}"#))
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.output["error"], "database unavailable")
        XCTAssertEqual(outcome.summary, "Couldn't add the task: database unavailable")
    }
}

final class AssistantEngineTests: XCTestCase {
    let cal = calendar(newYork)
    let now = date("2026-09-27T13:41:00Z")

    func engine(_ model: ScriptedModel, _ data: FakePlannerData, maxRounds: Int = 6) -> AssistantEngine {
        let fixedNow = now
        return AssistantEngine(client: model,
                               executor: ToolExecutor(data: data, calendar: cal, locale: Locale(identifier: "en_US_POSIX"),
                                                      now: { fixedNow }),
                               maxToolRounds: maxRounds)
    }

    func testToolLoopExecutesCallsAndSendsResultsBack() async throws {
        let data = FakePlannerData()
        let model = ScriptedModel([
            ChatCompletion(message: .assistant(nil, toolCalls: [
                toolCall("call_1", "create_task", #"{"title":"Finish essay","due_at":"2026-10-02T17:00:00-04:00"}"#),
                toolCall("call_2", "create_event", #"{"title":"Study","start_at":"2026-10-01T18:00:00-04:00","end_at":"2026-10-01T19:00:00-04:00"}"#),
            ]), finishReason: "tool_calls"),
            ChatCompletion(message: .assistant("Added 'Finish essay' due Friday 5pm and blocked Thursday 6pm to study."), finishReason: "stop"),
        ])
        let snapshot = PlannerSnapshot(tasks: [TaskItem(id: uuid(8), title: "Laundry", priority: .low)], events: [])
        let reply = try await engine(model, data).respond(to: "Add finish essay due Friday 5pm and a study block Thursday at 6",
                                                          model: "anthropic/claude-sonnet-4.5",
                                                          history: [.user("hi"), .assistant("Hello!")], snapshot: snapshot, now: now)
        XCTAssertEqual(reply.text, "Added 'Finish essay' due Friday 5pm and blocked Thursday 6pm to study.")
        XCTAssertEqual(reply.outcomes.map(\.succeeded), [true, true])
        XCTAssertEqual(reply.mutations.count, 2)
        XCTAssertEqual(model.requests.count, 2)

        let first = model.requests[0]
        XCTAssertEqual(first.model, "anthropic/claude-sonnet-4.5")
        XCTAssertEqual(first.toolChoice, "auto")
        XCTAssertEqual(first.tools?.count, 8)
        XCTAssertEqual(first.messages.map(\.role), [.system, .user, .assistant, .user])
        let system = first.messages[0].content ?? ""
        XCTAssertTrue(system.contains("Current date and time: Sunday, 27 September 2026 09:41 (2026-09-27T09:41:00-04:00)"), system)
        XCTAssertTrue(system.contains("Time zone: America/New_York"))
        XCTAssertTrue(system.contains("- id=00000000-0000-4000-8000-000000000008 | Laundry | priority low"))

        let second = model.requests[1].messages
        XCTAssertEqual(second.map(\.role), [.system, .user, .assistant, .user, .assistant, .tool, .tool])
        XCTAssertEqual(second[4].toolCalls?.map(\.id), ["call_1", "call_2"])
        XCTAssertEqual(second[5].toolCallId, "call_1")
        XCTAssertEqual(try JSONValue.parse(second[5].content ?? "")["ok"], true)
        XCTAssertEqual(second[6].toolCallId, "call_2")

        XCTAssertEqual(reply.transcript.map(\.role), [.user, .assistant, .tool, .tool, .assistant])
        let tasks = await data.tasks
        XCTAssertEqual(tasks.map(\.title), ["Finish essay"])
    }

    func testFailedToolCallIsReportedToTheModel() async throws {
        let data = FakePlannerData()
        let model = ScriptedModel([
            ChatCompletion(message: .assistant(nil, toolCalls: [toolCall("c1", "complete_task", #"{"task_id":"nope"}"#)])),
            ChatCompletion(message: .assistant("I couldn't find that task — which one did you mean?")),
        ])
        let reply = try await engine(model, data).respond(to: "complete it", model: "m", history: [],
                                                          snapshot: PlannerSnapshot(tasks: [], events: []), now: now)
        XCTAssertEqual(reply.outcomes.first?.succeeded, false)
        let toolMessage = model.requests[1].messages.last
        XCTAssertEqual(toolMessage?.role, .tool)
        XCTAssertEqual(try JSONValue.parse(toolMessage?.content ?? "")["ok"], false)
    }

    func testRunawayToolLoopIsCappedAndWrappedUp() async throws {
        let data = FakePlannerData()
        let looping = (0..<3).map { index in
            ChatCompletion(message: .assistant(nil, toolCalls: [toolCall("c\(index)", "list_tasks_for_range", "{}")]))
        }
        let model = ScriptedModel(looping + [ChatCompletion(message: .assistant("Here's what I found."))])
        let reply = try await engine(model, data, maxRounds: 3).respond(to: "loop", model: "m", history: [],
                                                                        snapshot: PlannerSnapshot(tasks: [], events: []), now: now)
        XCTAssertEqual(model.requests.count, 4)
        XCTAssertEqual(model.requests.last?.toolChoice, "none")
        XCTAssertEqual(reply.text, "Here's what I found.")
    }

    func testEmptyFinalAnswerFallsBackToSummaries() async throws {
        let data = FakePlannerData()
        let model = ScriptedModel([
            ChatCompletion(message: .assistant(nil, toolCalls: [toolCall("c1", "create_task", #"{"title":"Milk"}"#)])),
            ChatCompletion(message: .assistant("   ")),
        ])
        let reply = try await engine(model, data).respond(to: "milk", model: "m", history: [],
                                                          snapshot: PlannerSnapshot(tasks: [], events: []), now: now)
        XCTAssertEqual(reply.text, "Added “Milk”.")
    }

    func testEmptyMessageIsRejected() async {
        let model = ScriptedModel([])
        do {
            _ = try await engine(model, FakePlannerData()).respond(to: "  ", model: "m", history: [],
                                                                    snapshot: PlannerSnapshot(tasks: [], events: []))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AriaError, .invalidInput("Type a message first."))
        }
        XCTAssertEqual(model.requests.count, 0)
    }

    func testTranscriptLogging() async throws {
        let data = FakePlannerData()
        let model = ScriptedModel([
            ChatCompletion(message: .assistant("On it.", toolCalls: [toolCall("c1", "create_task", #"{"title":"Milk"}"#)])),
            ChatCompletion(message: .assistant("Added milk.")),
        ])
        let reply = try await engine(model, data).respond(to: "add milk", model: "m", history: [],
                                                          snapshot: PlannerSnapshot(tasks: [], events: []), now: now)
        let entries = ConversationHistory.logEntries(for: reply, startingAt: now)
        XCTAssertEqual(entries.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(entries.map(\.createdAt), (0..<4).map { now.addingTimeInterval(Double($0) / 1000) })
        XCTAssertEqual(entries[1].toolCalls?.arrayValue?.first?["function"]?["name"], "create_task")
        XCTAssertEqual(entries[2].toolCalls?["tool_call_id"], "c1")
        XCTAssertEqual(entries[2].toolCalls?["summary"], "Added “Milk”")
        XCTAssertEqual(entries[3].content, "Added milk.")
    }

    func testHistoryContextKeepsOnlyConversationText() {
        let entries: [ConversationEntry] = [
            ConversationEntry(role: .assistant, content: "orphan answer"),
            ConversationEntry(role: .user, content: "add milk"),
            ConversationEntry(role: .assistant, content: nil, toolCalls: [["id": "c1"]]),
            ConversationEntry(role: .tool, content: #"{"ok":true}"#, toolCalls: ["tool_call_id": "c1"]),
            ConversationEntry(role: .assistant, content: "Added milk."),
            ConversationEntry(role: .user, content: "  "),
        ]
        let context = ConversationHistory.contextMessages(from: entries)
        XCTAssertEqual(context, [.user("add milk"), .assistant("Added milk.")])
        XCTAssertEqual(ConversationHistory.contextMessages(from: entries, limit: 1), [], "a window can't start on an answer")
    }

    func testSnapshotForPromptPicksTodaysSlice() {
        let tasks = [
            TaskItem(id: uuid(1), title: "Overdue", dueAt: date("2026-09-25T12:00:00Z")),
            TaskItem(id: uuid(2), title: "Tomorrow", dueAt: date("2026-09-28T16:00:00Z")),
            TaskItem(id: uuid(3), title: "Undated"),
            TaskItem(id: uuid(4), title: "Done today", dueAt: date("2026-09-27T16:00:00Z"), completed: true),
            TaskItem(id: uuid(5), title: "Tonight", dueAt: date("2026-09-28T01:00:00Z")),
        ]
        let events = [
            EventItem(id: uuid(6), title: "Brunch", startAt: date("2026-09-27T15:00:00Z"), endAt: date("2026-09-27T16:00:00Z")),
            EventItem(id: uuid(7), title: "Monday", startAt: date("2026-09-28T15:00:00Z"), endAt: date("2026-09-28T16:00:00Z")),
        ]
        let snapshot = PlannerSnapshot.forPrompt(tasks: tasks, events: events, now: now, calendar: cal)
        XCTAssertEqual(snapshot.tasks.map(\.title), ["Overdue", "Tonight", "Undated"])
        XCTAssertEqual(snapshot.events.map(\.title), ["Brunch"])
    }
}
