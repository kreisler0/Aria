import Foundation

/// The fields two-way calendar sync compares, normalized so the same event reads the same
/// on both sides (trimmed text, empty notes = nil, whole seconds, all-day as UTC days).
public struct SyncContent: Codable, Hashable, Sendable {
    public var title: String
    public var notes: String?
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool

    public init(title: String?, notes: String?, startAt: Date, endAt: Date, allDay: Bool) {
        self.title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes
        self.startAt = Date(timeIntervalSince1970: startAt.timeIntervalSince1970.rounded())
        self.endAt = Date(timeIntervalSince1970: max(endAt, startAt).timeIntervalSince1970.rounded())
        self.allDay = allDay
    }

    public init(_ row: EventItem) {
        self.init(title: row.title, notes: row.notes, startAt: row.startAt, endAt: row.endAt, allDay: row.allDay)
    }
}

/// A calendar event on the device (EventKit), reduced to what is synced.
public struct ExternalEvent: Hashable, Sendable {
    /// Stable identifier stored in `events.ios_calendar_event_id` (EventKit's
    /// `calendarItemExternalIdentifier`, which is the same on all of the user's devices).
    public var externalId: String
    public var content: SyncContent
    public var lastModified: Date?
    /// Events Aria must not write to (read-only calendars, recurring occurrences): they
    /// are mirrored into Supabase but changes only ever flow from the device.
    public var isReadOnly: Bool

    public init(externalId: String, content: SyncContent, lastModified: Date?, isReadOnly: Bool = false) {
        self.externalId = externalId
        self.content = content
        self.lastModified = lastModified
        self.isReadOnly = isReadOnly
    }
}

/// What both sides looked like the last time a row and a device event were in sync.
public struct SyncRecord: Codable, Hashable, Sendable {
    public var rowId: UUID
    public var externalId: String
    public var content: SyncContent
    /// The row was deleted in Aria but the device event is read-only: don't re-import it.
    public var suppressed: Bool

    public init(rowId: UUID, externalId: String, content: SyncContent, suppressed: Bool = false) {
        self.rowId = rowId
        self.externalId = externalId
        self.content = content
        self.suppressed = suppressed
    }
}

public enum SyncOperation: Hashable, Sendable {
    /// Create (upsert) a row for a device event.
    case importEvent(ExternalEvent)
    /// Device → Supabase.
    case updateRow(rowId: UUID, externalId: String, content: SyncContent)
    case deleteRow(rowId: UUID, externalId: String)
    /// Create a device event for a row, then store its identifier on the row.
    case exportEvent(EventItem)
    /// Supabase → device.
    case updateExternal(externalId: String, rowId: UUID, content: SyncContent)
    case deleteExternal(externalId: String, rowId: UUID)
    /// Bookkeeping only.
    case link(rowId: UUID, externalId: String, content: SyncContent)
    case suppress(rowId: UUID, externalId: String, content: SyncContent)
    case forget(rowId: UUID, externalId: String)
}

/// Two-way sync decisions between Supabase `events` rows and device calendar events,
/// as a pure function so it can be tested exhaustively.
///
/// A side counts as changed when its content differs from the content recorded at the
/// last sync; when both changed, the most recent write wins (`events.updated_at` vs the
/// event's `lastModifiedDate`). Deleting an item deletes its counterpart, unless the
/// counterpart was edited since — then the edit wins and the item is recreated.
public enum CalendarSyncPlanner {
    /// Record ids whose counterpart is missing from the fetched window. Look these up
    /// directly and pass them to `plan` so an item moved out of the window isn't mistaken
    /// for a deleted one.
    public static func missingCounterparts(rows: [EventItem], externals: [ExternalEvent],
                                           records: [SyncRecord]) -> (rowIds: [UUID], externalIds: [String]) {
        let rowIds = Set(rows.map(\.id))
        let externalIds = Set(externals.map(\.externalId))
        let missingRows = records.filter { !$0.suppressed && !rowIds.contains($0.rowId) }.map(\.rowId)
        let missingExternals = records.filter { !externalIds.contains($0.externalId) }.map(\.externalId)
        return (Array(Set(missingRows)).sorted { $0.uuidString < $1.uuidString }, Array(Set(missingExternals)).sorted())
    }

    /// Device events with no known row: look their rows up by calendar identifier before
    /// planning, so a row that moved outside the window is updated rather than duplicated.
    public static func unmatchedExternalIds(rows: [EventItem], externals: [ExternalEvent],
                                            records: [SyncRecord]) -> [String] {
        let linked = Set(rows.compactMap(\.iosCalendarEventId)).union(records.map(\.externalId))
        return externals.map(\.externalId).filter { !linked.contains($0) }
    }

