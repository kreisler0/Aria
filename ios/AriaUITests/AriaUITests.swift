import UIKit
import XCTest

/// Runs the real app in the simulator; CI runs it on an iPhone and on an iPad. With
/// `-AriaUITestPreview` the app signs in to a day of sample data and no backend (see
/// `UITestPreview` in the app), so every screen can be exercised without a Supabase
/// project or an OpenRouter key.
final class AriaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchAsksForABackend() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Connect your backend"].waitForExistence(timeout: 30))
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "Connect needs a URL and a key first")
    }

    @MainActor
    func testEveryScreenWithSampleData() {
        let app = launch(arguments: ["-AriaUITestPreview"])
        let ui = UI(app: app)

        // Today: the greeting and what's next; ticking a task takes it off the list.
        XCTAssertTrue(app.staticTexts["Up next"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ", Ada")).firstMatch.exists,
                      "Today greets the user by name")
        XCTAssertTrue(app.staticTexts["Aria self-test day"].exists)
        XCTAssertTrue(app.staticTexts["Pay rent"].exists)
        app.buttons["complete Pay rent"].tap()
        XCTAssertTrue(ui.disappears(app.staticTexts["Pay rent"]), "a completed task leaves Today")

        // Quick Add, through the Quick Add widget's link.
        ui.openLink("aria://quick-add")
        XCTAssertTrue(app.staticTexts["Quick Add"].waitForExistence(timeout: 10))
        let field = ui.textInput("Add a task, or ask Aria…")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Buy oat milk")
        app.buttons["Add Task"].tap()
        XCTAssertTrue(ui.disappears(app.staticTexts["Quick Add"]))

        // Calendar (the Up Next widget's link): today's agenda, the week view, the event editor.
        ui.openLink("aria://calendar")
        XCTAssertTrue(app.staticTexts["Team stand-up"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Aria self-test day"].exists)
        app.buttons["Week"].tap()
        XCTAssertTrue(app.staticTexts["Team stand-up"].waitForExistence(timeout: 10))
        app.staticTexts["Team stand-up"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(ui.disappears(app.navigationBars["Edit Event"]))

        // Tasks: the task added above, completed tasks on request, the task editor.
        ui.openLink("aria://tasks")
        XCTAssertTrue(app.staticTexts["Read a chapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Buy oat milk"].exists, "Quick Add created the task")
        XCTAssertFalse(app.staticTexts["Pay rent"].exists, "completed tasks are hidden")
        ui.element("Show completed").tap()
        XCTAssertTrue(app.staticTexts["Pay rent"].waitForExistence(timeout: 10), "Show completed lists it again")
        app.staticTexts["Call Mum"].tap()
        XCTAssertTrue(app.navigationBars["Edit Task"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(ui.disappears(app.navigationBars["Edit Task"]))

        // Assistant: asks for an OpenRouter key and shows the conversation.
        ui.openLink("aria://assistant")
        XCTAssertTrue(ui.element("Connect OpenRouter").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Added 'Finish essay' for Friday at 5pm."].exists)
        XCTAssertTrue(app.staticTexts["Created task 'Finish essay'"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(ui.disappears(ui.element("Connect OpenRouter")))

        // Settings: the account, then signing out returns to the sign-in screen.
        ui.openTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(ui.showsText("Ada Lovelace"), "Settings shows the account")
        let signOut = app.buttons.matching(NSPredicate(format: "label == %@", "Sign Out"))
        signOut.firstMatch.tap()
        XCTAssertTrue(ui.waitFor { signOut.count >= 2 }, "Sign Out asks for confirmation")
        signOut.element(boundBy: signOut.count - 1).tap()
        XCTAssertTrue(app.staticTexts["Your planner, run by an assistant."].waitForExistence(timeout: 10))
    }

    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        // iPads run in landscape so the sidebar is on screen.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }
}

@MainActor
private struct UI {
    let app: XCUIApplication

    /// Opens an `aria://` link the way a widget does, accepting the system prompt if one appears.
    func openLink(_ link: String) {
        app.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
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

    /// Text shown as an element's label or, for merged rows like LabeledContent, its value.
    func showsText(_ text: String, timeout: TimeInterval = 10) -> Bool {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    func disappears(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func waitFor(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
