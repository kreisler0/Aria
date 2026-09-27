import SwiftUI
import WidgetKit

/// A one-tap entry point that deep-links into the app's Quick Add sheet (spec §4.1:
/// widgets can't host a real keyboard, so typing happens in the app, which opens instantly).
struct QuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.quickAdd, provider: QuickAddProvider()) { _ in
            QuickAddWidgetView()
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(AriaLink.quickAdd)
        }
        .configurationDisplayName("Ask Aria")
        .description("Jump straight to adding a task or asking Aria.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct QuickAddProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
    }

    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .never))
    }
}

struct QuickAddWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
            }
            .accessibilityLabel("Ask Aria")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Text("Ask Aria")
                    .font(.headline)
                HStack {
                    Text("Add a task…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
            }
        }
    }
}
