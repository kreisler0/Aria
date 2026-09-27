import XCTest
@testable import AriaKit

final class PlannerTests: XCTestCase {
    let cal = calendar(newYork)
    let now = date("2026-09-27T13:41:00Z") // Sunday 09:41 in New York

    func testUpcomingMixesTodaysItemsInTimeOrder() {
        let tasks = [
            TaskItem(id: uuid(1), title: "Overdue report", dueAt: date("2026-09-26T21:00:00Z"), priority: .high),
            TaskItem(id: uuid(2), title: "Pay rent", dueAt: date("2026-09-27T20:00:00Z")),
            TaskItem(id: uuid(3), title: "Next week", dueAt: date("2026-10-04T20:00:00Z")),
            TaskItem(id: uuid(4), title: "Important someday", priority: .high),
            TaskItem(id: uuid(5), title: "Trivial someday", priority: .low),
            TaskItem(id: uuid(6), title: "Already done", dueAt: date("2026-09-27T15:00:00Z"), completed: true),
        ]
        let events = [
            EventItem(id: uuid(7), title: "Brunch", startAt: date("2026-09-27T15:00:00Z"), endAt: date("2026-09-27T16:00:00Z")),
            EventItem(id: uuid(8), title: "Early run", startAt: date("2026-09-27T11:00:00Z"), endAt: date("2026-09-27T12:00:00Z")),
            EventItem(id: uuid(9), title: "Festival", startAt: date("2026-09-27T00:00:00Z"), endAt: date("2026-09-28T00:00:00Z"), allDay: true),
        ]
        let items = Planner.upcoming(tasks: tasks, events: events, now: now, calendar: cal)
        XCTAssertEqual(items.map(\.title), ["Overdue report", "Festival", "Brunch", "Pay rent", "Important someday"])
        XCTAssertEqual(Planner.upcoming(tasks: tasks, events: events, now: now, calendar: cal, limit: 3).count, 3)
    }

    func testWidgetTasks() {
        let tasks = [
            TaskItem(id: uuid(1), title: "Undated high", priority: .high),
            TaskItem(id: uuid(2), title: "Due today", dueAt: date("2026-09-27T20:00:00Z")),
            TaskItem(id: uuid(3), title: "Ticked today", dueAt: date("2026-09-27T18:00:00Z"), completed: true,
                     completedAt: date("2026-09-27T13:00:00Z")),
            TaskItem(id: uuid(4), title: "Ticked yesterday", completed: true, completedAt: date("2026-09-26T13:00:00Z")),
            TaskItem(id: uuid(5), title: "Future", dueAt: date("2026-09-30T20:00:00Z")),
            TaskItem(id: uuid(6), title: "Undated low", priority: .low),
        ]
        XCTAssertEqual(Planner.widgetTasks(tasks: tasks, now: now, calendar: cal, limit: 10).map(\.title),
                       ["Due today", "Undated high", "Undated low", "Ticked today"])
        XCTAssertEqual(Planner.widgetTasks(tasks: tasks, now: now, calendar: cal, limit: 2).map(\.title), ["Due today", "Undated high"])
    }

    func testNextEvents() {
        let events = [
            EventItem(id: uuid(1), title: "Ended", startAt: date("2026-09-27T11:00:00Z"), endAt: date("2026-09-27T12:00:00Z")),
            EventItem(id: uuid(2), title: "In progress", startAt: date("2026-09-27T13:30:00Z"), endAt: date("2026-09-27T14:00:00Z")),
            EventItem(id: uuid(3), title: "Tomorrow", startAt: date("2026-09-28T13:00:00Z"), endAt: date("2026-09-28T14:00:00Z")),
            EventItem(id: uuid(4), title: "Later", startAt: date("2026-09-27T18:00:00Z"), endAt: date("2026-09-27T19:00:00Z")),
            EventItem(id: uuid(5), title: "Next week", startAt: date("2026-10-04T18:00:00Z"), endAt: date("2026-10-04T19:00:00Z")),
        ]
        XCTAssertEqual(Planner.nextEvents(events: events, now: now, calendar: cal).map(\.title), ["In progress", "Later", "Tomorrow"])
    }

