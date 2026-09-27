import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import AriaKit

/// Lock Screen + Dynamic Island presentation of the current/next item (spec §4.2):
/// a countdown or progress bar for events, and a "Mark done" button (LiveActivityIntent).
/// The activity goes stale at midnight; from then until the app ends it (next launch or
/// background refresh) it shows a "day is over" state instead of yesterday's item.
struct AriaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AriaActivityAttributes.self) { context in
            Group {
                if context.isStale {
                    DayOverView()
                } else {
                    LockScreenLiveActivityView(state: context.state)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.35))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(AriaLink.today)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KindIcon(state: context.state, isStale: context.isStale)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale {
                        TimingText(state: context.state)
                            .font(.callout.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.isStale ? DayOverView.title : context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        Text(DayOverView.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            EventProgress(state: context.state)
                            MarkDoneButton(state: context.state)
                        }
                    }
                }
            } compactLeading: {
                KindIcon(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                if !context.isStale {
                    TimingText(state: context.state)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 52)
                }
            } minimal: {
                KindIcon(state: context.state, isStale: context.isStale)
            }
            .widgetURL(AriaLink.today)
            .keylineTint(Color.accentColor)
        }
    }
}

private struct LockScreenLiveActivityView: View {
    let state: AriaActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                KindIcon(state: state)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.kind == .event ? "Up next" : (state.isOverdue ? "Overdue task" : "Top task today"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(2)
                }
                Spacer()
                TimingText(state: state)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .multilineTextAlignment(.trailing)
            }
            EventProgress(state: state)
            MarkDoneButton(state: state)
        }
    }
}

/// Shown after midnight, once yesterday's item no longer applies.
private struct DayOverView: View {
    static let title = "That's a wrap for today"
    static let subtitle = "Open Aria to see today's plan."

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.stars.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title)
                    .font(.headline)
                Text(Self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct KindIcon: View {
    let state: AriaActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        if isStale {
            Image(systemName: "moon.stars.fill")
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: state.kind == .event ? "calendar" : (state.priority >= 3 ? "flag.fill" : "checklist"))
                .foregroundStyle(state.isOverdue ? Color.red : Color.accentColor)
        }
    }
}

/// Countdown to an upcoming event, time left in a running one, or a task's due time.
private struct TimingText: View {
    let state: AriaActivityAttributes.ContentState

    var body: some View {
        let now = Date()
        if state.kind == .event, let start = state.start, let end = state.end {
            if now < start {
                Text(timerInterval: now...start, countsDown: true)
            } else {
                Text(timerInterval: start...max(end, start), countsDown: true)
            }
        } else if let due = state.dueAt {
            Text(due, style: .time)
        } else {
            Text("Today")
        }
    }
}

/// A live progress bar while an event is happening.
private struct EventProgress: View {
    let state: AriaActivityAttributes.ContentState

    var body: some View {
        if state.kind == .event, let start = state.start, let end = state.end, end > start {
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(Color.accentColor)
        }
    }
}

private struct MarkDoneButton: View {
    let state: AriaActivityAttributes.ContentState

    var body: some View {
        Button(intent: CompleteLiveItemIntent(itemId: state.itemId)) {
            Label(state.kind == .task ? "Mark done" : "Dismiss", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
    }
}
