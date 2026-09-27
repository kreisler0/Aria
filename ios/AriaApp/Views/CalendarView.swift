import SwiftUI
import AriaKit

/// Month / week calendar with a day agenda and day notes (planner_days).
struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .month
    @State private var anchor = Date()
    @State private var selected = DayKey(Date(), calendar: .current)
    @State private var editingEvent: EventItem?
    @State private var editingTask: TaskItem?
    @State private var newEventDay: DayKey?
    @State private var newTaskDay: DayKey?

    enum Mode: String, CaseIterable, Identifiable {
        case month = "Month"
        case week = "Week"
        var id: String { rawValue }
    }

    private var calendar: Calendar { .current }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        GlassCard(padding: 14) {
                            VStack(spacing: 12) {
                                monthHeader
                                weekdayHeader
                                grid
                            }
                        }
                        agenda
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await model.refresh() }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode.animation(AriaTheme.spring)) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    AssistantToolbarButton()
                    Menu {
                        Button("New Event", systemImage: "calendar.badge.plus") { newEventDay = selected }
                        Button("New Task", systemImage: "checklist") { newTaskDay = selected }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task(id: visibleInterval) { await model.ensureEventsLoaded(for: visibleInterval) }
            .sheet(item: $editingEvent) { EventEditorView(event: $0) }
            .sheet(item: $editingTask) { TaskEditorView(task: $0) }
            .sheet(item: $newEventDay) { EventEditorView(day: $0) }
            .sheet(item: $newTaskDay) { day in
                TaskEditorView(defaultDue: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day.startDate(in: calendar)))
            }
        }
    }

    // MARK: Grid

    private var days: [Date] {
        switch mode {
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .month:
            guard let month = calendar.dateInterval(of: .month, for: anchor),
                  let gridStart = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start else { return [] }
            let lastDay = month.end.addingTimeInterval(-1)
            let gridEnd = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.end ?? month.end
            var result: [Date] = []
            var day = gridStart
            while day < gridEnd {
                result.append(day)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? gridEnd
            }
            return result
        }
    }

    private var visibleInterval: DateInterval {
        guard let first = days.first, let last = days.last else { return DateInterval(start: anchor, duration: 86_400) }
        return DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private var monthHeader: some View {
        HStack {
            Text(anchor.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            Spacer()
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous")
            Button("Today") {
                withAnimation(AriaTheme.spring) {
                    anchor = Date()
                    selected = DayKey(Date(), calendar: calendar)
                }
            }
            .font(.subheadline.weight(.medium))
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
    }

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let month = calendar.component(.month, from: anchor)
        let today = DayKey(Date(), calendar: calendar)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
            ForEach(days, id: \.self) { date in
                let key = DayKey(date, calendar: calendar)
                DayCell(day: calendar.component(.day, from: date),
                        isSelected: key == selected,
                        isToday: key == today,
                        isOutsideMonth: mode == .month && calendar.component(.month, from: date) != month,
                        hasEvents: !model.events(on: key).isEmpty,
                        hasTasks: !model.tasks(dueOn: key).filter { !$0.completed }.isEmpty)
                    .onTapGesture {
                        withAnimation(AriaTheme.spring) { selected = key }
                    }
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -50 { move(1) } else if value.translation.width > 50 { move(-1) }
        })
    }

    private func move(_ step: Int) {
        withAnimation(AriaTheme.spring) {
            anchor = calendar.date(byAdding: mode == .month ? .month : .weekOfYear, value: step, to: anchor) ?? anchor
        }
    }

    // MARK: Agenda

    private var agenda: some View {
        let dayEvents = model.events(on: selected)
        let dayTasks = model.tasks(dueOn: selected)
        return VStack(alignment: .leading, spacing: 12) {
            Text(selected.startDate(in: calendar).formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 4)
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    if dayEvents.isEmpty && dayTasks.isEmpty {
                        Text("Nothing planned.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(dayEvents) { event in
                        EventRow(event: event)
                            .onTapGesture { editingEvent = event }
                    }
                    if !dayEvents.isEmpty && !dayTasks.isEmpty { Divider() }
                    ForEach(dayTasks) { task in
                        TaskRow(task: task, showsDate: false)
                            .onTapGesture { editingTask = task }
                    }
                }
                .animation(AriaTheme.spring, value: dayEvents)
                .animation(AriaTheme.spring, value: dayTasks)
            }
            DayNotesCard(day: selected)
        }
    }
}

private struct DayCell: View {
    let day: Int
    let isSelected: Bool
    let isToday: Bool
    let isOutsideMonth: Bool
    let hasEvents: Bool
    let hasTasks: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text("\(day)")
                .font(.callout.weight(isToday ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.white : (isOutsideMonth ? Color.secondary.opacity(0.5) : (isToday ? Color.accentColor : Color.primary)))
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    } else if isToday {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
            HStack(spacing: 3) {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).opacity(hasEvents ? 1 : 0)
                Circle().fill(Color.orange).frame(width: 5, height: 5).opacity(hasTasks ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Free-form notes for a day, saved to `planner_days` a moment after typing stops.
private struct DayNotesCard: View {
    @Environment(AppModel.self) private var model
    let day: DayKey
    @State private var text = ""
    @State private var loadedDay: DayKey?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Notes", systemImage: "note.text")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Anything to remember for this day?", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .onChange(of: text) { _, newValue in
                        guard loadedDay == day else { return }
                        saveTask?.cancel()
                        let targetDay = day
                        saveTask = Task {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            guard !Task.isCancelled else { return }
                            await model.saveNotes(newValue, for: targetDay)
                        }
                    }
            }
        }
        .task(id: day) {
            loadedDay = nil
            text = await model.notes(for: day)
            loadedDay = day
        }
    }
}
