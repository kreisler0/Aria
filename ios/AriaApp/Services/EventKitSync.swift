import EventKit
import Foundation
import AriaKit

/// A calendar the user can include in or exclude from syncing.
struct CalendarOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    let isWritable: Bool
    let isDefault: Bool
}

/// Two-way sync between Supabase `events` and the iOS Calendar (spec §4.3).
///
/// Device events are identified by `calendarItemExternalIdentifier` (the same on all of
/// the user's devices), stored in `events.ios_calendar_event_id`. The decisions — what
/// to import, export, update or delete, with last-write-wins on conflicts — come from
/// `CalendarSyncPlanner` in AriaKit; this type only talks to EventKit and Supabase.
actor EventKitSync {
    struct Report: Sendable {
        var imported = 0
        var exported = 0
        var updatedRows = 0
        var updatedEvents = 0
        var deletedRows = 0
        var deletedEvents = 0
        var failures = 0

        var changedRows: Bool { imported + updatedRows + deletedRows > 0 }

        var summary: String {
            let parts = [
                imported > 0 ? "\(imported) imported" : nil,
                exported > 0 ? "\(exported) added to Calendar" : nil,
                updatedRows + updatedEvents > 0 ? "\(updatedRows + updatedEvents) updated" : nil,
                deletedRows + deletedEvents > 0 ? "\(deletedRows + deletedEvents) removed" : nil,
                failures > 0 ? "\(failures) failed" : nil,
            ].compactMap { $0 }
            return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
        }
    }

    private let eventStore = EKEventStore()

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func calendarOptions() -> [CalendarOption] {
        let defaultId = eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        return eventStore.calendars(for: .event)
            .filter { $0.type != .birthday }
            .map { CalendarOption(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "",
                                  isWritable: $0.allowsContentModifications, isDefault: $0.calendarIdentifier == defaultId) }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func sync(client: SupabaseClient, userId: UUID, shared: SharedStore) async throws -> Report {
        guard Self.isAuthorized else {
            throw AriaError.invalidInput("Aria doesn't have access to your calendars. Allow it in Settings ▸ Privacy & Security ▸ Calendars.")
        }
        let calendar = Calendar.current
        let today = DayKey(Date(), calendar: calendar)
        let windowStart = today.adding(days: -30).startDate(in: calendar)
        let windowEnd = today.adding(days: 180).startDate(in: calendar)
        let excluded = shared.calendarSyncExcluded
        let calendars = eventStore.calendars(for: .event).filter { $0.type != .birthday && !excluded.contains($0.calendarIdentifier) }
        let syncedCalendarIds = Set(calendars.map(\.calendarIdentifier))
        var book = SyncRecordBook(shared.syncRecords(for: userId))

        // Device side.
        var deviceEvents: [String: EKEvent] = [:]
        var externals: [ExternalEvent] = []
        if !calendars.isEmpty {
            let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)
            for event in eventStore.events(matching: predicate) {
                guard let external = externalEvent(from: event, calendar: calendar), deviceEvents[external.externalId] == nil else { continue }
                deviceEvents[external.externalId] = event
                externals.append(external)
            }
        }

        // Supabase side.
        var rows = try await client.fetchEventRows(from: windowStart, to: windowEnd)

        // Look up counterparts that moved outside the window before deciding anything.
        let missing = CalendarSyncPlanner.missingCounterparts(rows: rows, externals: externals, records: book.records)
        if !missing.rowIds.isEmpty {
            rows += try await client.fetchEvents(ids: missing.rowIds)
        }
        for recordedId in missing.externalIds {
            guard let event = findEvent(recordedId), let external = externalEvent(from: event, calendar: calendar) else { continue }
            guard let eventCalendar = event.calendar, syncedCalendarIds.contains(eventCalendar.calendarIdentifier) else {
                // Its calendar was switched off: stop syncing it, keep the row.
                book.forget(externalId: recordedId)
                continue
            }
            if external.externalId != recordedId, let record = book.records.first(where: { $0.externalId == recordedId }) {
                // The identifier changed (e.g. the event got its server id): re-key.
                book.link(rowId: record.rowId, externalId: external.externalId, content: record.content)
                _ = try? await client.updateEvent(id: record.rowId, EventUpdate(iosCalendarEventId: .some(external.externalId)))
            }
            if deviceEvents[external.externalId] == nil {
                deviceEvents[external.externalId] = event
                externals.append(external)
            }
        }
        let unmatched = CalendarSyncPlanner.unmatchedExternalIds(rows: rows, externals: externals, records: book.records)
        if !unmatched.isEmpty {
            rows += try await client.fetchEventRows(calendarIds: unmatched)
        }
        var seen = Set<UUID>()
        rows = rows.filter { seen.insert($0.id).inserted }

        var report = Report()
        for operation in CalendarSyncPlanner.plan(rows: rows, externals: externals, records: book.records) {
            do {
                try await execute(operation, client: client, userId: userId, shared: shared, deviceEvents: deviceEvents,
                                  calendar: calendar, book: &book, report: &report)
            } catch {
                report.failures += 1
            }
        }
        shared.saveSyncRecords(book.records, for: userId)
        return report
    }

    // MARK: Operations

    private func execute(_ operation: SyncOperation, client: SupabaseClient, userId: UUID, shared: SharedStore,
                         deviceEvents: [String: EKEvent], calendar: Calendar, book: inout SyncRecordBook,
                         report: inout Report) async throws {
        switch operation {
        case .importEvent(let external):
            let content = external.content
            let row = try await client.upsertEventByCalendarId(NewEvent(
                id: nil, userId: userId, title: content.title, notes: content.notes, startAt: content.startAt,
                endAt: content.endAt, allDay: content.allDay, iosCalendarEventId: external.externalId, source: .user))
            book.link(rowId: row.id, externalId: external.externalId, content: content)
            report.imported += 1

        case let .updateRow(rowId, externalId, content):
            _ = try await client.updateEvent(id: rowId, EventUpdate(title: content.title, notes: .some(content.notes),
                                                                    startAt: content.startAt, endAt: content.endAt,
                                                                    allDay: content.allDay))
            book.link(rowId: rowId, externalId: externalId, content: content)
            report.updatedRows += 1

        case let .deleteRow(rowId, externalId):
            _ = try await client.deleteEvent(id: rowId)
            book.forget(rowId: rowId, externalId: externalId)
            report.deletedRows += 1

        case .exportEvent(let row):
            guard let target = targetCalendar(shared) else { return }
            let event = EKEvent(eventStore: eventStore)
            event.calendar = target
            apply(SyncContent(row), to: event, calendar: calendar)
            try eventStore.save(event, span: .thisEvent, commit: true)
            guard let externalId = identifier(of: event) else { return }
            _ = try await client.updateEvent(id: row.id, EventUpdate(iosCalendarEventId: .some(externalId)))
            book.link(rowId: row.id, externalId: externalId, content: SyncContent(row))
            report.exported += 1

        case let .updateExternal(externalId, rowId, content):
            guard let event = deviceEvents[externalId] ?? findEvent(externalId) else { return }
            apply(content, to: event, calendar: calendar)
            try eventStore.save(event, span: .thisEvent, commit: true)
            book.link(rowId: rowId, externalId: externalId, content: content)
            report.updatedEvents += 1

        case let .deleteExternal(externalId, rowId):
            if let event = deviceEvents[externalId] ?? findEvent(externalId) {
                try eventStore.remove(event, span: .thisEvent, commit: true)
            }
            book.forget(rowId: rowId, externalId: externalId)
            report.deletedEvents += 1

        case let .link(rowId, externalId, content):
            book.link(rowId: rowId, externalId: externalId, content: content)

        case let .suppress(rowId, externalId, content):
            book.suppress(rowId: rowId, externalId: externalId, content: content)

        case let .forget(rowId, externalId):
            book.forget(rowId: rowId, externalId: externalId)
        }
    }

    // MARK: EventKit mapping

    private func isRecurring(_ event: EKEvent) -> Bool {
        event.hasRecurrenceRules || event.isDetached
    }

    private func identifier(of event: EKEvent) -> String? {
        let external: String? = event.calendarItemExternalIdentifier
        let local: String? = event.eventIdentifier
        guard let base = (external?.isEmpty == false ? external : nil) ?? local else { return nil }
        if isRecurring(event) {
            let occurrence: Date? = event.occurrenceDate
            return "\(base)@\(AriaDate.formatUTC(occurrence ?? event.startDate))"
        }
        return base
    }

    private func externalEvent(from event: EKEvent, calendar: Calendar) -> ExternalEvent? {
        guard let id = identifier(of: event), let start = event.startDate, let end = event.endDate else { return nil }
        let range = event.isAllDay ? AllDayRange.stored(start: start, end: end, calendar: calendar) : (start: start, end: end)
        let content = SyncContent(title: event.title, notes: event.notes, startAt: range.start, endAt: range.end,
                                  allDay: event.isAllDay)
        let writable = event.calendar?.allowsContentModifications ?? false
        // Recurring series are mirrored one way: writing one occurrence back is too easy to get wrong.
        return ExternalEvent(externalId: id, content: content, lastModified: event.lastModifiedDate,
                             isReadOnly: !writable || isRecurring(event))
    }

    private func apply(_ content: SyncContent, to event: EKEvent, calendar: Calendar) {
        event.title = content.title
        event.notes = content.notes
        if content.allDay {
            let first = DayKey(utc: content.startAt)
            let last = max(first, DayKey(utc: content.endAt.addingTimeInterval(-1)))
            event.isAllDay = true
            event.startDate = first.startDate(in: calendar)
            // EventKit represents all-day events as ending at 23:59:59 on their last day.
            event.endDate = last.adding(days: 1).startDate(in: calendar).addingTimeInterval(-1)
        } else {
            event.isAllDay = false
            event.startDate = content.startAt
            event.endDate = content.endAt
        }
    }

    private func findEvent(_ externalId: String) -> EKEvent? {
        let parts = externalId.split(separator: "@", maxSplits: 1).map(String.init)
        let base = parts.first ?? externalId
        if parts.count == 2, let occurrence = AriaDate.parseTimestamp(parts[1]) {
            // A recurring occurrence: search around its original date.
            let predicate = eventStore.predicateForEvents(withStart: occurrence.addingTimeInterval(-86_400),
                                                          end: occurrence.addingTimeInterval(86_400), calendars: nil)
            return eventStore.events(matching: predicate).first { identifier(of: $0) == externalId }
        }
        let matches = eventStore.calendarItems(withExternalIdentifier: base).compactMap { $0 as? EKEvent }
        if let match = matches.first(where: { !isRecurring($0) }) ?? matches.first {
            return match
        }
        return eventStore.event(withIdentifier: base)
    }

    private func targetCalendar(_ shared: SharedStore) -> EKCalendar? {
        if let id = shared.calendarSyncTarget, let chosen = eventStore.calendar(withIdentifier: id), chosen.allowsContentModifications {
            return chosen
        }
        return eventStore.defaultCalendarForNewEvents
    }
}
