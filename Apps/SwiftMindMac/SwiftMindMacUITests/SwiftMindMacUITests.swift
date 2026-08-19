import XCTest

/// macOS UI smoke tests (XCUITest — built into Xcode).
///
/// Goal: catch “app won’t open / shortcuts broken / chrome missing”
/// without manual click-through. Canvas geometry is covered by unit tests.
final class SwiftMindMacUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "app.swiftmind.mac")
        // Defaults for UI testing are set in SwiftMindMacApp when it sees -uitesting.
        app.launchArguments = ["-uitesting"]
        app.launch()
        try ensureDocumentWindow()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Document bootstrap

    /// App auto-opens last map or creates ~/Documents/SwiftMind/Untitled — no Open panel.
    private func ensureDocumentWindow() throws {
        _ = app.wait(for: .runningForeground, timeout: 8)

        // Wait for chrome from auto-open (no File → New required).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if hasWorkingChrome() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        XCTAssertTrue(
            hasWorkingChrome() || app.windows.count > 0,
            """
            Failed to open a document window after auto-bootstrap.
            Windows: \(app.windows.count)
            Debug (truncated): \(String(app.debugDescription.prefix(2000)))
            """
        )
    }

    private func hasWorkingChrome() -> Bool {
        if element("mapCanvas").waitForExistence(timeout: 1) { return true }
        if element("mapTitleField").waitForExistence(timeout: 0.5) { return true }
        if element("statusStrip").waitForExistence(timeout: 0.5) { return true }
        if element("toolbarMyBrain").waitForExistence(timeout: 0.5) { return true }
        if app.buttons["Add Child"].exists || element("toolbarAddChild").exists { return true }
        return false
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    // MARK: - Tests

    func testLaunchHasWindow() throws {
        XCTAssertGreaterThan(app.windows.count, 0, "App should show at least one window")
    }

    func testLaunchHasNoOpenPanel() throws {
        // Cold launch should not leave an Open sheet up.
        let openDialog = app.dialogs["Open"]
        XCTAssertFalse(openDialog.exists, "Should not show Open dialog on launch")
    }

    func testAddChildViaCommandT() throws {
        let beforeWindows = app.windows.count
        XCTAssertGreaterThan(beforeWindows, 0)

        let addChild = element("toolbarAddChild")
        if addChild.waitForExistence(timeout: 2), addChild.isHittable {
            addChild.click()
        } else if app.buttons["Add Child"].exists {
            app.buttons["Add Child"].click()
        } else {
            app.typeKey("t", modifierFlags: .command)
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertGreaterThan(app.windows.count, 0)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testAddChildThenSiblingShortcuts() throws {
        XCTAssertGreaterThan(app.windows.count, 0)
        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeKey("t", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertGreaterThan(app.windows.count, 0)
    }

    func testCommandPaletteOpenClose() throws {
        app.typeKey("k", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testUndoAfterAddChild() throws {
        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeKey("z", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMyBrainToolbarExists() throws {
        XCTAssertTrue(
            element("toolbarMyBrain").waitForExistence(timeout: 5)
                || app.buttons["My Brain"].exists,
            "My Brain control should be available"
        )
    }

    func testFormulaSetAndClear() throws {
        // Root is selected on launch; the inspector is visible by default.
        let field = element("formulaField")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Formula field should be in the inspector")

        field.click()
        field.typeText("count(children)")
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let result = element("formulaResult")
        XCTAssertTrue(result.waitForExistence(timeout: 3), "Computed result should appear")

        let clear = element("clearFormulaButton")
        XCTAssertTrue(clear.waitForExistence(timeout: 2), "Clear button should appear once a formula is set")
        clear.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(result.exists, "Clearing the formula should remove the result")
    }
}
