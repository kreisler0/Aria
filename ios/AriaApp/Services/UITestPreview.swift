import Foundation
import AriaKit

/// `-AriaUITestPreview`, the launch argument the UI tests use: the app signs in to a day of
/// sample tasks, events and a conversation with no backend, so every screen can be exercised
/// without a Supabase project or an OpenRouter key. Changes stay in memory.
enum UITestPreview {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-AriaUITestPreview")
    /// Any UI-test launch (`-AriaUITest`): UIKit animations are switched off so the tests
    /// don't wait for transitions.
    static let isUITest = isEnabled || ProcessInfo.processInfo.arguments.contains("-AriaUITest")

    struct Sample {
        let user: AuthUser
        let tasks: [TaskItem]
        let events: [EventItem]
        let chat: [ChatBubble]
    }

    static func sample(now: Date = Date(), calendar: Calendar = .current) -> Sample {
        let today = DayKey(now, calendar: calendar)
        func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = today.adding(days: days).startDate(in: calendar)
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        // All-day events are stored as UTC midnights.
        func day(_ days: Int) -> Date { today.adding(days: days).utcMidnight }

        let tasks = [
            TaskItem(title: "Pay rent", dueAt: at(-1, 17), priority: .high),
            TaskItem(title: "Finish essay", dueAt: at(0, 17), priority: .medium, source: .ai),
            TaskItem(title: "Call Mum", dueAt: at(1, 12)),
            TaskItem(title: "Plan next week", dueAt: at(3, 9), priority: .low),
            TaskItem(title: "Read a chapter", priority: .medium),
            TaskItem(title: "Water the plants", dueAt: at(0, 8), completed: true, completedAt: now),
        ]
        let events = [
            EventItem(title: "Aria self-test day", startAt: day(0), endAt: day(1), allDay: true),
            EventItem(title: "Team stand-up", startAt: at(0, 10), endAt: at(0, 10, 15)),
            EventItem(title: "Study session", startAt: at(0, 18), endAt: at(0, 20), source: .ai),
            EventItem(title: "Mum's birthday", startAt: day(1), endAt: day(2), allDay: true),
            EventItem(title: "Lunch with Sam", startAt: at(2, 12, 30), endAt: at(2, 13, 30)),
        ]
        let chat = [
            ChatBubble(role: .user, text: "Add 'Finish essay' due Friday at 5pm"),
            ChatBubble(role: .action(succeeded: true), text: "Created task 'Finish essay'"),
            ChatBubble(role: .action(succeeded: false), text: "Could not find an event called 'Gym'"),
            ChatBubble(role: .assistant, text: "Added 'Finish essay' for Friday at 5pm."),
            ChatBubble(role: .error, text: "OpenRouter could not be reached."),
        ]
        return Sample(user: AuthUser(id: UUID(), email: "self-test@aria.invalid", displayName: "Ada Lovelace"),
                      tasks: tasks, events: events, chat: chat)
    }
}