    func testLiveActivityPrefersCurrentEventThenSoonEventThenTopTask() {
        let current = EventItem(id: uuid(1), title: "Meeting", startAt: date("2026-09-27T13:30:00Z"), endAt: date("2026-09-27T14:30:00Z"))
        let soon = EventItem(id: uuid(2), title: "Call", startAt: date("2026-09-27T14:20:00Z"), endAt: date("2026-09-27T14:40:00Z"))
        let later = EventItem(id: uuid(3), title: "Dinner", startAt: date("2026-09-27T23:00:00Z"), endAt: date("2026-09-28T00:00:00Z"))
        let allDay = EventItem(id: uuid(4), title: "Holiday", startAt: date("2026-09-27T00:00:00Z"), endAt: date("2026-09-28T00:00:00Z"), allDay: true)
        let low = TaskItem(id: uuid(5), title: "Low", dueAt: date("2026-09-27T15:00:00Z"), priority: .low)
        let high = TaskItem(id: uuid(6), title: "High", dueAt: date("2026-09-27T22:00:00Z"), priority: .high)
        let tomorrow = TaskItem(id: uuid(7), title: "Tomorrow", dueAt: date("2026-09-28T15:00:00Z"), priority: .high)

        XCTAssertEqual(Planner.liveActivityItem(tasks: [low, high], events: [current, soon, later, allDay], now: now, calendar: cal)?.title, "Meeting")
        XCTAssertEqual(Planner.liveActivityItem(tasks: [low, high], events: [soon, later, allDay], now: now, calendar: cal)?.title, "Call")
        XCTAssertEqual(Planner.liveActivityItem(tasks: [low, high, tomorrow], events: [later, allDay], now: now, calendar: cal)?.title, "High")
        XCTAssertEqual(Planner.liveActivityItem(tasks: [tomorrow], events: [later, allDay], now: now, calendar: cal)?.title, "Dinner")
        XCTAssertNil(Planner.liveActivityItem(tasks: [tomorrow], events: [allDay], now: now, calendar: cal))
        // "Mark done" on the Lock Screen dismisses an event for the rest of the day.
        XCTAssertEqual(Planner.liveActivityItem(tasks: [low], events: [current], now: now, calendar: cal,
                                                dismissed: [PlannerItem.event(current).id])?.title, "Low")
    }

    func testGreeting() {
        XCTAssertEqual(Planner.greeting(for: date("2026-09-27T13:41:00Z"), calendar: cal), "Good morning")
        XCTAssertEqual(Planner.greeting(for: date("2026-09-27T18:00:00Z"), calendar: cal), "Good afternoon")
        XCTAssertEqual(Planner.greeting(for: date("2026-09-28T02:00:00Z"), calendar: cal), "Good evening")
    }

    func testTaskOrder() {
        let tasks = [
            TaskItem(id: uuid(1), title: "undated low", priority: .low, createdAt: date("2026-09-01T00:00:00Z")),
            TaskItem(id: uuid(2), title: "late", dueAt: date("2026-10-01T00:00:00Z")),
            TaskItem(id: uuid(3), title: "undated high", priority: .high),
            TaskItem(id: uuid(4), title: "early", dueAt: date("2026-09-28T00:00:00Z")),
        ]
        XCTAssertEqual(tasks.sorted(by: Planner.taskOrder).map(\.title), ["early", "late", "undated high", "undated low"])
    }
}

final class SharedStoreTests: XCTestCase {
    func makeStore() -> SharedStore {
        SharedStore(appGroup: "aria.tests.\(UUID().uuidString)")
    }

    func testSnapshotRoundTripAndLocalToggle() {
        let store = makeStore()
        XCTAssertNil(store.loadSnapshot())
        let snapshot = WidgetSnapshot(generatedAt: date("2026-09-27T13:00:00Z"),
                                      tasks: [TaskItem(id: uuid(1), title: "Milk")],
                                      events: [EventItem(id: uuid(2), title: "Brunch", startAt: date("2026-09-27T15:00:00Z"),
                                                         endAt: date("2026-09-27T16:00:00Z"))])
        store.saveSnapshot(snapshot)
        XCTAssertEqual(store.loadSnapshot(), snapshot)
        let toggled = snapshot.settingTask(uuid(1), completed: true, at: date("2026-09-27T13:05:00Z"))
        XCTAssertTrue(toggled.tasks[0].completed)
        XCTAssertEqual(toggled.tasks[0].completedAt, date("2026-09-27T13:05:00Z"))
    }

