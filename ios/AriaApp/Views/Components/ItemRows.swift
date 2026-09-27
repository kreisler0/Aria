import SwiftUI
import AriaKit

/// A task with its completion toggle.
struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    var showsDate = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            CompletionCheckbox(isOn: task.completed) {
                Task { await model.toggle(task) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.body)
                        .strikethrough(task.completed, color: .secondary)
                        .foregroundStyle(task.completed ? .secondary : .primary)
                    SourceBadge(source: task.source)
                }
                HStack(spacing: 8) {
                    if showsDate, let due = task.dueAt {
                        Label(due.formatted(.relative(presentation: .named)), systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(task.isOverdue(at: Date()) ? Color.red : Color.secondary)
                    }
                    PriorityBadge(priority: task.priority)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .animation(AriaTheme.spring, value: task.completed)
    }
}

/// A calendar event with a colored time rail.
struct EventRow: View {
    let event: EventItem
    var showsDay = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title.isEmpty ? "(No title)" : event.title)
                        .font(.body)
                    SourceBadge(source: event.source)
                }
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var timing: String {
        let calendar = Calendar.current
        if event.allDay {
            let days = event.firstDay == event.lastDay ? "All day"
                : "All day · until \(event.lastDay.startDate(in: calendar).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
            return days
        }
        let start = event.startAt.formatted(date: showsDay ? .abbreviated : .omitted, time: .shortened)
        let end = event.endAt.formatted(date: calendar.isDate(event.startAt, inSameDayAs: event.endAt) ? .omitted : .abbreviated,
                                        time: .shortened)
        return "\(start) – \(end)"
    }
}

/// Today view's mixed list.
struct PlannerItemRow: View {
    let item: PlannerItem

    var body: some View {
        switch item {
        case .task(let task): TaskRow(task: task)
        case .event(let event): EventRow(event: event)
        }
    }
}

/// The floating glass "Ask Aria" bar pinned to the bottom of Today (spec §6): tapping it
/// expands into the full assistant sheet.
struct AIInputBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating.speed(0.3))
                Text("Ask Aria to plan something…")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Aria")
    }
}
