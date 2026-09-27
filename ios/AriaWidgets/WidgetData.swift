import Foundation
import WidgetKit
import AriaKit

struct PlannerEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let isSignedIn: Bool

    static var placeholder: PlannerEntry {
        let now = Date()
        let calendar = Calendar.current
        let today = DayKey(now, calendar: calendar)
        return PlannerEntry(
            date: now,
            snapshot: WidgetSnapshot(
                generatedAt: now,
                tasks: [
                    TaskItem(title: "Finish essay", dueAt: now.addingTimeInterval(3 * 3600), priority: .high),
                    TaskItem(title: "Call the bank", dueAt: now.addingTimeInterval(5 * 3600)),
                    TaskItem(title: "Buy groceries", priority: .medium),
                ],
                events: [
                    EventItem(title: "Team standup", startAt: now.addingTimeInterval(1800), endAt: now.addingTimeInterval(3600)),
                    EventItem(title: "Lunch with Sam", startAt: now.addingTimeInterval(4 * 3600), endAt: now.addingTimeInterval(5 * 3600)),
                    EventItem(title: "Gym", startAt: today.adding(days: 1).startDate(in: calendar).addingTimeInterval(18 * 3600),
                              endAt: today.adding(days: 1).startDate(in: calendar).addingTimeInterval(19 * 3600)),
                ]),
            isSignedIn: true)
    }
}

/// Loads widget data: fresh from Supabase (with the session shared by the app), falling
/// back to the snapshot the app last wrote.
enum WidgetDataLoader {
    static func cachedEntry(date: Date = Date()) -> PlannerEntry {
        let environment = SharedEnvironment()
        let signedIn = environment.config != nil && KeychainSessionStore(keychain: environment.sessionKeychain).loadSession() != nil
        return PlannerEntry(date: date, snapshot: environment.store.loadSnapshot(), isSignedIn: signedIn)
    }

    static func freshEntry() async -> PlannerEntry {
        let environment = SharedEnvironment()
        guard let client = environment.makeClient(), await client.auth.currentUser != nil else {
            return cachedEntry()
        }
        await PendingCompletions.flush(client: client, store: environment.store)
        let now = Date()
        let calendar = Calendar.current
        let window = DateInterval(start: DayKey(now, calendar: calendar).startDate(in: calendar), duration: 8 * 86_400)
        do {
            async let tasks = client.fetchTasks(.workingSet(now: now))
            async let events = client.fetchEvents(overlapping: window, calendar: calendar)
            let snapshot = WidgetSnapshot(generatedAt: now, tasks: try await tasks, events: try await events)
            environment.store.saveSnapshot(snapshot)
            return PlannerEntry(date: now, snapshot: snapshot, isSignedIn: true)
        } catch {
            return cachedEntry()
        }
    }

    /// Entries at "now" and whenever a visible event ends, so finished events drop off
    /// without waiting for the next reload.
    static func timeline(from entry: PlannerEntry) -> Timeline<PlannerEntry> {
        let now = entry.date
        let calendar = Calendar.current
        let boundaries = (entry.snapshot?.events ?? [])
            .map { $0.displayEnd(in: calendar) }
            .filter { $0 > now && $0 < now.addingTimeInterval(6 * 3600) }
            .sorted()
            .prefix(6)
        let midnight = DayKey(now, calendar: calendar).adding(days: 1).startDate(in: calendar)
        var dates = [now] + boundaries
        if midnight < now.addingTimeInterval(6 * 3600) { dates.append(midnight) }
        let entries = dates.map { PlannerEntry(date: $0, snapshot: entry.snapshot, isSignedIn: entry.isSignedIn) }
        return Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(30 * 60), midnight)))
    }
}

struct PlannerTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlannerEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PlannerEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(WidgetDataLoader.cachedEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlannerEntry>) -> Void) {
        Task {
            let entry = await WidgetDataLoader.freshEntry()
            completion(WidgetDataLoader.timeline(from: entry))
        }
    }
}