    func testPendingCompletionQueue() {
        let store = makeStore()
        let first = PendingCompletion(taskId: uuid(1), completed: true, at: date("2026-09-27T13:00:00Z"))
        store.enqueuePendingCompletion(first)
        store.enqueuePendingCompletion(PendingCompletion(taskId: uuid(2), completed: true, at: date("2026-09-27T13:01:00Z")))
        let retoggle = PendingCompletion(taskId: uuid(1), completed: false, at: date("2026-09-27T13:02:00Z"))
        store.enqueuePendingCompletion(retoggle)
        XCTAssertEqual(store.pendingCompletions().map(\.taskId), [uuid(2), uuid(1)])
        // Syncing the stale entry must not drop the newer toggle.
        store.removePendingCompletions([first])
        XCTAssertEqual(store.pendingCompletions().count, 2)
        store.removePendingCompletions(store.pendingCompletions())
        XCTAssertEqual(store.pendingCompletions(), [])
    }

    func testDismissedLiveItemsArePerDay() {
        let store = makeStore()
        let today = DayKey("2026-09-27")!
        store.dismissLiveItem("event-1", on: today)
        store.dismissLiveItem("task-2", on: today)
        XCTAssertEqual(store.dismissedLiveItems(on: today), ["event-1", "task-2"])
        XCTAssertEqual(store.dismissedLiveItems(on: today.adding(days: 1)), [])
        store.dismissLiveItem("task-3", on: today.adding(days: 3))
        XCTAssertEqual(store.dismissedLiveItems(on: today), [], "old days are forgotten")
    }

    func testPreferencesAndConfig() {
        let store = makeStore()
        XCTAssertTrue(store.liveActivitiesEnabled, "on by default")
        XCTAssertFalse(store.calendarSyncEnabled, "off until the user grants access")
        store.calendarSyncExcluded = ["b", "a"]
        XCTAssertEqual(store.calendarSyncExcluded, ["a", "b"])
        let config = SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "k")
        store.supabaseConfig = config
        XCTAssertEqual(store.supabaseConfig, config)
        store.supabaseConfig = nil
        XCTAssertNil(store.supabaseConfig)
        let records = [SyncRecord(rowId: uuid(1), externalId: "E1", content: SyncContent(title: "x", notes: nil,
                                  startAt: date("2026-09-27T13:00:00Z"), endAt: date("2026-09-27T14:00:00Z"), allDay: false))]
        store.saveSyncRecords(records, for: uuid(9))
        XCTAssertEqual(store.syncRecords(for: uuid(9)), records)
        XCTAssertEqual(store.syncRecords(for: uuid(8)), [])
    }

    func testKeychainSessionStoreRoundTrip() throws {
        #if canImport(Security)
        // The real Keychain needs a signed app (entitlements); it is exercised by the app itself.
        throw XCTSkip("Keychain round-trip runs on platforms without Security.framework")
        #else
        let store = KeychainSessionStore(keychain: KeychainStore(service: "aria.tests.\(UUID().uuidString)"))
        XCTAssertNil(store.loadSession())
        let session = AuthSession(accessToken: "A", refreshToken: "R", expiresAt: date("2026-09-27T13:00:00Z"),
                                  user: AuthUser(id: uuid(1), email: "a@b.c", displayName: "Alice"))
        store.saveSession(session)
        XCTAssertEqual(store.loadSession(), session)
        store.saveSession(nil)
        XCTAssertNil(store.loadSession())
        let keys = OpenRouterKeyStore(keychain: KeychainStore(service: "aria.tests.\(UUID().uuidString)"))
        XCTAssertNil(keys.apiKey)
        XCTAssertNoThrow(try keys.save("  sk-or-123 "))
        XCTAssertEqual(keys.apiKey, "sk-or-123")
        XCTAssertNoThrow(try keys.save(""))
        XCTAssertNil(keys.apiKey)
        #endif
    }
}
