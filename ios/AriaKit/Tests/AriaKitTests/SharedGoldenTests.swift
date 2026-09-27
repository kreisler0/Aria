import XCTest
@testable import AriaKit

/// The iOS and Windows apps must give the model the same tools and the same prompt. Both
/// test suites compare against the files in `shared/ai/` (regenerate them with
/// `ARIA_WRITE_GOLDEN=1 swift test --filter SharedGoldenTests`).
final class SharedGoldenTests: XCTestCase {
    private func goldenURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // → repository root
        return url.appendingPathComponent("shared/ai/\(name)")
    }

    private func check(_ actual: String, against name: String) throws {
        let url = goldenURL(name)
        if ProcessInfo.processInfo.environment["ARIA_WRITE_GOLDEN"] == "1" {
            try actual.write(to: url, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(actual, expected, "\(name) changed — update shared/ai and the Windows implementation together")
    }

    func testToolSchemaMatchesSharedDefinition() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.array(AriaTools.definitions))
        try check(String(decoding: data, as: UTF8.self) + "\n", against: "tools.json")
    }

    func testSystemPromptMatchesSharedGolden() throws {
        try check(AssistantPrompt.system(now: date("2026-09-27T13:41:00Z"), calendar: calendar(newYork), snapshot: Self.goldenSnapshot) + "\n",
                  against: "system-prompt.golden.txt")
    }

    static let goldenSnapshot = PlannerSnapshot(
        tasks: [
            TaskItem(id: uuid(1), title: "Finish essay", dueAt: date("2026-10-02T21:00:00Z"), priority: .high),
            TaskItem(id: uuid(2), title: "Buy milk"),
        ],
        events: [
            EventItem(id: uuid(4), title: "Holiday", startAt: date("2026-09-27T00:00:00Z"), endAt: date("2026-09-28T00:00:00Z"), allDay: true),
            EventItem(id: uuid(3), title: "Dentist", startAt: date("2026-09-27T14:00:00Z"), endAt: date("2026-09-27T15:00:00Z")),
        ])
}
