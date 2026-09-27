import ActivityKit
import Foundation
import AriaKit

/// The Live Activity: the current/next event or the top-priority task of the day.
struct AriaActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            case task
            case event
        }

        /// `PlannerItem.id` ("task-…" / "event-…").
        var itemId: String
        var kind: Kind
        var title: String
        var start: Date?
        var end: Date?
        var dueAt: Date?
        var priority: Int
        var isOverdue: Bool

        init(item: PlannerItem, now: Date) {
            itemId = item.id
            title = item.title
            switch item {
            case .event(let event):
                kind = .event
                start = event.startAt
                end = event.endAt
                dueAt = nil
                priority = 0
                isOverdue = false
            case .task(let task):
                kind = .task
                start = nil
                end = nil
                dueAt = task.dueAt
                priority = task.priority.rawValue
                isOverdue = task.isOverdue(at: now)
            }
        }

        /// True while an event is happening (shows a progress bar).
        func isInProgress(at date: Date) -> Bool {
            guard let start, let end else { return false }
            return start <= date && date < end
        }
    }

    /// The day (`yyyy-MM-dd`) the activity belongs to; it is ended at day rollover.
    var day: String
}
