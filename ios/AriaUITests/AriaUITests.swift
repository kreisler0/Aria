import UIKit
import XCTest

/// Runs the real app in the simulator; CI runs it on an iPhone and on an iPad. With
/// `-AriaUITestPreview` the app signs in to a day of sample data and no backend (see
/// `UITestPreview` in the app), so every screen can be exercised without a Supabase
/// project or an OpenRouter key. Each test launches the app fresh, so a failure points at
/// one screen.
final class AriaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchAsksForABackend() {
        let app = launch(["-AriaUITest"])
        XCTAssertTrue(app.staticTexts["Connect your backend"].waitForExistence(timeout: 20))
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "Connect needs a URL and a key first")
    }

    /// Today: the greeting and what's next; ticking a task takes it off the list; Quick Add
    /// (through the Quick Add widget's link) creates a task.
    @MainActor
    func testTodayTickAndQuickAdd() {
        let (app, ui) = launchPreview()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ", Ada")).firstMatch.exists,
                      "Today greets the user by name")
        XCTAssertTrue(app.staticTexts["Aria self-test day"].exists)
        XCTAssertTrue(app.staticTexts["Pay rent"].exists)
        app.buttons["complete Pay rent"].tap()
        XCTAssertTrue(ui.disappears(app.staticTexts["Pay rent"]), "a completed task leaves Today")

        ui.openLink("aria://quick-add")
        XCTAssertTrue(app.staticTexts["Quick Add"].waitForExistence(timeout: 10))
        let field = ui.textInput("Add a task, or ask Aria…")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Buy milk") // words autocorrect leaves alone
        app.buttons["Add Task"].tap()
        XCTAssertTrue(ui.disappears(app.staticTexts["Quick Add"]))

        ui.openTab("Tasks")
        XCTAssertTrue(ui.reveal("milk"), "Quick Add created the task")
    }

    /// Calendar (the Up Next widget's link): today's agenda, the week view, the event editor.
    @MainActor
    func testCalendar() {
        let (app, ui) = launchPreview()
        ui.openLink("aria://calendar")
        XCTAssertTrue(app.staticTexts["Team stand-up"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Aria self-test day"].exists)
        app.buttons["Week"].tap()
        XCTAssertTrue(app.staticTexts["Team stand-up"].waitForExistence(timeout: 10))
        app.staticTexts["Team stand-up"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(ui.disappears(app.navigationBars["Edit Event"]))
    }

    /// Tasks: open tasks, completed ones on request, the task editor.
    @MainActor
    func testTasks() {
        let (app, ui) = launchPreview()
        ui.openLink("aria://tasks")
        XCTAssertTrue(app.staticTexts["Read a chapter"].waitForExistence(timeout: 10))
        app.staticTexts["Call Mum"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(ui.disappears(app.navigationBars["Edit Task"]))

        XCTAssertFalse(app.staticTexts["Water the plants"].exists, "completed tasks are hidden")
        ui.element("Show completed").tap()
        XCTAssertTrue(ui.reveal("Water the plants"), "Show completed lists them")
    }

    /// The assistant asks for an OpenRouter key and shows the conversation; Settings shows
    /// the account and signs out.
    @MainActor
    func testAssistantAndSettings() {
        let (app, ui) = launchPreview()
        ui.openLink("aria://assistant")
        XCTAssertTrue(ui.element("Connect OpenRouter").waitForExistence(timeout: 10))
        XCTAssertTrue(ui.showsText("Added 'Finish essay' for Friday at 5pm."), "shows the reply")
        XCTAssertTrue(ui.showsText("Created task 'Finish essay'"), "shows the change the assistant made")
        app.buttons["Done"].tap()
        XCTAssertTrue(ui.disappears(ui.element("Connect OpenRouter")))

        ui.openTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(ui.showsText("Ada Lovelace"), "Settings shows the account")
        let signOut = app.buttons.matching(NSPredicate(format: "label == %@", "Sign Out"))
        let row = signOut.firstMatch
        let rowFrame = row.frame
        row.tap()
        // The confirmation's own button: the row underneath is covered (an action sheet on
        // iPhone, a popover on iPad).
        let confirm = ui.waitForElement { signOut.allElementsBoundByIndex.first { $0.frame != rowFrame && $0.isHittable } }
        XCTAssertNotNil(confirm, "Sign Out asks for confirmation")
        confirm?.tap()
        XCTAssertTrue(app.staticTexts["Your planner, run by an assistant."].waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        // iPads run in landscape so the sidebar is on screen.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func launchPreview() -> (XCUIApplication, UI) {
        let app = launch(["-AriaUITest", "-AriaUITestPreview"])
        XCTAssertTrue(app.staticTexts["Up next"].waitForExistence(timeout: 20), "the preview signs in to Today")
        return (app, UI(app: app))
    }
}

@MainActor
private struct UI {
    let app: XCUIApplication

    /// Opens an `aria://` link the way a widget does, accepting the system prompt if one appears.
    func openLink(_ link: String) {
        app.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 1) { open.tap() }
    }

    /// A tab on iPhone, a sidebar row on iPad.
    func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.exists { tab.tap() } else { app.buttons[name].firstMatch.tap() }
    }

    func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
    }

    /// A one-line or multi-line (vertical axis) SwiftUI text field.
    func textInput(_ label: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue] as NSArray
        return app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@ AND (label == %@ OR placeholderValue == %@)", types, label, label)).firstMatch
    }

    /// Text shown in an element's label (also inside merged rows such as "Name, Ada Lovelace")
    /// or as its value.
    func showsText(_ text: String, timeout: TimeInterval = 10) -> Bool {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value == %@", text, text)).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    /// Scrolls down until the text shows up: lists only create the rows that are on screen,
    /// so on a small iPhone the bottom sections don't exist until scrolled to.
    func reveal(_ text: String, swipes: Int = 4) -> Bool {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if match.waitForExistence(timeout: 5) { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if match.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    func disappears(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func waitForElement(timeout: TimeInterval = 10, _ find: @escaping () -> XCUIElement?) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = find() { return element }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return find()
    }
}
