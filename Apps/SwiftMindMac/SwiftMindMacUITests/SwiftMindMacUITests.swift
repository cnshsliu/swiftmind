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
        // IMPORTANT: Do NOT pass "YES"/"NO" as separate launch args.
        // DocumentGroup treats bare tokens as file paths → dialog:
        //   The document "YES" could not be opened.
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

    /// DocumentGroup shows Open sheet on cold launch — get to an Untitled window.
    private func ensureDocumentWindow() throws {
        // Give launch a moment
        _ = app.wait(for: .runningForeground, timeout: 8)

        // Dismiss Open / Open Recent style sheets
        dismissOpenPanelIfPresent()

        // Try File → New / New Document via menu (locale-tolerant)
        if !hasWorkingChrome() {
            openNewDocumentFromMenu()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            dismissOpenPanelIfPresent()
        }

        // Keyboard fallback
        if !hasWorkingChrome() {
            app.typeKey("n", modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            dismissOpenPanelIfPresent()
        }

        // One more New
        if !hasWorkingChrome() {
            app.typeKey("n", modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }

        XCTAssertTrue(
            hasWorkingChrome() || app.windows.count > 0,
            """
            Failed to open a document window.
            Windows: \(app.windows.count)
            Debug (truncated): \(String(app.debugDescription.prefix(2000)))
            """
        )
    }

    private func dismissOpenPanelIfPresent() {
        // System open panel can be a sheet or dialog
        let candidates = [
            app.sheets.firstMatch,
            app.dialogs["Open"],
            app.dialogs.firstMatch,
        ]
        for panel in candidates {
            guard panel.waitForExistence(timeout: 1.5) else { continue }
            for title in ["Cancel", "取消", "Close", "关闭"] {
                let btn = panel.buttons[title]
                if btn.exists {
                    btn.click()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    return
                }
            }
            // Keyboard cancel
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            return
        }
    }

    private func openNewDocumentFromMenu() {
        let fileMenu = app.menuBars.menuBarItems["File"]
        if fileMenu.exists {
            fileMenu.click()
            for itemTitle in ["New", "New Document", "新建", "新建文稿", "New…"] {
                let item = app.menuItems[itemTitle]
                if item.exists {
                    item.click()
                    return
                }
            }
            // Menu might already show items without click in some configs
            app.typeKey("n", modifierFlags: .command)
        }
    }

    private func hasWorkingChrome() -> Bool {
        if element("mapCanvas").waitForExistence(timeout: 1) { return true }
        if element("mapTitleField").waitForExistence(timeout: 0.5) { return true }
        if element("statusStrip").waitForExistence(timeout: 0.5) { return true }
        if app.textFields["Untitled map"].exists { return true }
        // Any document window with toolbar buttons
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

    func testAddChildViaCommandT() throws {
        let beforeWindows = app.windows.count
        XCTAssertGreaterThan(beforeWindows, 0)

        // Prefer toolbar if identifier is visible
        let addChild = element("toolbarAddChild")
        if addChild.waitForExistence(timeout: 2), addChild.isHittable {
            addChild.click()
        } else if app.buttons["Add Child"].exists {
            app.buttons["Add Child"].click()
        } else {
            app.typeKey("t", modifierFlags: .command)
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        // Still alive + window present
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
}
