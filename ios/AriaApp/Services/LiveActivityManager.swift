import ActivityKit
import Foundation
import AriaKit

/// Keeps one Live Activity showing the current/next event or the top-priority task of the
/// day (spec §4.2). It is started or updated whenever the day's data changes, moves on
/// when the item is marked done, and ends at day rollover (its stale date is midnight).
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private init() {}

    func update(tasks: [TaskItem], events: [EventItem], enabled: Bool) async {
        let calendar = Calendar.current
        let now = Date()
        let today = DayKey(now, calendar: calendar)
        let store = SharedEnvironment().store
        let activities = Activity<AriaActivityAttributes>.activities

        // Day rollover: yesterday's activity goes away.
        for activity in activities where activity.attributes.day != today.string {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              let item = Planner.liveActivityItem(tasks: tasks, events: events, now: now, calendar: calendar,
                                                  dismissed: store.dismissedLiveItems(on: today)) else {
            await endAll()
            return
        }

        let state = AriaActivityAttributes.ContentState(item: item, now: now)
        let content = ActivityContent(state: state, staleDate: today.adding(days: 1).startDate(in: calendar))
        if let current = activities.first(where: { $0.attributes.day == today.string }) {
            if current.content.state != state {
                await current.update(content)
            }
        } else {
            // Only allowed while the app is in the foreground; the next foreground retries.
            _ = try? Activity.request(attributes: AriaActivityAttributes(day: today.string), content: content, pushType: nil)
        }
    }

    /// Re-evaluates from the widget cache (used after "Mark done" on the Lock Screen).
    func refreshFromSnapshot() async {
        let store = SharedEnvironment().store
        guard let snapshot = store.loadSnapshot() else { return }
        await update(tasks: snapshot.tasks, events: snapshot.events, enabled: store.liveActivitiesEnabled)
    }

    func endAll() async {
        for activity in Activity<AriaActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
