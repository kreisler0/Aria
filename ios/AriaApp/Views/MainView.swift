import SwiftUI
import AriaKit

/// iPhone: tabs. iPad (regular width): a sidebar split view with the assistant as a
/// first-class destination.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular {
                SidebarLayout()
            } else {
                TabLayout()
            }
        }
        .sheet(isPresented: $model.showQuickAdd) {
            QuickAddView()
                .presentationDetents([.height(260), .medium])
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(AriaTheme.cornerRadius)
        }
        .sheet(isPresented: $model.showAssistant) {
            NavigationStack { AIChatView(isSheet: true) }
                .presentationDetents([.large])
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(AriaTheme.cornerRadius)
        }
    }
}

private struct TabLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(AppTab.today)
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppTab.calendar)
            TaskListView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(AppTab.tasks)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}

private struct SidebarLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List {
                row(.today, "Today", "sun.max")
                row(.calendar, "Calendar", "calendar")
                row(.tasks, "Tasks", "checklist")
                row(.assistant, "Assistant", "sparkles")
                row(.settings, "Settings", "gearshape")
            }
            .navigationTitle("Aria")
        } detail: {
            switch model.selectedTab {
            case .today: TodayView()
            case .calendar: CalendarView()
            case .tasks: TaskListView()
            case .assistant: NavigationStack { AIChatView(isSheet: false) }
            case .settings: SettingsView()
            }
        }
    }

    private func row(_ tab: AppTab, _ title: String, _ icon: String) -> some View {
        Button {
            model.selectedTab = tab
        } label: {
            Label(title, systemImage: icon)
        }
        .listRowBackground(model.selectedTab == tab ? Color.accentColor.opacity(0.18) : Color.clear)
        .foregroundStyle(model.selectedTab == tab ? Color.accentColor : Color.primary)
    }
}

/// Toolbar button that opens the assistant from any screen.
struct AssistantToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            if model.selectedTab == .assistant { return }
            model.showAssistant = true
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("Ask Aria")
    }
}
