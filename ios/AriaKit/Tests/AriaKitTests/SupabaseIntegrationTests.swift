import XCTest
@testable import AriaKit

/// End-to-end tests against a real Supabase stack (`supabase start`, or any project with
/// the migration applied). Skipped unless ARIA_TEST_SUPABASE_URL and
/// ARIA_TEST_SUPABASE_ANON_KEY are set.
final class SupabaseIntegrationTests: XCTestCase {
    var config: SupabaseConfig!
    let newYorkCalendar = calendar(newYork)

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["ARIA_TEST_SUPABASE_URL"], let key = environment["ARIA_TEST_SUPABASE_ANON_KEY"],
              let config = SupabaseConfig(urlString: url, anonKey: key) else {
            throw XCTSkip("Set ARIA_TEST_SUPABASE_URL and ARIA_TEST_SUPABASE_ANON_KEY to run integration tests")
        }
        self.config = config
    }

    func makeUser(_ name: String) async throws -> SupabaseClient {
        let client = SupabaseClient(config: config, sessionStore: InMemorySessionStore())
        let email = "\(name)-\(UUID().uuidString.prefix(8).lowercased())@aria.test"
        _ = try await client.auth.signUp(email: email, password: "correct-horse-battery", displayName: name.capitalized)
        return client
    }

    func testProfileTasksAndIsolation() async throws {
        let alice = try await makeUser("alice")
        let bob = try await makeUser("bob")

        let profile = try await alice.fetchProfile()
        XCTAssertEqual(profile?.openrouterModel, ModelCatalog.defaultModel)
        try await alice.updateModel("openai/gpt-4o")
        let updatedProfile = try await alice.fetchProfile()
        XCTAssertEqual(updatedProfile?.openrouterModel, "openai/gpt-4o")

        let essay = try await alice.createTask(NewTask(title: "Finish essay", dueAt: date("2026-10-02T21:00:00Z"), priority: .high))
        XCTAssertEqual(essay.priority, .high)
        XCTAssertNotNil(essay.userId)
        let undated = try await alice.createTask(NewTask(title: "Someday", notes: "maybe"))

        let completed = try await alice.setTaskCompleted(id: essay.id, completed: true)
        XCTAssertEqual(completed?.completed, true)
        XCTAssertNotNil(completed?.completedAt, "the trigger stamps completed_at")

        let open = try await alice.fetchTasks(.allOpen)
        XCTAssertEqual(open.map(\.id), [undated.id])
        let working = try await alice.fetchTasks(.workingSet(now: Date()))
        XCTAssertEqual(Set(working.map(\.id)), [essay.id, undated.id])
        let friday = DayKey("2026-10-02")!.interval(in: newYorkCalendar)
        let dueFriday = try await alice.fetchTasks(TaskQuery(dueRange: friday))
        XCTAssertEqual(dueFriday.map(\.id), [essay.id])
        let fridayOrUndated = try await alice.fetchTasks(TaskQuery(dueRange: friday, includeUndated: true, openOnly: true))
        XCTAssertEqual(fridayOrUndated.map(\.id), [undated.id])

        let cleared = try await alice.updateTask(id: undated.id, TaskUpdate(notes: .some(nil), dueAt: .some(date("2026-10-05T12:00:00Z"))))
        XCTAssertNil(cleared?.notes)
        XCTAssertEqual(cleared?.dueAt, date("2026-10-05T12:00:00Z"))

        // Row-Level Security: Bob sees and touches nothing of Alice's.
        let bobsView = try await bob.fetchTasks(TaskQuery())
        XCTAssertEqual(bobsView, [])
        let bobUpdate = try await bob.setTaskCompleted(id: undated.id, completed: true)
        XCTAssertNil(bobUpdate)
        let bobDelete = try await bob.deleteTask(id: undated.id)
        XCTAssertNil(bobDelete)
        let stillThere = try await alice.fetchTask(id: undated.id)
        XCTAssertEqual(stillThere?.completed, false)

        let deleted = try await alice.deleteTask(id: undated.id)
        XCTAssertEqual(deleted?.title, "Someday")
        let deletedAgain = try await alice.deleteTask(id: undated.id)
        XCTAssertNil(deletedAgain)

        // The database rejects invalid data even if a client bug let it through.
        do {
            _ = try await alice.createTask(NewTask(title: "   "))
            XCTFail("blank titles must be rejected")
        } catch let AriaError.server(status, code, _) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, "23514")
        }
    }

    func testEventsUpsertsAndPlannerDays() async throws {
        let alice = try await makeUser("alice")
        let timed = try await alice.createEvent(NewEvent(title: "Dentist", startAt: date("2026-10-01T13:00:00Z"),
                                                         endAt: date("2026-10-01T14:00:00Z")))
        let stored = AllDayRange.stored(first: DayKey("2026-10-01")!, last: DayKey("2026-10-01")!)
        let allDay = try await alice.createEvent(NewEvent(title: "Holiday", startAt: stored.start, endAt: stored.end, allDay: true))
        let otherDay = try await alice.createEvent(NewEvent(title: "Tomorrow", startAt: date("2026-10-02T13:00:00Z"),
                                                            endAt: date("2026-10-02T14:00:00Z")))

        let tokyo = calendar(TimeZone(identifier: "Asia/Tokyo")!)
        for cal in [newYorkCalendar, tokyo] {
            let day = DayKey("2026-10-01")!.interval(in: cal)
            let events = try await alice.fetchEvents(overlapping: day, calendar: cal)
            XCTAssertTrue(events.contains { $0.id == allDay.id }, "all-day events show on their date in every time zone")
            XCTAssertFalse(events.contains { $0.id == otherDay.id })
        }
        let newYorkDay = try await alice.fetchEvents(overlapping: DayKey("2026-10-01")!.interval(in: newYorkCalendar),
                                                     calendar: newYorkCalendar)
        XCTAssertEqual(Set(newYorkDay.map(\.id)), [timed.id, allDay.id])

        // Upsert keyed on the iOS calendar identifier keeps one row with a stable id.
        let calendarId = "EK-\(UUID().uuidString)"
        let first = try await alice.upsertEventByCalendarId(NewEvent(title: "Imported", startAt: date("2026-10-03T13:00:00Z"),
                                                                     endAt: date("2026-10-03T14:00:00Z"), iosCalendarEventId: calendarId))
        let second = try await alice.upsertEventByCalendarId(NewEvent(title: "Imported (renamed)", startAt: date("2026-10-03T13:00:00Z"),
                                                                      endAt: date("2026-10-03T15:00:00Z"), iosCalendarEventId: calendarId))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.title, "Imported (renamed)")
        let byCalendarId = try await alice.fetchEventRows(calendarIds: [calendarId, "missing,(weird)\"id"])
        XCTAssertEqual(byCalendarId.map(\.id), [first.id])
        let byIds = try await alice.fetchEvents(ids: [timed.id, otherDay.id, UUID()])
        XCTAssertEqual(Set(byIds.map(\.id)), [timed.id, otherDay.id])

        let moved = try await alice.updateEvent(id: timed.id, EventUpdate(startAt: date("2026-10-01T15:00:00Z"),
                                                                            endAt: date("2026-10-01T16:00:00Z"),
                                                                            iosCalendarEventId: .some("EK-linked")))
        XCTAssertEqual(moved?.iosCalendarEventId, "EK-linked")
        XCTAssertGreaterThan(moved!.updatedAt!, timed.updatedAt!)
        let removed = try await alice.deleteEvent(id: otherDay.id)
        XCTAssertEqual(removed?.id, otherDay.id)

        // Planner day notes upsert on (user, date).
        let day = DayKey("2026-10-01")!
        let note = try await alice.savePlannerDay(day, notes: "Pack lunch")
        let renote = try await alice.savePlannerDay(day, notes: "Pack lunch + umbrella")
        XCTAssertEqual(note.id, renote.id)
        let fetchedDay = try await alice.fetchPlannerDay(day)
        XCTAssertEqual(fetchedDay?.notes, "Pack lunch + umbrella")
        let emptyDay = try await alice.fetchPlannerDay(day.adding(days: 1))
        XCTAssertNil(emptyDay)
    }

    func testSyncedKeyAndDevicesArePrivatePerAccount() async throws {
        let alice = try await makeUser("alice")
        let bob = try await makeUser("bob")

        let none = try await alice.fetchSyncedKey()
        XCTAssertNil(none)
        try await alice.saveSyncedKey("sk-or-v1-alice")
        try await alice.saveSyncedKey(" sk-or-v1-alice-2 ")
        let saved = try await alice.fetchSyncedKey()
        XCTAssertEqual(saved, "sk-or-v1-alice-2", "saving again replaces the key")
        let bobsView = try await bob.fetchSyncedKey()
        XCTAssertNil(bobsView, "keys are private to their account")

        try await alice.registerDevice(deviceId: "alice-iphone-0001", name: "Alice's iPhone", platform: .ios)
        try await alice.registerDevice(deviceId: "alice-iphone-0001", name: "Alice's iPhone", platform: .ios)
        try await alice.registerDevice(deviceId: "alice-browser-0001", name: "Safari on Mac", platform: .web)
        let devices = try await alice.fetchDevices()
        XCTAssertEqual(Set(devices.map(\.deviceId)), ["alice-iphone-0001", "alice-browser-0001"])
        XCTAssertTrue(devices.allSatisfy { $0.isOnline() })
        let bobsDevices = try await bob.fetchDevices()
        XCTAssertTrue(bobsDevices.isEmpty, "devices are private to their account")
        try await bob.removeDevice(deviceId: "alice-iphone-0001")

        let stillThere = try await alice.touchDevice(deviceId: "alice-iphone-0001")
        XCTAssertTrue(stillThere, "Bob can't sign Alice's devices out")
        try await alice.removeDevice(deviceId: "alice-iphone-0001")
        let afterRemoval = try await alice.touchDevice(deviceId: "alice-iphone-0001")
        XCTAssertFalse(afterRemoval, "a removed device learns it was signed out")

        try await alice.clearSyncedKey()
        let cleared = try await alice.fetchSyncedKey()
        XCTAssertNil(cleared)
    }

    func testConversationLogRefreshAndSignOut() async throws {
        let alice = try await makeUser("alice")
        let start = Date()
        try await alice.appendConversation([
            NewConversationEntry(role: .user, content: "Add milk", createdAt: start),
            NewConversationEntry(role: .assistant, content: nil,
                                 toolCalls: [["id": "c1", "type": "function", "function": ["name": "create_task", "arguments": "{}"]]],
                                 createdAt: start.addingTimeInterval(0.001)),
            NewConversationEntry(role: .tool, content: #"{"ok":true}"#, toolCalls: ["tool_call_id": "c1", "name": "create_task"],
                                 createdAt: start.addingTimeInterval(0.002)),
            NewConversationEntry(role: .assistant, content: "Added milk.", createdAt: start.addingTimeInterval(0.003)),
        ])
        let log = try await alice.fetchConversation(limit: 10)
        XCTAssertEqual(log.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(log[2].toolCalls?["tool_call_id"], "c1")
        XCTAssertEqual(ConversationHistory.contextMessages(from: log), [.user("Add milk"), .assistant("Added milk.")])
        try await alice.clearConversation()
        let cleared = try await alice.fetchConversation()
        XCTAssertEqual(cleared, [])

        let before = await alice.auth.currentSession
        let refreshed = try await alice.auth.refreshSession()
        // (The access token can be byte-identical when refreshed within the same second.)
        XCTAssertNotEqual(refreshed.refreshToken, before?.refreshToken, "refresh tokens rotate")
        XCTAssertGreaterThanOrEqual(refreshed.expiresAt, before!.expiresAt)
        _ = try await alice.fetchTasks(.allOpen) // the new token works

        let email = before!.user.email!
        await alice.auth.signOut()
        do {
            _ = try await alice.fetchTasks(.allOpen)
            XCTFail("signed out")
        } catch {
            XCTAssertEqual(error as? AriaError, .notAuthenticated)
        }
        do {
            _ = try await alice.auth.signIn(email: email, password: "wrong password")
            XCTFail("wrong password")
        } catch let AriaError.server(status, code, message) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, "invalid_credentials")
            XCTAssertEqual(message, "Invalid login credentials")
        }
        let session = try await alice.auth.signIn(email: email, password: "correct-horse-battery")
        XCTAssertEqual(session.user.email, email)
        XCTAssertEqual(session.user.displayName, "Alice")
    }

    /// The whole spec §3 flow against the real database, with a scripted model standing
    /// in for OpenRouter.
    func testAssistantToolCallsWriteThroughSupabase() async throws {
        let alice = try await makeUser("alice")
        let existing = try await alice.createTask(NewTask(title: "Call the bank"))
        let model = ScriptedModel([
            ChatCompletion(message: .assistant(nil, toolCalls: [
                toolCall("c1", "create_task", #"{"title":"Finish essay","due_at":"2026-10-02T17:00:00-04:00","priority":3}"#),
                toolCall("c2", "create_event", #"{"title":"Study","start_at":"2026-10-01T18:00:00-04:00","end_at":"2026-10-01T19:00:00-04:00"}"#),
                toolCall("c3", "complete_task", "{\"task_id\":\"\(existing.id.lowercasedString)\"}"),
            ])),
            ChatCompletion(message: .assistant(nil, toolCalls: [
                toolCall("c4", "list_events_for_range", #"{"start":"2026-10-01","end":"2026-10-01"}"#),
            ])),
            ChatCompletion(message: .assistant("Added 'Finish essay' due Friday 5pm, booked a study block, and ticked off the bank call.")),
        ])
        let engine = AssistantEngine(client: model, executor: ToolExecutor(data: alice, calendar: newYorkCalendar))
        let tasks = try await alice.fetchTasks(.workingSet())
        let reply = try await engine.respond(to: "Add finish essay due Friday 5pm, study Thursday 6pm, and I called the bank",
                                             model: "anthropic/claude-sonnet-4.5", history: [],
                                             snapshot: PlannerSnapshot(tasks: tasks, events: []))
        XCTAssertEqual(reply.outcomes.map(\.succeeded), [true, true, true, true])
        XCTAssertEqual(reply.mutations.count, 3)
        let listed = try JSONValue.parse(model.requests[2].messages.last?.content ?? "")
        XCTAssertEqual(listed["events"]?.arrayValue?.first?["title"], "Study")
        XCTAssertEqual(listed["events"]?.arrayValue?.first?["start_at"], "2026-10-01T18:00:00-04:00")

        let after = try await alice.fetchTasks(.workingSet())
        let essay = after.first { $0.title == "Finish essay" }
        XCTAssertEqual(essay?.source, .ai)
        XCTAssertEqual(essay?.dueAt, date("2026-10-02T21:00:00Z"))
        XCTAssertEqual(essay?.priority, .high)
        XCTAssertEqual(after.first { $0.id == existing.id }?.completed, true)
        let events = try await alice.fetchEventRows(from: date("2026-10-01T00:00:00Z"), to: date("2026-10-03T00:00:00Z"))
        XCTAssertEqual(events.map(\.title), ["Study"])
        XCTAssertEqual(events.first?.source, .ai)

        try await alice.appendConversation(ConversationHistory.logEntries(for: reply, startingAt: Date()))
        let log = try await alice.fetchConversation()
        XCTAssertEqual(log.map(\.role), [.user, .assistant, .tool, .tool, .tool, .assistant, .tool, .assistant])
        XCTAssertEqual(log.last?.content, reply.text)
    }
}
