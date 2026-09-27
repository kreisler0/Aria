import BackgroundTasks
import Foundation
import UIKit
import WidgetKit
import AriaKit

/// Background app refresh: flushes widget toggles, runs the calendar sync and refreshes
/// the widget cache while the app isn't open (spec §4.3 "via background app refresh").
enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "aria.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule() // keep the chain going
        let environment = SharedEnvironment()
        guard let client = environment.makeClient(), let user = await client.auth.currentUser else { return }
        await PendingCompletions.flush(client: client, store: environment.store)
        if environment.store.calendarSyncEnabled && EventKitSync.isAuthorized {
            _ = try? await EventKitSync().sync(client: client, userId: user.id, shared: environment.store)
        }
        let calendar = Calendar.current
        let now = Date()
        let window = DateInterval(start: DayKey(now, calendar: calendar).startDate(in: calendar), duration: 8 * 86_400)
        if let tasks = try? await client.fetchTasks(.workingSet(now: now)),
           let events = try? await client.fetchEvents(overlapping: window, calendar: calendar) {
            environment.store.saveSnapshot(WidgetSnapshot(generatedAt: now, tasks: tasks, events: events))
            WidgetCenter.shared.reloadAllTimelines()
            await LiveActivityManager.shared.update(tasks: tasks, events: events,
                                                    enabled: environment.store.liveActivitiesEnabled)
        }
    }
}

enum Haptics {
    @MainActor
    static func completed() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