    public static func plan(rows: [EventItem], externals: [ExternalEvent], records: [SyncRecord]) -> [SyncOperation] {
        let rowsById = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let externalsById = Dictionary(externals.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })
        var seenRows = Set<UUID>()
        var seenExternals = Set<String>()
        var operations: [SyncOperation] = []

        for record in records {
            guard !seenRows.contains(record.rowId), !seenExternals.contains(record.externalId) else {
                operations.append(.forget(rowId: record.rowId, externalId: record.externalId))
                continue
            }
            seenRows.insert(record.rowId)
            seenExternals.insert(record.externalId)
            let row = rowsById[record.rowId]
            let external = externalsById[record.externalId]

            if record.suppressed {
                if external == nil {
                    operations.append(.forget(rowId: record.rowId, externalId: record.externalId))
                } else if let row {
                    // The row exists again (e.g. restored): resume normal syncing.
                    operations.append(contentsOf: reconcile(row: row, external: external!, base: nil))
                }
                continue
            }

            switch (row, external) {
            case (nil, nil):
                operations.append(.forget(rowId: record.rowId, externalId: record.externalId))
            case let (row?, nil):
                // Deleted on the device.
                if SyncContent(row) != record.content {
                    operations.append(.exportEvent(row)) // edited in Aria since: the edit wins
                } else {
                    operations.append(.deleteRow(rowId: row.id, externalId: record.externalId))
                }
            case let (nil, external?):
                // Deleted in Aria (app, AI or Windows).
                if external.isReadOnly {
                    operations.append(.suppress(rowId: record.rowId, externalId: external.externalId, content: external.content))
                } else if external.content != record.content {
                    operations.append(.importEvent(external)) // edited on the device since: the edit wins
                } else {
                    operations.append(.deleteExternal(externalId: external.externalId, rowId: record.rowId))
                }
            case let (row?, external?):
                operations.append(contentsOf: reconcile(row: row, external: external, base: record.content))
            }
        }

        for row in rows where !seenRows.contains(row.id) {
            seenRows.insert(row.id)
            if let externalId = row.iosCalendarEventId {
                if let external = externalsById[externalId], !seenExternals.contains(externalId) {
                    // Known to Supabase but new to this device (reinstall, second device).
                    seenExternals.insert(externalId)
                    operations.append(contentsOf: reconcile(row: row, external: external, base: nil))
                }
                // Otherwise the event lives in a calendar this device doesn't have: leave it.
            } else {
                operations.append(.exportEvent(row))
            }
        }

        for external in externals where !seenExternals.contains(external.externalId) {
            seenExternals.insert(external.externalId)
            operations.append(.importEvent(external))
        }
        return operations
    }

    private static func reconcile(row: EventItem, external: ExternalEvent, base: SyncContent?) -> [SyncOperation] {
        let rowContent = SyncContent(row)
        let externalContent = external.content
        if rowContent == externalContent {
            return base == rowContent ? [] : [.link(rowId: row.id, externalId: external.externalId, content: rowContent)]
        }
        let pushToRow = SyncOperation.updateRow(rowId: row.id, externalId: external.externalId, content: externalContent)
        let pushToDevice = SyncOperation.updateExternal(externalId: external.externalId, rowId: row.id, content: rowContent)
        if external.isReadOnly { return [pushToRow] }
        let rowChanged = base.map { $0 != rowContent } ?? true
        let externalChanged = base.map { $0 != externalContent } ?? true
        if rowChanged && !externalChanged { return [pushToDevice] }
        if externalChanged && !rowChanged { return [pushToRow] }
        // Both changed: last write wins.
        let rowTime = row.updatedAt ?? .distantPast
        let externalTime = external.lastModified ?? .distantPast
        return externalTime > rowTime ? [pushToRow] : [pushToDevice]
    }
}

/// The persisted set of `SyncRecord`s, kept consistent (one record per row and per
/// device event).
public struct SyncRecordBook: Hashable, Sendable {
    public private(set) var records: [SyncRecord]

    public init(_ records: [SyncRecord] = []) {
        self.records = records
    }

    public mutating func link(rowId: UUID, externalId: String, content: SyncContent) {
        records.removeAll { $0.rowId == rowId || $0.externalId == externalId }
        records.append(SyncRecord(rowId: rowId, externalId: externalId, content: content))
    }

    public mutating func suppress(rowId: UUID, externalId: String, content: SyncContent) {
        records.removeAll { $0.rowId == rowId || $0.externalId == externalId }
        records.append(SyncRecord(rowId: rowId, externalId: externalId, content: content, suppressed: true))
    }

    public mutating func forget(rowId: UUID? = nil, externalId: String? = nil) {
        records.removeAll { record in
            (rowId != nil && record.rowId == rowId) || (externalId != nil && record.externalId == externalId)
        }
    }
}
