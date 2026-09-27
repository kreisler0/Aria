import SwiftUI
import AriaKit

/// All tasks, grouped by when they're due, with full create/edit/complete/delete.
struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: TaskItem?
    @State private var showNewTask = false
    @State private var showCompleted = false

    private struct Section: Identifiable {
        let id: String
        let title: String
        let tasks: [TaskItem]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                List {
                    let sections = self.sections
                    if sections.allSatisfy({ $0.tasks.isEmpty }) {
                        ContentUnavailableView("No tasks", systemImage: "checklist",
                                               description: Text("Tap + or ask Aria to add one."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(sections.filter { !$0.tasks.isEmpty }) { section in
                        SwiftUI.Section(section.title) {
                            ForEach(section.tasks) { task in
                                TaskRow(task: task)
                                    .onTapGesture { editing = task }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            Task { await model.deleteTask(task) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            Task { await model.toggle(task) }
                                        } label: {
                                            Label(task.completed ? "Undo" : "Done", systemImage: task.completed ? "arrow.uturn.backward" : "checkmark")
                                        }
                                        .tint(.green)
                                    }
                                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .animation(AriaTheme.spring, value: model.tasks)
                .refreshable { await model.refresh() }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle(isOn: $showCompleted.animation(AriaTheme.spring)) {
                        Label("Show completed", systemImage: showCompleted ? "eye" : "eye.slash")
                    }
                    .toggleStyle(.button)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    AssistantToolbarButton()
                    Button {
                        showNewTask = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New task")
                }
            }
            .sheet(item: $editing) { TaskEditorView(task: $0) }
            .sheet(isPresented: $showNewTask) { TaskEditorView() }
        }
    }

    private var sections: [Section] {
        let calendar = Calendar.current
        let now = Date()
        let today = DayKey(now, calendar: calendar).interval(in: calendar)
        let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: today.end) ?? today.end
        let open = model.tasks.filter { !$0.completed }.sorted(by: Planner.taskOrder)
        var overdue: [TaskItem] = [], dueToday: [TaskItem] = [], tomorrow: [TaskItem] = []
        var later: [TaskItem] = [], someday: [TaskItem] = []
        for task in open {
            guard let due = task.dueAt else {
                someday.append(task)
                continue
            }
            if due < now && due < today.start { overdue.append(task) }
            else if due < today.end { dueToday.append(task) }
            else if due < tomorrowEnd { tomorrow.append(task) }
            else { later.append(task) }
        }
        let completed = showCompleted
            ? model.tasks.filter(\.completed).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            : []
        return [
            Section(id: "overdue", title: "Overdue", tasks: overdue),
            Section(id: "today", title: "Today", tasks: dueToday),
            Section(id: "tomorrow", title: "Tomorrow", tasks: tomorrow),
            Section(id: "later", title: "Upcoming", tasks: later),
            Section(id: "someday", title: "No date", tasks: someday),
            Section(id: "done", title: "Completed", tasks: completed),
        ]
    }
}
