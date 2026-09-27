import SwiftUI
import AriaKit

/// Create or edit a task.
struct TaskEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let task: TaskItem?
    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var dueAt: Date
    @State private var priority: TaskPriority
    @FocusState private var titleFocused: Bool

    init(task: TaskItem? = nil, defaultDue: Date? = nil) {
        self.task = task
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        let due = task?.dueAt ?? defaultDue
        _hasDueDate = State(initialValue: due != nil)
        _dueAt = State(initialValue: due ?? Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0),
                                                                       matchingPolicy: .nextTime) ?? Date())
        _priority = State(initialValue: task?.priority ?? .none)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .focused($titleFocused)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    Toggle("Due date", isOn: $hasDueDate.animation(AriaTheme.spring))
                    if hasDueDate {
                        DatePicker("Due", selection: $dueAt)
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(TaskPriority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                }
                if let task {
                    Section {
                        Button("Delete Task", role: .destructive) {
                            Task { await model.deleteTask(task) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(task == nil ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(task == nil ? "Add" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if task == nil { titleFocused = true } }
        }
    }

    private func save() {
        let due: Date? = hasDueDate ? dueAt : nil
        if let task {
            var update = TaskUpdate()
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != task.title { update.title = trimmed }
            if notes.nilIfBlank != task.notes { update.notes = .some(notes.nilIfBlank) }
            if due != task.dueAt { update.dueAt = .some(due) }
            if priority != task.priority { update.priority = priority }
            Task { await model.updateTask(task, update) }
        } else {
            Task { await model.addTask(title: title, notes: notes, dueAt: due, priority: priority) }
        }
        dismiss()
    }
}

/// Create or edit a calendar event.
struct EventEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let event: EventItem?
    @State private var title: String
    @State private var notes: String
    @State private var allDay: Bool
    @State private var start: Date
    @State private var end: Date
    @FocusState private var titleFocused: Bool

    init(event: EventItem? = nil, day: DayKey? = nil) {
        self.event = event
        let calendar = Calendar.current
        _title = State(initialValue: event?.title ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        _allDay = State(initialValue: event?.allDay ?? false)
        if let event {
            _start = State(initialValue: event.displayStart(in: calendar))
            let end = event.displayEnd(in: calendar)
            _end = State(initialValue: event.allDay ? end.addingTimeInterval(-1) : end)
        } else {
            let now = Date()
            var start = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            if let day, !calendar.isDate(start, inSameDayAs: day.startDate(in: calendar)) {
                start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day.startDate(in: calendar)) ?? start
            }
            _start = State(initialValue: start)
            _end = State(initialValue: start.addingTimeInterval(3600))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($titleFocused)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    Toggle("All-day", isOn: $allDay.animation(AriaTheme.spring))
                    DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                }
                if let event {
                    Section {
                        Button("Delete Event", role: .destructive) {
                            Task { await model.deleteEvent(event) }
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: start) { oldValue, newValue in
                // Keep the duration when the start moves.
                end = newValue.addingTimeInterval(max(0, end.timeIntervalSince(oldValue)))
            }
            .navigationTitle(event == nil ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(event == nil ? "Add" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if event == nil { titleFocused = true } }
        }
    }

    private func save() {
        let calendar = Calendar.current
        let endDate = allDay
            ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end)
            : end
        let startDate = allDay ? calendar.startOfDay(for: start) : start
        if let event {
            Task { await model.updateEvent(event, title: title, notes: notes, start: startDate, end: endDate, allDay: allDay) }
        } else {
            Task { await model.addEvent(title: title, notes: notes, start: startDate, end: endDate, allDay: allDay) }
        }
        dismiss()
    }
}
