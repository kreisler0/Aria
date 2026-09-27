import XCTest
@testable import AriaKit

/// Simulates Supabase rows and a device calendar, applying the planner's operations the
/// same way `EventKitSync` does in the app.
struct SyncWorld {
    var rows: [UUID: EventItem] = [:]
    var device: [String: ExternalEvent] = [:]
    var book = SyncRecordBook()
    var clock = date("2026-09-27T12:00:00Z")
    var nextExternal = 1

    mutating func tick() -> Date {
        clock = clock.addingTimeInterval(60)
        return clock
    }

    func content(_ title: String, hour: Int, allDay: Bool = false) -> SyncContent {
        let start = date("2026-10-01T00:00:00Z").addingTimeInterval(Double(hour) * 3600)
        return SyncContent(title: title, notes: nil, startAt: start, endAt: start.addingTimeInterval(allDay ? 86_400 : 3600), allDay: allDay)
    }

    @discardableResult
    mutating func addRow(_ title: String, hour: Int, calendarId: String? = nil) -> UUID {
        let id = UUID()
        let c = content(title, hour: hour)
        let now = tick()
        rows[id] = EventItem(id: id, title: c.title, startAt: c.startAt, endAt: c.endAt, iosCalendarEventId: calendarId,
                             source: .ai, updatedAt: now)
        return id
    }

    @discardableResult
    mutating func addDeviceEvent(_ title: String, hour: Int, readOnly: Bool = false, id: String? = nil) -> String {
        let externalId = id ?? "EK-\(nextExternal)"
        if id == nil { nextExternal += 1 }
        let now = tick()
        device[externalId] = ExternalEvent(externalId: externalId, content: content(title, hour: hour), lastModified: now,
                                           isReadOnly: readOnly)
        return externalId
    }

    mutating func editRow(_ id: UUID, title: String) {
        let now = tick()
        rows[id]?.title = title
        rows[id]?.updatedAt = now
    }

    mutating func editDevice(_ id: String, title: String) {
        let now = tick()
        device[id]?.content.title = title
        device[id]?.lastModified = now
    }

    @discardableResult
    mutating func sync() -> [SyncOperation] {
        let operations = CalendarSyncPlanner.plan(rows: rows.values.sorted { $0.id.uuidString < $1.id.uuidString },
                                                  externals: device.values.sorted { $0.externalId < $1.externalId },
                                                  records: book.records)
        for operation in operations { apply(operation) }
        return operations
    }

    mutating func apply(_ operation: SyncOperation) {
        switch operation {
        case .importEvent(let external):
            let existing = rows.values.first { $0.iosCalendarEventId == external.externalId }
            let id = existing?.id ?? UUID()
            let now = tick()
            rows[id] = EventItem(id: id, title: external.content.title, notes: external.content.notes, startAt: external.content.startAt,
                                 endAt: external.content.endAt, allDay: external.content.allDay, iosCalendarEventId: external.externalId,
                                 source: existing?.source ?? .user, updatedAt: now)
            book.link(rowId: id, externalId: external.externalId, content: external.content)
        case let .updateRow(rowId, externalId, content):
            guard var row = rows[rowId] else { return XCTFail("updateRow on missing row") }
            row.title = content.title
            row.notes = content.notes
            row.startAt = content.startAt
            row.endAt = content.endAt
            row.allDay = content.allDay
            row.updatedAt = tick()
            rows[rowId] = row
            book.link(rowId: rowId, externalId: externalId, content: content)
        case let .deleteRow(rowId, externalId):
            rows[rowId] = nil
            book.forget(rowId: rowId, externalId: externalId)
        case .exportEvent(let row):
            let externalId = "EK-\(nextExternal)"
            nextExternal += 1
            let created = tick()
            device[externalId] = ExternalEvent(externalId: externalId, content: SyncContent(row), lastModified: created)
            let linked = tick()
            rows[row.id]?.iosCalendarEventId = externalId
            rows[row.id]?.updatedAt = linked
            book.link(rowId: row.id, externalId: externalId, content: SyncContent(row))
        case let .updateExternal(externalId, rowId, content):
            guard device[externalId] != nil else { return XCTFail("updateExternal on missing event") }
            let now = tick()
            device[externalId]?.content = content
            device[externalId]?.lastModified = now
            book.link(rowId: rowId, externalId: externalId, content: content)
        case let .deleteExternal(externalId, rowId):
            device[externalId] = nil
            book.forget(rowId: rowId, externalId: externalId)
        case let .link(rowId, externalId, content):
            book.link(rowId: rowId, externalId: externalId, content: content)
        case let .suppress(rowId, externalId, content):
            book.suppress(rowId: rowId, externalId: externalId, content: content)
        case let .forget(rowId, externalId):
            book.forget(rowId: rowId, externalId: externalId)
        }
    }

