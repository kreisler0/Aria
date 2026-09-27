import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import AriaKit

/// Lock Screen + Dynamic Island presentation of the current/next item (spec §4.2):
/// a countdown or progress bar for events, and a "Mark done" button (LiveActivityIntent).
struct AriaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AriaActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AriaLink.today)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KindIcon(state: context.state)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimingText(state: context.state)
                        .font(.callout.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        EventProgress(state: context.state)
                        MarkDoneButton(state: context.state)
                    }
                }
            } compactLeading: {
                KindIcon(state: context.state)
            } compactTrailing: {
                TimingText(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                KindIcon(state: context.state)
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

private struct KindIcon: View {
    let state: AriaActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.kind == .event ? "calendar" : (state.priority >= 3 ? "flag.fill" : "checklist"))
            .foregroundStyle(state.isOverdue ? Color.red : Color.accentColor)
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
