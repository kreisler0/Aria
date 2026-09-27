import Foundation

/// A task or an event, for lists that mix both (Today view, widgets, Live Activity).
public enum PlannerItem: Identifiable, Hashable, Sendable {
    case task(TaskItem)
    case event(EventItem)

    public var id: String {
        switch self {
        case .task(let task): return "task-\(task.id.lowercasedString)"
        case .event(let event): return "event-\(event.id.lowercasedString)"
        }
    }

    public var title: String {
        switch self {
        case .task(let task): return task.title
        case .event(let event): return event.title
        }
    }
}

/// Pure planning rules shared by the app, the widgets and the Live Activity.
public enum Planner {
    /// Open tasks: overdue/soonest first, then undated by priority.
    public static func taskOrder(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        switch (lhs.dueAt, rhs.dueAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
        }
    }

    /// The Today view's short list (3–5 items): today's events that haven't ended and open
    /// tasks due today or overdue, in time order; undated high-priority tasks fill any room.
    public static func upcoming(tasks: [TaskItem], events: [EventItem], now: Date, calendar: Calendar,
                                limit: Int = 5) -> [PlannerItem] {
        let today = DayKey(now, calendar: calendar).interval(in: calendar)
        var timed: [(Date, PlannerItem)] = []
        for event in events where event.overlaps(today, calendar: calendar) && event.displayEnd(in: calendar) > now {
            // All-day events sort to the top of the day.
            timed.append((event.allDay ? today.start : event.displayStart(in: calendar), .event(event)))
        }
        for task in tasks where !task.completed {
            if let due = task.dueAt, due < today.end {
                timed.append((due, .task(task)))
            }
        }
        timed.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title) == .orderedAscending
        }
        var items = timed.map(\.1)
        if items.count < limit {
            let undated = tasks.filter { !$0.completed && $0.dueAt == nil && $0.priority >= .medium }.sorted(by: taskOrder)
            items.append(contentsOf: undated.prefix(limit - items.count).map { .task($0) })
        }
        return Array(items.prefix(limit))
    }

    /// The task widget's list: open tasks due today or overdue, then undated ones by
    /// priority, then anything completed today (so a tick stays visible until tomorrow).
    public static func widgetTasks(tasks: [TaskItem], now: Date, calendar: Calendar, limit: Int) -> [TaskItem] {
        let today = DayKey(now, calendar: calendar).interval(in: calendar)
        let dueNow = tasks.filter { !$0.completed && ($0.dueAt.map { $0 < today.end } ?? false) }.sorted(by: taskOrder)
        let undated = tasks.filter { !$0.completed && $0.dueAt == nil }.sorted(by: taskOrder)
        let doneToday = tasks.filter { task in
            guard task.completed, let completedAt = task.completedAt else { return false }
            return today.contains(completedAt) && (task.dueAt.map { $0 < today.end } ?? true)
        }.sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
        return Array((dueNow + undated + doneToday).prefix(limit))
    }

    /// The calendar widget's list: the next events that haven't ended yet.
    public static func nextEvents(events: [EventItem], now: Date, calendar: Calendar, limit: Int = 3) -> [EventItem] {
        events
            .filter { $0.displayEnd(in: calendar) > now }
            .sorted { lhs, rhs in
                let left = lhs.displayStart(in: calendar), right = rhs.displayStart(in: calendar)
                if left != right { return left < right }
                return lhs.allDay && !rhs.allDay
            }
            .prefix(limit)
            .map { $0 }
    }

    /// What the Live Activity shows (spec §4.2): an event in progress, else one starting
    /// within the hour, else the top-priority task due today (or overdue), else the next
    /// event later today. All-day events are skipped; `dismissed` holds item ids the user
    /// marked done from the Lock Screen.
    public static func liveActivityItem(tasks: [TaskItem], events: [EventItem], now: Date, calendar: Calendar,
                                        dismissed: Set<String> = []) -> PlannerItem? {
        let today = DayKey(now, calendar: calendar).interval(in: calendar)
        let todaysEvents = events
            .filter { !$0.allDay && $0.overlaps(today, calendar: calendar) && $0.endAt > now }
            .filter { !dismissed.contains(PlannerItem.event($0).id) }
            .sorted { $0.startAt < $1.startAt }
        if let current = todaysEvents.first(where: { $0.startAt <= now }) {
            return .event(current)
        }
        if let soon = todaysEvents.first(where: { $0.startAt.timeIntervalSince(now) <= 3600 }) {
            return .event(soon)
        }
        let dueTasks = tasks
            .filter { !$0.completed && ($0.dueAt.map { $0 < today.end } ?? false) }
            .filter { !dismissed.contains(PlannerItem.task($0).id) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return taskOrder(lhs, rhs)
            }
        if let task = dueTasks.first {
            return .task(task)
        }
        return todaysEvents.first.map { .event($0) }
    }

    /// "Good morning" / "Good afternoon" / "Good evening".
    public static func greeting(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}
