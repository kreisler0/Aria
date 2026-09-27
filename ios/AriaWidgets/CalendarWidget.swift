import SwiftUI
import WidgetKit
import AriaKit

/// The next three events (also on the Lock Screen as a rectangular accessory).
struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.calendar, provider: PlannerTimelineProvider()) { entry in
            CalendarWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Up Next")
        .description("Your next three events.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlannerEntry

    private var events: [EventItem] {
        Planner.nextEvents(events: entry.snapshot?.events ?? [], now: entry.date, calendar: .current, limit: 3)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let next = events.first {
                Text("\(next.title) · \(timeText(next))")
            } else {
                Text("No upcoming events")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                if let next = events.first {
                    Text(next.title).font(.headline).lineLimit(1)
                    Text(timeText(next)).font(.caption)
                    if events.count > 1 {
                        Text("then \(events[1].title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Aria").font(.headline)
                    Text("No upcoming events").font(.caption)
                }
            }
            .widgetURL(AriaLink.calendar)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label("Up next", systemImage: "calendar")
                    .font(.headline)
                    .foregroundStyle(.tint)
                if events.isEmpty {
                    Spacer()
                    Text(entry.isSignedIn ? "Nothing scheduled" : "Open Aria to sign in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(events.prefix(family == .systemSmall ? 2 : 3)) { event in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.accentColor)
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title.isEmpty ? "(No title)" : event.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(timeText(event))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxHeight: 34)
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(AriaLink.calendar)
        }
    }

    private func timeText(_ event: EventItem) -> String {
        let calendar = Calendar.current
        let start = event.displayStart(in: calendar)
        let dayPrefix: String
        if calendar.isDateInToday(start) || event.isInProgress(at: entry.date, calendar: calendar) {
            dayPrefix = ""
        } else if calendar.isDateInTomorrow(start) {
            dayPrefix = "Tomorrow "
        } else {
            dayPrefix = start.formatted(.dateTime.weekday(.abbreviated)) + " "
        }
        if event.allDay { return dayPrefix + "All day" }
        return dayPrefix + start.formatted(date: .omitted, time: .shortened)
    }
}
