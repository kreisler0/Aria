import SwiftUI
import AriaKit

/// The daily home screen (spec §6 minimalism): a greeting, the next 3–5 items and the
/// floating AI bar — nothing else.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var editingTask: TaskItem?
    @State private var editingEvent: EventItem?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        upcomingCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await model.refresh() }

                if sizeClass != .regular || model.selectedTab != .assistant {
                    AIInputBar { model.showAssistant = true }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .frame(maxWidth: 680)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.showQuickAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Quick add")
                }
            }
            .sheet(item: $editingTask) { TaskEditorView(task: $0) }
            .sheet(item: $editingEvent) { EventEditorView(event: $0) }
        }
    }

    private var header: some View {
        let now = Date()
        let name = model.user?.displayName?.split(separator: " ").first.map(String.init)
        return VStack(alignment: .leading, spacing: 6) {
            Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(name.map { "\(Planner.greeting(for: now, calendar: .current)), \($0)" } ?? Planner.greeting(for: now, calendar: .current))
                .font(.system(.largeTitle, design: .rounded).bold())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var upcomingCard: some View {
        let items = model.upcoming
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Up next")
                        .font(.headline)
                    Spacer()
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                }
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text("Nothing else today")
                            .font(.headline)
                        Text("Ask Aria to plan something, or enjoy the free time.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(items) { item in
                        PlannerItemRow(item: item)
                            .onTapGesture { open(item) }
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
            .animation(AriaTheme.spring, value: items)
        }
    }

    private func open(_ item: PlannerItem) {
        switch item {
        case .task(let task): editingTask = task
        case .event(let event): editingEvent = event
        }
    }
}