    /// Every live record joins two items with identical content.
    func assertConverged(file: StaticString = #filePath, line: UInt = #line) {
        for record in book.records where !record.suppressed {
            guard let row = rows[record.rowId], let external = device[record.externalId] else {
                XCTFail("dangling record \(record)", file: file, line: line)
                continue
            }
            XCTAssertEqual(SyncContent(row), external.content, file: file, line: line)
            XCTAssertEqual(row.iosCalendarEventId, record.externalId, file: file, line: line)
        }
    }
}

final class CalendarSyncPlannerTests: XCTestCase {
    func testInitialImportThenIdempotent() {
        var world = SyncWorld()
        world.addDeviceEvent("Dentist", hour: 9)
        world.addDeviceEvent("Gym", hour: 18)
        let first = world.sync()
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy { if case .importEvent = $0 { return true } else { return false } })
        XCTAssertEqual(Set(world.rows.values.map(\.title)), ["Dentist", "Gym"])
        XCTAssertEqual(world.sync(), [], "second pass must be a no-op")
        world.assertConverged()
    }

    func testAIEventsArePushedToTheDevice() {
        var world = SyncWorld()
        let id = world.addRow("Study block", hour: 18)
        let operations = world.sync()
        XCTAssertEqual(operations.count, 1)
        guard case .exportEvent(let row) = operations[0] else { return XCTFail("expected export") }
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(world.device.values.map(\.content.title), ["Study block"])
        XCTAssertNotNil(world.rows[id]?.iosCalendarEventId)
        XCTAssertEqual(world.sync(), [])
        world.assertConverged()
    }

    func testEditsFlowInBothDirections() {
        var world = SyncWorld()
        let externalId = world.addDeviceEvent("Dentist", hour: 9)
        world.sync()
        let rowId = world.rows.values.first!.id

        world.editRow(rowId, title: "Dentist (moved by AI)")
        XCTAssertEqual(world.sync(), [.updateExternal(externalId: externalId, rowId: rowId, content: SyncContent(world.rows[rowId]!))])
        XCTAssertEqual(world.device[externalId]?.content.title, "Dentist (moved by AI)")

        world.editDevice(externalId, title: "Dentist — Dr. Lee")
        XCTAssertEqual(world.sync(), [.updateRow(rowId: rowId, externalId: externalId, content: world.device[externalId]!.content)])
        XCTAssertEqual(world.rows[rowId]?.title, "Dentist — Dr. Lee")
        XCTAssertEqual(world.sync(), [])
        world.assertConverged()
    }

    func testConcurrentEditsResolveLastWriteWins() {
        var world = SyncWorld()
        let externalId = world.addDeviceEvent("Standup", hour: 9)
        world.sync()
        let rowId = world.rows.values.first!.id

        world.editRow(rowId, title: "Standup (Aria)")
        world.editDevice(externalId, title: "Standup (Calendar)") // later → wins
        world.sync()
        XCTAssertEqual(world.rows[rowId]?.title, "Standup (Calendar)")

        world.editDevice(externalId, title: "Standup (Calendar 2)")
        world.editRow(rowId, title: "Standup (Aria 2)") // later → wins
        world.sync()
        XCTAssertEqual(world.device[externalId]?.content.title, "Standup (Aria 2)")
        XCTAssertEqual(world.sync(), [])
        world.assertConverged()
    }

    func testDeletionsPropagate() {
        var world = SyncWorld()
        let deviceOnly = world.addDeviceEvent("Coffee", hour: 8)
        world.addRow("Lunch", hour: 12)
        world.sync()
        let coffeeRow = world.rows.values.first { $0.title == "Coffee" }!.id
        let lunch = world.rows.values.first { $0.title == "Lunch" }!

        world.device[deviceOnly] = nil // deleted in the Calendar app
        XCTAssertEqual(world.sync(), [.deleteRow(rowId: coffeeRow, externalId: deviceOnly)])
        XCTAssertNil(world.rows[coffeeRow])

        world.rows[lunch.id] = nil // deleted by the AI / Windows app
        XCTAssertEqual(world.sync(), [.deleteExternal(externalId: lunch.iosCalendarEventId!, rowId: lunch.id)])
        XCTAssertTrue(world.device.isEmpty)
        XCTAssertEqual(world.book.records, [])
        XCTAssertEqual(world.sync(), [])
    }

    func testEditWinsOverDeleteOnTheOtherSide() {
        var world = SyncWorld()
        let externalId = world.addDeviceEvent("Review", hour: 15)
        world.sync()
        let rowId = world.rows.values.first!.id

        // Deleted on the device, but edited in Aria before the sync: recreate on the device.
        world.device[externalId] = nil
        world.editRow(rowId, title: "Review (updated)")
        let operations = world.sync()
        guard case .exportEvent(let row)? = operations.first else { return XCTFail("expected export, got \(operations)") }
        XCTAssertEqual(row.title, "Review (updated)")
        XCTAssertEqual(world.device.values.map(\.content.title), ["Review (updated)"])
        XCTAssertEqual(world.sync(), [])

        // Deleted in Aria, but edited on the device: re-import.
        let newExternal = world.rows[rowId]!.iosCalendarEventId!
        world.rows[rowId] = nil
        world.editDevice(newExternal, title: "Review (device)")
        let second = world.sync()
        guard case .importEvent(let external)? = second.first else { return XCTFail("expected import, got \(second)") }
        XCTAssertEqual(external.content.title, "Review (device)")
        XCTAssertEqual(world.rows.values.map(\.title), ["Review (device)"])
        XCTAssertEqual(world.sync(), [])
        world.assertConverged()
    }

    func testReadOnlyEventsAreMirroredOneWay() {
        var world = SyncWorld()
        let holiday = world.addDeviceEvent("Public holiday", hour: 0, readOnly: true)
        world.sync()
        let rowId = world.rows.values.first!.id

        // Edits made in Aria to a read-only event are reverted from the device.
        world.editRow(rowId, title: "Renamed")
        XCTAssertEqual(world.sync(), [.updateRow(rowId: rowId, externalId: holiday, content: world.device[holiday]!.content)])

        // Deleting it in Aria hides it without touching the calendar, and it stays hidden.
        world.rows[rowId] = nil
        let operations = world.sync()
        XCTAssertEqual(operations, [.suppress(rowId: rowId, externalId: holiday, content: world.device[holiday]!.content)])
        XCTAssertNotNil(world.device[holiday])
        XCTAssertEqual(world.sync(), [])
        XCTAssertTrue(world.rows.isEmpty)

        // Once the calendar drops it too, the bookkeeping is cleaned up.
        world.device[holiday] = nil
        XCTAssertEqual(world.sync(), [.forget(rowId: rowId, externalId: holiday)])
        XCTAssertEqual(world.book.records, [])
    }

    func testSecondDeviceLinksInsteadOfDuplicating() {
        var world = SyncWorld()
        // Device A already imported EK-7; this device has the same event (same external id) but no records.
        let rowId = world.addRow("Dentist", hour: 9, calendarId: "EK-7")
        world.addDeviceEvent("Dentist", hour: 9, id: "EK-7")
        XCTAssertEqual(world.sync(), [.link(rowId: rowId, externalId: "EK-7", content: SyncContent(world.rows[rowId]!))])
        XCTAssertEqual(world.rows.count, 1)
        XCTAssertEqual(world.device.count, 1)

        // A row linked to an event this device doesn't have is left alone.
        world.addRow("Work calendar thing", hour: 11, calendarId: "EK-OTHER")
        XCTAssertEqual(world.sync(), [])
    }

    func testFirstPairingWithDifferencesUsesLastWriteWins() {
        var world = SyncWorld()
        world.addDeviceEvent("Old title", hour: 9, id: "EK-9")
        let rowId = world.addRow("New title", hour: 9, calendarId: "EK-9") // written later
        world.sync()
        XCTAssertEqual(world.device["EK-9"]?.content.title, "New title")
        XCTAssertEqual(world.rows[rowId]?.title, "New title")
        world.assertConverged()
    }

    func testDuplicateAndOrphanRecordsAreCleanedUp() {
        let c = SyncContent(title: "x", notes: nil, startAt: date("2026-10-01T09:00:00Z"), endAt: date("2026-10-01T10:00:00Z"), allDay: false)
        let operations = CalendarSyncPlanner.plan(rows: [], externals: [], records: [
            SyncRecord(rowId: uuid(1), externalId: "A", content: c),
            SyncRecord(rowId: uuid(1), externalId: "B", content: c),
        ])
        XCTAssertEqual(operations, [.forget(rowId: uuid(1), externalId: "A"), .forget(rowId: uuid(1), externalId: "B")])
    }

    func testLookupHelpers() {
        let c = SyncContent(title: "x", notes: nil, startAt: date("2026-10-01T09:00:00Z"), endAt: date("2026-10-01T10:00:00Z"), allDay: false)
        let row = EventItem(id: uuid(1), title: "x", startAt: c.startAt, endAt: c.endAt, iosCalendarEventId: "A")
        let records = [SyncRecord(rowId: uuid(1), externalId: "A", content: c), SyncRecord(rowId: uuid(2), externalId: "B", content: c)]
        let externals = [ExternalEvent(externalId: "B", content: c, lastModified: nil), ExternalEvent(externalId: "C", content: c, lastModified: nil)]
        let missing = CalendarSyncPlanner.missingCounterparts(rows: [row], externals: externals, records: records)
        XCTAssertEqual(missing.rowIds, [uuid(2)])
        XCTAssertEqual(missing.externalIds, ["A"])
        XCTAssertEqual(CalendarSyncPlanner.unmatchedExternalIds(rows: [row], externals: externals, records: records), ["C"])
    }

    func testSyncContentNormalization() {
        let a = SyncContent(title: "  Lunch ", notes: "  ", startAt: Date(timeIntervalSince1970: 100.4), endAt: Date(timeIntervalSince1970: 50),
                            allDay: false)
        XCTAssertEqual(a.title, "Lunch")
        XCTAssertNil(a.notes)
        XCTAssertEqual(a.startAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(a.endAt, a.startAt, "an end before the start is clamped")
        XCTAssertEqual(SyncContent(title: nil, notes: nil, startAt: a.startAt, endAt: a.endAt, allDay: false).title, "")
    }

    /// Random edits on both sides, syncing in between: the two sides must always converge
    /// and a repeated sync must never do anything.
    func testRandomizedConvergence() {
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var world = SyncWorld()
        for step in 0..<400 {
            switch next(8) {
            case 0: world.addRow("row \(step)", hour: next(48))
            case 1: world.addDeviceEvent("device \(step)", hour: next(48), readOnly: next(5) == 0)
            case 2: if let id = world.rows.keys.sorted(by: { $0.uuidString < $1.uuidString }).randomElement(using: next) {
                world.editRow(id, title: "row edit \(step)")
            }
            case 3: if let id = world.device.keys.sorted().randomElement(using: next) {
                world.editDevice(id, title: "device edit \(step)")
            }
            case 4: if let id = world.rows.keys.sorted(by: { $0.uuidString < $1.uuidString }).randomElement(using: next) {
                world.rows[id] = nil
            }
            case 5: if let id = world.device.keys.sorted().randomElement(using: next) { world.device[id] = nil }
            default:
                world.sync()
                world.assertConverged()
                XCTAssertEqual(world.sync(), [], "step \(step): sync must be idempotent")
            }
        }
        world.sync()
        world.assertConverged()
        XCTAssertEqual(world.sync(), [])
        // Every non-suppressed device event has exactly one row and vice versa.
        let linkedRows = world.rows.values.filter { $0.iosCalendarEventId != nil }
        XCTAssertEqual(linkedRows.count, world.rows.count)
        XCTAssertEqual(Set(linkedRows.compactMap(\.iosCalendarEventId)).count, linkedRows.count)
    }
}

private extension Array {
    func randomElement(using next: (Int) -> Int) -> Element? {
        isEmpty ? nil : self[next(count)]
    }
}
