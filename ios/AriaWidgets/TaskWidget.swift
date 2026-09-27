import AppIntents
import SwiftUI
import WidgetKit
import AriaKit

/// Today's tasks with checkboxes that complete them right from the Home Screen
/// (`Button(intent:)` + `ToggleTaskIntent`, iOS 17 interactive widgets).
struct TaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.tasks, provider: PlannerTimelineProvider()) { entry in
            TaskWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Today's Tasks")
        .description("See and tick off today's tasks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TaskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlannerEntry

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemLarge: return 9
        default: return 4
        }
    }

    var body: some View {
        let tasks = Planner.widgetTasks(tasks: entry.snapshot?.tasks ?? [], now: entry.date, calendar: .current, limit: limit)
        let openCount = (entry.snapshot?.tasks ?? []).filter { task in
            !task.completed && (task.dueAt.map { Calendar.current.isDate($0, inSameDayAs: entry.date) || $0 < entry.date } ?? false)
        }.count
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            HStack {
                Text("Today")
                    .font(.headline)
                Spacer()
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            if !entry.isSignedIn {
                Spacer()
                Text("Open Aria to sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if tasks.isEmpty {
                Spacer()
                Label("All clear", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                Spacer()
            } else {
                ForEach(tasks) { task in
                    HStack(spacing: 8) {
                        Button(intent: ToggleTaskIntent(taskId: task.id, completed: !task.completed)) {
                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(task.completed ? Color.accentColor : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(task.title)
                                .font(.subheadline)
                                .lineLimit(1)
                                .strikethrough(task.completed)
                                .foregroundStyle(task.completed ? .secondary : .primary)
                            if family != .systemSmall, let due = task.dueAt {
                                Text(due, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(task.isOverdue(at: entry.date) ? Color.red : Color.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if task.priority == .high && family != .systemSmall {
                            Image(systemName: "exclamationmark")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.red)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(AriaLink.tasks)
    }
}

/// The glassy gradient used behind every widget.
struct WidgetBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.purple.opacity(0.10), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
