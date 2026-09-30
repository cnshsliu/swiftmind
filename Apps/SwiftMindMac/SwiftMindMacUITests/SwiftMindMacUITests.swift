import XCTest
import Carbon.HIToolbox
import PencilKit

/// macOS UI smoke tests (XCUITest — built into Xcode).
///
/// Goal: catch “app won’t open / shortcuts broken / chrome missing”
/// without manual click-through. Canvas geometry is covered by unit tests.
final class SwiftMindMacUITests: XCTestCase {
    var app: XCUIApplication!
    private var savedInputSource: TISInputSource?

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Synthesized English keystrokes vanish into an active CJK input
        // method (composition swallows letters; Esc cancels the composition,
        // not the UI). Force ABC for the test, restore the user's source
        // afterwards.
        savedInputSource = InputSourceHelper.selectASCII()
        app = XCUIApplication(bundleIdentifier: "app.swiftmind.mac.dev")
        // Defaults for UI testing are set in SwiftMindMacApp when it sees -uitesting;
        // the scratch map keeps edits away from the user's real documents.
        app.launchArguments = ["-uitesting", "-uitesting-scratch-map"]
        app.launch()
        try ensureDocumentWindow()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        InputSourceHelper.restore(savedInputSource)
        savedInputSource = nil
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

    /// Multi-window behavior (2026-09 design, replaces the withdrawn
    /// quit-on-close fix): closing the last window leaves the app running
    /// Word-style, and File > New Map reopens a window — that menu path is
    /// what App Review guideline 4 requires. NOT YET RUN (deferred).
    func testClosingLastWindowLeavesAppRunningAndNewMapReopens() throws {
        XCTAssertTrue(element("mapCanvas").waitForExistence(timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // File > Close (⌘W) must exist — its absence was the review rejection.
        let closeItem = app.menuBars.menuBarItems["File"].menuItems["Close"]
        XCTAssertTrue(closeItem.exists, "File menu must offer Close (⌘W)")
        app.typeKey("w", modifierFlags: .command)

        // App stays running with zero windows…
        let windowsGone = NSPredicate { app, _ in
            guard let app = app as? XCUIApplication else { return false }
            return app.state == .runningForeground && app.windows.count == 0
        }
        expectation(for: windowsGone, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.state, .runningForeground, "closing the last window must not quit the app")

        // …and the menu can open one again.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(element("mapCanvas").waitForExistence(timeout: 8),
                      "File > New Map must reopen a window after all windows were closed")
    }

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
        focusCanvasWithSelection()
        let afterAdd = nodeCount()
        XCTAssertGreaterThan(afterAdd, 1, "⌘T should add a child")

        app.typeKey("z", modifierFlags: .command)
        let undone = NSPredicate { _, _ in self.nodeCount() == afterAdd - 1 }
        expectation(for: undone, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(nodeCount(), afterAdd - 1, "⌘Z must undo add-child")

        app.typeKey("z", modifierFlags: [.command, .shift])
        let redone = NSPredicate { _, _ in self.nodeCount() == afterAdd }
        expectation(for: redone, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(nodeCount(), afterAdd, "⇧⌘Z must redo add-child")
    }

    func testMyBrainToolbarExists() throws {
        XCTAssertTrue(
            element("toolbarMyBrain").waitForExistence(timeout: 5)
                || app.buttons["My Brain"].exists,
            "My Brain control should be available"
        )
    }

    func testSpatialNavigationKeys() throws {
        let selected = element("selectedNodeLabel")
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        // StaticText exposes its content via value, not label.
        func selectedText() -> String { selected.value as? String ?? "" }

        // ⌘T adds a child and selects it (branch side depends on layout weights).
        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let childLabel = selectedText()
        XCTAssertNotEqual(childLabel, "Central Idea")

        // Inward = parent depends on branch side: left branch → h, right branch → l.
        // On a childless node the outward arrow is a no-op, so try left first.
        var outwardKey = XCUIKeyboardKey.rightArrow
        app.typeKey(.leftArrow, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if selectedText() == childLabel {
            outwardKey = .leftArrow
            app.typeKey(.rightArrow, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertEqual(selectedText(), "Central Idea", "inward arrow should select the parent")

        // Outward from root returns to the last focused child (memory).
        app.typeKey(outwardKey, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(selectedText(), childLabel, "outward arrow should return to the remembered child")
    }

    func testRunScriptInPalette() throws {
        app.typeKey("k", modifierFlags: .command)
        let query = element("paletteQueryField")
        XCTAssertTrue(query.waitForExistence(timeout: 4), "Palette query field should appear")
        query.click()
        query.typeText("run script")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        // Palette rows are Buttons whose AX label merges title + subtitle.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Run Script"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Palette should offer Run Script…")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsWindowOpens() throws {
        app.typeKey(",", modifierFlags: .command)
        // The Settings scene can restore a previously-used tab (Agent), so
        // explicitly select General before asserting its content. SwiftUI
        // composes the picker's AX label on this OS — match by substring.
        let generalTab = app.buttons["General"]
        XCTAssertTrue(generalTab.waitForExistence(timeout: 4), "⌘, should open Settings")
        generalTab.click()
        // StaticText exposes its content via value, not label.
        let pickerLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS 'On launch, open'"))
            .firstMatch
        XCTAssertTrue(
            pickerLabel.waitForExistence(timeout: 4),
            "General tab should show the launch-behavior picker"
        )
        // Close the settings window so later tests see the document window.
        app.typeKey("w", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    // MARK: - Agent bridge loopback

    private struct BridgeClientError: Error {
        let detail: String
    }

    /// The test runner acts as a UDS client against the live AgentBridge,
    /// using the same wire protocol as BridgeClient in the CLI.
    func testAgentBridgeLoopback() throws {
        XCTAssertTrue(element("mapCanvas").waitForExistence(timeout: 5))
        // The XCUITest runner is sandboxed, so NSHomeDirectory() points at the
        // runner's own container — resolve the real user home via getpwuid.
        let pw = try XCTUnwrap(getpwuid(getuid()), "getpwuid returned nil")
        let home = String(cString: pw.pointee.pw_dir)
        // Debug builds use the canary bundle id app.swiftmind.mac.dev, so the
        // bridge lives in that container (separate from the Release install).
        let bridgeDir = home
            + "/Library/Containers/app.swiftmind.mac.dev/Data/Library/SwiftMind"
        let socketPath = bridgeDir + "/agent.sock"
        let tokenURL = URL(fileURLWithPath: bridgeDir + "/agent.token")

        // Each launch rewrites agent.token; a still-terminating instance from
        // the previous test can briefly remove it or leave a stale one, so
        // poll until a token/session round-trip succeeds.
        var session: [String: Any]?
        var lastProblem = "no attempt made"
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, session == nil {
            if let tokenData = try? Data(contentsOf: tokenURL),
               let token = String(data: tokenData, encoding: .utf8), !token.isEmpty {
                do {
                    let response = try bridgeCall(
                        socketPath: socketPath,
                        request: ["id": 1, "token": token, "method": "session", "params": [:]]
                    )
                    if response["ok"] as? Bool == true {
                        session = response
                    } else {
                        lastProblem = "bridge rejected: \(response)"
                    }
                } catch {
                    lastProblem = "bridgeCall: \(error)"
                }
            } else {
                lastProblem = "token unreadable at \(tokenURL.path)"
            }
            if session == nil {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
        let ok = try XCTUnwrap(
            session,
            "no working agent.token/agent.sock after 10s — AgentBridge should always start with the app (last: \(lastProblem))"
        )
        let result = try XCTUnwrap(ok["result"] as? [String: Any])
        XCTAssertNotNil(result["title"] as? String)
        XCTAssertNotNil(result["isBrainMode"] as? Bool)

        // Wrong token must be rejected.
        let denied = try bridgeCall(
            socketPath: socketPath,
            request: ["id": 2, "token": "wrong", "method": "session", "params": [:]]
        )
        XCTAssertEqual(denied["ok"] as? Bool, false, "wrong token should fail: \(denied)")
        let error = try XCTUnwrap(denied["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unauthorized")
    }

    /// One request, one short-lived connection (mirrors BridgeClient).
    private func bridgeCall(socketPath: String, request: [String: Any]) throws -> [String: Any] {
        func fail(_ detail: String) throws -> Never {
            throw BridgeClientError(detail: detail)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try fail("socket() failed: errno \(errno)") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            try fail("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    dest.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            try fail("connect to \(socketPath) failed: errno \(errno)")
        }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var payload = try JSONSerialization.data(withJSONObject: request)
        var length = UInt32(payload.count).bigEndian
        payload.insert(contentsOf: withUnsafeBytes(of: &length) { Data($0) }, at: 0)
        try payload.withUnsafeBytes { ptr in
            var sent = 0
            while sent < ptr.count {
                // MSG_NOSIGNAL: a dead peer must not kill the test runner with SIGPIPE.
                let n = send(fd, ptr.baseAddress! + sent, ptr.count - sent, MSG_NOSIGNAL)
                if n < 0 {
                    if errno == EINTR { continue }
                    try fail("send failed: errno \(errno)")
                }
                sent += n
            }
        }

        func readFully(_ count: Int) -> Data? {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: min(count, 65536))
            while data.count < count {
                let n = buffer.withUnsafeMutableBytes { ptr in
                    recv(fd, ptr.baseAddress, min(ptr.count, count - data.count), 0)
                }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return nil }
                data.append(contentsOf: buffer[0..<n])
            }
            return data
        }
        guard let header = readFully(4) else { try fail("no response header") }
        let responseLength = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard responseLength > 0, responseLength <= 4 * 1024 * 1024 else {
            try fail("bad frame length \(responseLength)")
        }
        guard let body = readFully(Int(responseLength)) else { try fail("truncated response") }
        guard let response = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            try fail("malformed response")
        }
        return response
    }

    func testFormulaSetAndClear() throws {
        // Formula lives on the inspector's Data page now.
        let dataTab = app.radioButtons["Data"]
        XCTAssertTrue(dataTab.waitForExistence(timeout: 3), "inspector tabs should exist")
        dataTab.click()
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

    func testCopyPasteNode() throws {
        let countLabel = element("nodeCountLabel")
        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        func nodeCount() -> Int {
            let text = countLabel.value as? String ?? countLabel.label
            let digits = text.prefix { $0.isNumber }
            return Int(digits) ?? -1
        }

        // Focus the canvas first: at launch a text field (map title) can own
        // keyboard focus, which would turn ⌘C/⌘V into plain text edits.
        focusCanvasWithSelection()

        // Add a child (auto-selected), copy it, clear selection, paste.
        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let afterAdd = nodeCount()
        app.typeKey("c", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeKey("v", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        XCTAssertEqual(nodeCount(), afterAdd + 1, "Paste of a copied node should add exactly one node")
        let selected = element("selectedNodeLabel")
        XCTAssertTrue(
            selected.waitForExistence(timeout: 2)
                && (selected.value as? String ?? selected.label).contains("New Idea"),
            "Pasted node should be selected; got \(selected.value ?? "nil")"
        )
    }

    func testNoteEditorTypingKeepsEditorOpen() throws {
        focusCanvasWithSelection()

        // E opens the floating editor; typing letters (especially "e"/"x")
        // must go into the editor, not toggle it closed.
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        app.typeText("hello")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(editor.exists, "Typing \"hello\" (contains e) must not close the editor")

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(editor.exists, "Esc should close the note editor")
    }

    /// Esc CANCELS the note editor: a debounced commit that already landed is
    /// reverted to the editor-open baseline (the revert itself is undoable).
    func testNoteEditorEscCancels() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        editor.click()
        editor.typeText("cancel me")

        // The debounced commit must be observable on disk first — otherwise a
        // broken revert would pass vacuously.
        XCTAssertTrue(
            waitForScratchMap { $0.contains("cancel me") },
            "the debounced note commit should autosave before Esc"
        )

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(editor.exists, "Esc should close the note editor")
        XCTAssertTrue(
            waitForScratchMap { !$0.contains("cancel me") },
            "Esc must revert the note to the pre-edit content"
        )
    }

    /// ⌘Enter commits & closes the note editor.
    func testNoteEditorCommandReturnCommits() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        editor.click()
        editor.typeText("keepme")

        app.typeKey(.return, modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(editor.exists, "⌘Enter should close the note editor")
        XCTAssertTrue(
            waitForScratchMap { $0.contains("keepme") },
            "⌘Enter must commit the typed note"
        )
    }

    /// Clicking blank canvas commits & closes the note editor.
    func testNoteEditorClickAwayCommits() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        editor.click()
        editor.typeText("clickaway")

        // Tap blank canvas. The mapCanvas AX frame spans sidebar + canvas +
        // toolbar (measured: window 1920 wide, frame 0,30 1539x972), so
        // normalized corners land on chrome — aim past the sidebar, clear of
        // the toolbar and the vertically centered nodes/editor.
        let canvas = element("mapCanvas")
        let frame = canvas.frame
        let target = CGPoint(x: frame.midX, y: frame.minY + 140)
        canvas.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.x - frame.minX, dy: target.y - frame.minY))
            .click()
        let closed = NSPredicate { _, _ in !editor.exists }
        expectation(for: closed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(editor.exists, "click-away should close the note editor")
        XCTAssertTrue(
            waitForScratchMap { $0.contains("clickaway") },
            "click-away must commit the typed note"
        )
    }

    /// ⌘E ("Edit Note at Node") opens the note editor even on a title-only
    /// node — the virtual document is just `# title`; plain title editing
    /// stays on Return.
    func testCommandEOpensNoteEditorOnNotelessNode() throws {
        focusCanvasWithSelection()

        app.typeKey("e", modifierFlags: .command)
        let editor = element("noteEditor")
        XCTAssertTrue(
            editor.waitForExistence(timeout: 3),
            "⌘E should open the note editor on a noteless node"
        )
        // Nothing typed — Esc cancel is a no-op revert.
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Typing aid: Return on a `- ` list line continues the marker on the
    /// next line (outliner behavior in MarkdownEditorView).
    func testNoteEditorListContinuation() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        editor.click()
        // Caret to the document end (past the `# title` line), then one item.
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("- alpha")
        app.typeKey(.return, modifierFlags: []) // continues the "- " marker
        app.typeText("beta")

        app.typeKey(.return, modifierFlags: .command) // ⌘Enter: commit & close
        let closed = NSPredicate { _, _ in !editor.exists }
        expectation(for: closed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(
            waitForScratchMap { $0.contains("- alpha") && $0.contains("- beta") },
            "Return on a list line must insert the marker (only \"beta\" was typed)"
        )
    }

    /// Typing aid: ⌘B wraps the selected word in `**`.
    func testNoteEditorBoldShortcut() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("bold")
        app.typeKey(.leftArrow, modifierFlags: [.shift, .option]) // select the word
        app.typeKey("b", modifierFlags: .command)

        app.typeKey(.return, modifierFlags: .command) // commit & close
        let closed = NSPredicate { _, _ in !editor.exists }
        expectation(for: closed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(
            waitForScratchMap { $0.contains("**bold**") },
            "⌘B must wrap the selection in ** markers"
        )
    }

    /// Undo coalescing (2c): all debounced bursts of one editor session are a
    /// single map-level undo step.
    func testNoteUndoRevertsWholeSession() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("sessAAA")
        // Burst 1 must land on disk before burst 2, otherwise a missing
        // coalescing merge would pass vacuously.
        XCTAssertTrue(
            waitForScratchMap { $0.contains("sessAAA") },
            "first debounced commit should autosave"
        )
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("sessBBB")
        XCTAssertTrue(
            waitForScratchMap { $0.contains("sessBBB") },
            "second debounced commit should autosave"
        )

        app.typeKey(.return, modifierFlags: .command) // ⌘Enter: commit & close
        let closed = NSPredicate { _, _ in !editor.exists }
        expectation(for: closed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)

        // One map-level ⌘Z reverts BOTH bursts (canvas has focus, so this is
        // the store undo, not text-level undo).
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            waitForScratchMap { !$0.contains("sessAAA") && !$0.contains("sessBBB") },
            "one ⌘Z must revert the whole editing session"
        )
    }

    /// Insertion helpers (3b): the link toolbar button writes `[title](url)`
    /// at the caret as plain Markdown.
    func testNoteEditorInsertLinkWritesMarkdown() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        let insertLink = element("noteEditorInsertLink")
        XCTAssertTrue(insertLink.waitForExistence(timeout: 3), "insert-link toolbar should appear")
        insertLink.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        app.typeKey(.return, modifierFlags: .command)
        let closed = NSPredicate { _, _ in !editor.exists }
        expectation(for: closed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(
            waitForScratchMap { $0.contains("[title](url)") },
            "Insert Link must write a Markdown link template at the caret"
        )
    }

    /// Insertion helpers (3b): math on an empty line writes a `$$…$$` block.
    func testNoteEditorInsertMathWritesTemplate() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "E should open the note editor")
        let insertMath = element("noteEditorInsertMath")
        XCTAssertTrue(insertMath.waitForExistence(timeout: 3), "insert-math toolbar should appear")
        insertMath.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        app.typeKey(.return, modifierFlags: .command)
        let closed = NSPredicate { _, _ in !editor.exists }
        expectation(for: closed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(
            waitForScratchMap { $0.contains("$$") },
            "Insert Math must write a $$ template"
        )
    }

    /// Enter at the end of a list item continues the list: the editor opens
    /// the next line with the same marker and typed letters stay there.
    /// (Deterministic flow: one list item typed, Return via an explicit key
    /// event — never "\n" inside typeText, whose delivery mode varies between
    /// batched insertText and per-key synthesis. Quote continuation and the
    /// caret edge cases are covered by MarkdownEditingSessionTests.)
    func testEnterContinuesListAndQuoteBeforeTheNextLine() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("- dotted item")
        app.typeKey(.return, modifierFlags: [])
        editor.typeText("abcd")

        let value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("abcd"), value)
        XCTAssertTrue(
            value.contains("- abcd") || value.contains("\nabcd\n"),
            "continued list line should hold abcd — \(value)"
        )
        XCTAssertFalse(value.contains("abcdanother"), value)
        // No corruption from the pre-flush race: lines must not duplicate.
        XCTAssertFalse(value.contains("- dotted item\n- dotted item"), value)
    }

    /// Backspace on the dash of an empty middle list item must not send the
    /// caret to the end of the note.
    func testBackspaceOnEmptyListItemKeepsCaret() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("- dotted item")
        app.typeKey(.return, modifierFlags: [])
        // Caret is after the continued "- ". Step back onto the dash and delete it.
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let value = (editor.value as? String) ?? ""
        try? value.write(toFile: "/tmp/note-editor-value.txt", atomically: true, encoding: .utf8)
        try? editor.label.write(toFile: "/tmp/note-editor-label.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(value.contains("dotted item"), value)
        XCTAssertFalse(value.contains("- -"), "list marker doubled — \(value)")
        let label = editor.label
        if let caretRange = label.range(of: "caret:"),
           let caret = Int(label[caretRange.upperBound...].prefix(while: \.isNumber)) {
            XCTAssertNotEqual(
                caret,
                (value as NSString).length,
                "caret jumped to the end — \(label)\n\(value)"
            )
        }
    }

    /// A highlighted span is removed by Delete and by Forward Delete.
    /// One character at the caret is the bug.
    func testDeleteRemovesSelectedText() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("abcdef")
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.delete, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        var value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("abc"), value)
        XCTAssertFalse(value.contains("def"), "Delete must remove the selection — \(value)")
        XCTAssertFalse(value.contains("abcf"), "Delete removed one character — \(value)")

        editor.typeText("xyz")
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.forwardDelete, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("abc"), value)
        XCTAssertTrue(value.contains("x"), value)
        XCTAssertFalse(value.contains("yz"), "Forward Delete must remove the selection — \(value)")
        XCTAssertFalse(value.contains("xy"), "Forward Delete removed one character — \(value)")

        editor.typeText("abcdef")
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.leftArrow, modifierFlags: .shift)
        editor.typeText("a")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("abca"), "typing must leave the character that replaced the selection — \(value)")
        XCTAssertFalse(value.contains("def"), "typing must replace the selection — \(value)")
        XCTAssertFalse(value.contains("abcda"), "typing inserted beside the selection — \(value)")
    }

    /// Backspace and Return keep the rest of the note, and the navigation
    /// keys do not eat it.
    func testNoteEditorCaretStaysPutAndNavigationKeysWork() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n- alpha\n> quoted")

        // Caret after the dash on the list line: up, then to the line start, then right.
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])
        var value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("alpha"), "backspace after '-' must keep the item — got \(value)")
        XCTAssertFalse(value.contains("- -"), "list marker must not double — got \(value)")

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("quoted"), "return in a quote must keep the quote — got \(value)")

        app.typeKey(.home, modifierFlags: [])
        app.typeKey(.end, modifierFlags: [])
        app.typeKey(.pageUp, modifierFlags: [])
        app.typeKey(.pageDown, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: .command)
        value = (editor.value as? String) ?? ""
        XCTAssertTrue(value.contains("alpha"), "navigation keys must not delete the note — got \(value)")
        XCTAssertTrue(value.contains("quoted"), "navigation keys must not delete the quote — got \(value)")
    }

    func testNoteEditorHidesBoldMarkers() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("**x**")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let value = (editor.value as? String) ?? ""
        XCTAssertFalse(value.contains("*"), "rendered display hides ** — got \(value)")
        XCTAssertTrue(value.contains("x"))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForScratchMap { $0.contains("**x**") }, "file still stores the markers")
    }

    /// A wrapped paragraph measures taller than one line and stays under the cap.
    func testExpandedCardIsTallerThanOneLine() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(String(repeating: "word ", count: 80))
        app.typeKey(.return, modifierFlags: .command)
        app.typeKey(.init("x"), modifierFlags: [])
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'noteCard-'")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertGreaterThan(card.frame.height, 40)
        XCTAssertLessThanOrEqual(card.frame.height, 420)
    }

    /// On-card mode (3a): with Settings `swiftmind.noteEditMode=onCard` and
    /// an expanded note, `E` hosts the editor at the card (`noteEditorOnCard`).
    func testOnCardNoteEditorOpensAndCommits() throws {
        app.terminate()
        app.launchArguments = [
            "-uitesting", "-uitesting-scratch-map",
            "-swiftmind.noteEditMode", "onCard",
        ]
        app.launch()
        try ensureDocumentWindow()
        focusCanvasWithSelection()

        app.typeKey(.init("x"), modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        app.typeKey(.init("e"), modifierFlags: [])

        let onCard = element("noteEditorOnCard")
        XCTAssertTrue(
            onCard.waitForExistence(timeout: 3),
            "expanded note + E in on-card mode should host the editor on the card"
        )
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 2), "the shared note editor should exist")
        editor.click()
        editor.typeText("oncardbody")

        app.typeKey(.return, modifierFlags: .command)
        let closed = NSPredicate { _, _ in !editor.exists }
        expectation(for: closed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(
            waitForScratchMap { $0.contains("oncardbody") },
            "⌘Enter must commit on-card edits"
        )
    }

    func testZZCaptureNoteMathRendering() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("e"), modifierFlags: [])
        let editor = element("noteEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeText("Gauss $\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}$ done")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        guard let shot = try? XCUIScreen.main.screenshot() else {
            XCTFail("no screenshot"); return
        }
        // Test runner's sandbox is disabled, so /tmp is writable.
        try shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/uitest_shot.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp/uitest_shot.png"))
    }

    /// Bug repro (reported 2026-09-24): create node, type short text,
    /// confirm; then re-edit and replace with very long text — the frame
    /// stays short and the text overflows. Screenshots land in
    /// /tmp/title-edit-shots so the frames can be inspected off-line.
    func testTitleEditShortToLongFrame() throws {
        focusCanvasWithSelection() // ⌘T → "New Idea" selected + editing
        let out = URL(fileURLWithPath: "/tmp/title-edit-shots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            try? app.windows.firstMatch.screenshot().pngRepresentation
                .write(to: out.appendingPathComponent(name))
        }

        app.typeKey("a", modifierFlags: .command)
        app.typeText("abcd")
        app.typeKey(.return, modifierFlags: [])
        shot("1-abcd-committed.png")

        // Re-edit the same node: Return renames the selected node.
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("this text was edited in place from a short four letter word into something far longer than before")
        shot("2-long-mid-edit.png")

        // NOTE: no frame assertion here — the overlay TextField does not
        // expose itself to the macOS accessibility tree (identifier, focus
        // predicate, and empty-identifier queries all miss it). The mid-edit
        // box width is guarded by 2-long-mid-edit.png + 4-cjk-mid-edit.png
        // (visual regression, like testZZAppStoreScreenshots) and the
        // committed-frame width by LayoutEngineTests' CJK tests.

        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("3-long-committed.png")

        // Round 2: a different long text (edit-again path). NOTE: typing CJK
        // through synthesized events stalls under the forced ASCII input
        // source (XCUITest cannot synthesize it reliably) — CJK width is
        // covered deterministically by LayoutEngineTests' CJK tests.
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("a second long replacement typed over the first one to exercise the edit-again path")
        shot("4-replace-mid-edit.png")
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("5-replace-committed.png")

        XCTAssertGreaterThanOrEqual(settledNodeCount(), 2)
    }

    /// 1.2: ⌥↓/⌥↑ reorder the selected node among siblings.
    func testReorderSiblingShortcuts() throws {
        focusCanvasWithSelection()
        let before = settledNodeCount()
        // Three siblings: the scratch root has one child; add two more.
        app.typeKey("t", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        app.typeKey("t", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(settledNodeCount(), before + 2)

        // ⌥↓ then ⌥↑ — count unchanged, no crash; undo stack consistent.
        app.typeKey(.downArrow, modifierFlags: .option)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeKey(.upArrow, modifierFlags: .option)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(settledNodeCount(), before + 2)
    }

    /// 1.2: Tab inserts a child and opens the inline editor.
    func testTabInsertsChildAndEdits() throws {
        focusCanvasWithSelection()
        let before = settledNodeCount()
        app.typeKey(.tab, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(settledNodeCount(), before + 1, "Tab must add a child")
    }

    /// 1.2 smoke: the Node menu offers Fold All Below and invoking it keeps
    /// the app healthy (core-level behavior is covered by MapStoreTests).
    func testFoldAllMenuSmoke() throws {
        focusCanvasWithSelection()
        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let before = settledNodeCount()
        let foldAll = app.menuBars.menuBarItems["Node"].menuItems["Fold All Below"]
        XCTAssertTrue(foldAll.waitForExistence(timeout: 3), "Node menu must offer Fold All Below")
        foldAll.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(settledNodeCount(), before, "fold never changes the model count")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// App Store listing screenshots: relaunch WITHOUT the scratch map so the
    /// default launch behavior opens the bundled Welcome map (a good demo
    /// backdrop) and capture canvas / outline / note-editor / My Brain.
    /// PNGs land in /tmp/appstore-shots; a script step crops them to an
    /// accepted App Store size afterwards (no AX window resizing — that
    /// triggers an Accessibility permission prompt that blocks the app).
    func testZZAppStoreScreenshots() throws {
        app.terminate()
        app.launchArguments = ["-uitesting"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 8)
        XCTAssertTrue(element("mapCanvas").waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let window = app.windows.firstMatch
        let out = URL(fileURLWithPath: "/tmp/appstore-shots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            try? window.screenshot().pngRepresentation
                .write(to: out.appendingPathComponent(name))
        }

        shot("1-canvas.png")

        // Outline view via the segmented picker (segments expose as radio
        // buttons on macOS).
        let picker = element("viewModePicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertEqual(picker.radioButtons.count, 2)
        picker.radioButtons.element(boundBy: 1).click()
        XCTAssertTrue(element("outlineList").waitForExistence(timeout: 3))
        shot("2-outline.png")
        picker.radioButtons.element(boundBy: 0).click()
        XCTAssertTrue(element("mapCanvas").waitForExistence(timeout: 3))

        // Floating note editor on the root (Markdown + LaTeX demo). Click a
        // node card directly — canvas-center clicks miss the root on the
        // wide Welcome map.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'noteCard-'"))
            .firstMatch
        if card.waitForExistence(timeout: 3) {
            // The card can extend past the window bottom (window size varies
            // between the launch-adopted and value windows) — click its
            // visible top region instead of the center.
            if card.isHittable {
                card.click()
            } else {
                card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).click()
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeKey(.init("e"), modifierFlags: [])
        if element("noteEditor").waitForExistence(timeout: 3) {
            shot("3-note-editor.png")
            app.typeKey(.escape, modifierFlags: [])
        }

        // My Brain vault navigator.
        app.typeKey("b", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        shot("4-mybrain.png")

        let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertGreaterThanOrEqual(files.count, 4, "expected screenshots in \(out.path)")
    }
}


// MARK: - Canvas focus helper

/// Creates a selected node through the app command. The canvas accessibility
/// frame can include the inspector, so its center is not a reliable node hit.
extension SwiftMindMacUITests {
    func nodeCount() -> Int {
        let el = element("nodeCountLabel")
        guard el.exists else { return 0 }
        let raw = ((el.value as? String) ?? el.label)
        let digits = raw.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    /// Node count after the label has caught up with recent store changes
    /// (the count label can lag the selection label by a runloop tick).
    func settledNodeCount() -> Int {
        var last = nodeCount()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let current = nodeCount()
            if current == last { return current }
            last = current
        }
        return last
    }

    func focusCanvasWithSelection() {
        let canvas = element("mapCanvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "map canvas should exist")
        canvas.click()
        app.typeKey("t", modifierFlags: .command)
        let selected = element("selectedNodeLabel")
        let hasSelection = NSPredicate { _, _ in
            guard selected.exists else { return false }
            return ((selected.value as? String) ?? selected.label) == "New Idea"
        }
        expectation(for: hasSelection, evaluatedWith: selected)
        waitForExpectations(timeout: 5)
    }

    /// Reads the scratch map the app autosaves under -uitesting-scratch-map
    /// (this runner is unsandboxed by entitlement, so the path is readable).
    func scratchMapHTML() -> String? {
        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        return try? String(contentsOfFile: scratch, encoding: .utf8)
    }

    /// Autosave is debounced — poll the scratch map until `probe` holds.
    func waitForScratchMap(_ probe: (String) -> Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let html = scratchMapHTML(), probe(html) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    // MARK: - Sketch (drawing) node

    /// D opens the large borderless sketch editor on the selected node;
    /// Esc commits and closes. Drawing a stroke via a coordinate drag
    /// persists (the editor reopens with content after close).
    func testSketchHotkeyDrawEscapeRoundTrip() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("d"), modifierFlags: [])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "D should open the sketch editor")

        // Draw a stroke (coordinate drag = mouse draw) with window-relative
        // normalized coordinates — absolute frames can resolve to infinity.
        // The board covers ~70% of the window centered on the selected node.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce commit

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(editor.exists, "Esc should commit and close the sketch editor")

        // Reopen: the committed drawing loads back into the board.
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "D should reopen the sketch editor")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSketchEditorGuardsCanvasKeys() throws {
        focusCanvasWithSelection()

        app.typeKey(.init("d"), modifierFlags: [])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        // Note-editor hotkey must not fire while the sketch editor is open.
        app.typeKey(.init("e"), modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(element("noteEditor").exists, "E must not open the note editor while sketching")

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(editor.exists)
    }

    func testSketchShiftCommandDMenuShortcut() throws {
        focusCanvasWithSelection()

        // ⇧⌘D is the Node > Sketch menu key equivalent.
        app.typeKey("d", modifierFlags: [.command, .shift])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "⇧⌘D should open the sketch editor")

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(editor.exists)
    }

    /// D on an empty node scribbles on that node directly — no extra child.
    func testSketchOnEmptyNodeStaysInPlace() throws {
        focusCanvasWithSelection()
        let before = settledNodeCount()

        app.typeKey(.init("d"), modifierFlags: [])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "D on an empty node should open the editor in place")

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(nodeCount(), before, "Scribbling an empty node must not create a child")
    }

    /// D on a titled node first adds a child, then scribbles on that child.
    func testSketchOnTitledNodeCreatesChild() throws {
        focusCanvasWithSelection()
        let before = settledNodeCount()

        // Give the selected node a title: Return renames, type, Return commits.
        app.typeKey(.return, modifierFlags: [])
        app.typeText("titled")
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(nodeCount(), before, "Renaming must not change the node count")

        app.typeKey(.init("d"), modifierFlags: [])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "D on a titled node should open the editor")

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(nodeCount(), before + 1, "Scribbling a titled node must add a child to draw on")

        // Undo removes the sketch board, then the child.
        app.typeKey("z", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeKey("z", modifierFlags: .command)
        let restored = NSPredicate { _, _ in self.nodeCount() == before }
        expectation(for: restored, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(nodeCount(), before, "⌘Z twice should remove the child again")
    }

    /// D on a node that already holds a sketch reopens that sketch in place.
    func testSketchOnSketchedNodeEditsInPlace() throws {
        focusCanvasWithSelection()
        let before = settledNodeCount()

        // Open + draw + close: the node now owns a committed sketch.
        app.typeKey(.init("d"), modifierFlags: [])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce commit
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // Re-invoke: same node, no new child.
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "D on a sketched node should reopen its board")
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(nodeCount(), before, "Re-editing a sketch must not create a child")
    }

    /// Shape tools commit MODEL elements (PPT-style): geometry + outline
    /// styling persisted via node-sketch-shapes. Precision comes from
    /// ShapeGeometry (core-tested); here assert the payload carries the
    /// drawn shapes with sane frames.
    func testSketchShapesCommitTrueGeometry() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")

        func drawShape(_ menuTitle: String, _ from: CGVector, _ to: CGVector) {
            app.typeKey(.init("d"), modifierFlags: [])
            XCTAssertTrue(editor.waitForExistence(timeout: 3), "sketch editor should open")
            let menu = element("sketchShapesMenu")
            XCTAssertTrue(menu.waitForExistence(timeout: 2), "shapes menu button")
            menu.click()
            let item = app.menuItems[menuTitle]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "menu should offer \(menuTitle)")
            item.click()
            let start = editor.coordinate(withNormalizedOffset: from)
            let end = editor.coordinate(withNormalizedOffset: to)
            start.press(forDuration: 0.05, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce commit
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave
        }

        drawShape("Rectangle", CGVector(dx: 0.25, dy: 0.55), CGVector(dx: 0.6, dy: 0.85))
        drawShape("Ellipse", CGVector(dx: 0.4, dy: 0.55), CGVector(dx: 0.7, dy: 0.85))

        let shapes = try decodePersistedShapes()
        let rect = shapes.first { $0["kind"] as? String == "rect" }
        XCTAssertNotNil(rect, "the rect tool must persist a rect element")
        let ellipse = shapes.first { $0["kind"] as? String == "ellipse" }
        XCTAssertNotNil(ellipse, "the ellipse tool must persist an ellipse element")
        for shape in [rect, ellipse].compactMap({ $0 }) {
            XCTAssertGreaterThanOrEqual(shape["width"] as? Double ?? 0, 40)
            XCTAssertGreaterThanOrEqual(shape["height"] as? Double ?? 0, 30)
            XCTAssertNotNil(shape["strokeColor"])
        }
    }

    /// Board tool shortcuts (V/B/H/E/T/U) live ONLY while the board is open.
    /// After closing, those letters must fall through to the map shortcuts
    /// ('e' opens the note editor again) and must not reopen the board.
    func testSketchToolShortcutsStopAfterClose() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.typeKey(.init("b"), modifierFlags: []) // works inside
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(editor.exists)

        // On the map again: letters do not reopen the board…
        app.typeKey(.init("v"), modifierFlags: [])
        app.typeKey(.init("u"), modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(editor.exists, "tool letters must not reopen the board")

        // …and the map's own shortcuts are back ('e' opens the note editor).
        app.typeKey(.init("e"), modifierFlags: [])
        let noteEditor = element("noteEditor")
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 3),
                      "map-level 'e' must work after the board closes")
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// PPT-style colors: board background (preset swatch) persists on the
    /// node (data-sketch-bg) and shape fill (custom RGB) persists on the shape.
    func testSketchBoardBackgroundAndShapeFill() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        // Board background: cream preset.
        element("sketchBoardBackground").click()
        let cream = element("sketchBoardBackground-#FFF8E1")
        XCTAssertTrue(cream.waitForExistence(timeout: 3), "board palette should open")
        cream.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // Shape + custom RGB fill (deep sky-ish 64/156/255).
        let menu = element("sketchShapesMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.click()
        let tri = app.menuItems["Triangle"]
        XCTAssertTrue(tri.waitForExistence(timeout: 3))
        tri.click()
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce

        app.activate()
        element("sketchToolSelect").click()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.6)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        element("sketchShapeFill").click()
        let r = element("sketchShapeFillApplyRGB")
        XCTAssertTrue(r.waitForExistence(timeout: 3), "fill picker should open")
        // Three RGB fields precede the Apply button in the picker panel.
        let fields = app.textFields.matching(
            NSPredicate(format: "placeholderValue IN {'R', 'G', 'B'}")
        ).allElementsBoundByIndex
        XCTAssertEqual(fields.count, 3, "picker should expose R/G/B fields")
        fields[0].click(); fields[0].typeText("64")
        fields[1].click(); fields[1].typeText("156")
        fields[2].click(); fields[2].typeText("255")
        r.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        // Board background persisted on the node.
        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        XCTAssertTrue(html.contains("data-sketch-bg=\"#FFF8E1\""),
                      "board background should persist as data-sketch-bg")

        // Shape fill persisted with the custom RGB.
        let shapes = try decodePersistedShapes()
        let filled = shapes.first {
            $0["kind"] as? String == "triangle" && $0["fillColor"] as? String == "#409CFF"
        }
        XCTAssertNotNil(filled, "custom RGB fill (64,156,255 → #409CFF) must persist")
    }

    /// Fill is sticky: after filling one shape, the NEXT shape drawn comes
    /// pre-filled with the same color (fillable kinds only — line/arrow and
    /// pen strokes never fill).
    func testSketchFillStickyForNewShapes() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        func pickShape(_ title: String) {
            let menu = element("sketchShapesMenu")
            XCTAssertTrue(menu.waitForExistence(timeout: 2))
            menu.click()
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.click()
        }
        func draw(_ from: CGVector, _ to: CGVector) {
            let a = editor.coordinate(withNormalizedOffset: from)
            let b = editor.coordinate(withNormalizedOffset: to)
            a.press(forDuration: 0.05, thenDragTo: b)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }

        // First triangle: no fill (outline only).
        pickShape("Triangle")
        draw(CGVector(dx: 0.1, dy: 0.5), CGVector(dx: 0.3, dy: 0.7))

        // Fill it red via the select-tool fill bar.
        app.activate()
        element("sketchToolSelect").click()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        element("sketchShapeFill").click()
        let red = element("sketchShapeFill-#FF6B6B")
        XCTAssertTrue(red.waitForExistence(timeout: 3))
        red.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // Back to a fillable shape: the new one inherits the red fill…
        app.activate()
        element("sketchToolStar")
        // star via menu (no flat button)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let menu = element("sketchShapesMenu")
        menu.click()
        let star = app.menuItems["Star"]
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        star.click()
        draw(CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.8, dy: 0.8))

        // …and a line never fills.
        menu.click()
        let line = app.menuItems["Line"]
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        line.click()
        draw(CGVector(dx: 0.5, dy: 0.2), CGVector(dx: 0.8, dy: 0.3))

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let shapes = try decodePersistedShapes()
        let filledStar = shapes.first {
            $0["kind"] as? String == "star" && $0["fillColor"] as? String == "#FF6B6B"
        }
        XCTAssertNotNil(filledStar, "a shape drawn AFTER filling must inherit the fill")
        let lineShape = shapes.first { $0["kind"] as? String == "line" }
        XCTAssertNil(lineShape?["fillColor"] ?? nil, "lines must never fill")
    }

    /// 'd' OPENS the board and never closes it — only Esc / Done close, so a
    /// stray keypress cannot throw away the user's place mid-drawing.
    func testSketchDKeyOpensOnly() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("d"), modifierFlags: [])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "d should open the board")

        app.typeKey(.init("d"), modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(editor.exists, "d while the board is open must NOT close it")

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(editor.exists, "Esc must close the board")
    }

    /// Corner-resize handles grow a shape, and ⌘C/⌘V duplicates it in-board.
    /// Uses DIAMOND — unique to this test — so accumulated scratch-map nodes
    /// from other runs cannot pollute the assertion.
    func testSketchResizeHandlesAndClipboard() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        let menu = element("sketchShapesMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.click()
        let diamond = app.menuItems["Diamond"]
        XCTAssertTrue(diamond.waitForExistence(timeout: 3))
        diamond.click()
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce

        // Select it, then drag the TOP-RIGHT corner outward.
        app.activate()
        element("sketchToolSelect").click()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.65)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let tr = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let trFar = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35))
        tr.press(forDuration: 0.05, thenDragTo: trFar)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce

        // In-board duplicate: ⌘C then ⌘V.
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let shapes = try decodePersistedShapes()
        let diamonds = shapes.filter { $0["kind"] as? String == "diamond" }
        XCTAssertEqual(diamonds.count, 2, "⌘C/⌘V must duplicate the diamond")

        // Resize check RELATIVE to the board: the drag drew 0.3 board-widths
        // and the corner pull widened it to ~0.5.
        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        let boardMatch = html.firstMatch(
            of: #/<div class="node-sketch" hidden="hidden">[A-Za-z0-9+/=]+\|([0-9.]+)\|[0-9.]+</div>/#
        )
        let boardWidth = Double(boardMatch.map { String($0.output.1) } ?? "") ?? 0
        for shape in diamonds {
            let width = shape["width"] as? Double ?? 0
            XCTAssertGreaterThan(width, boardWidth * 0.42,
                                 "resized diamond should span ~0.5 board widths (\(width) of \(boardWidth))")
        }
    }

    /// Custom named styles: "Save as Style…" persists the node's current
    /// style under a name; the picker offers it and the file round-trips.
    func testSaveNamedStyleRoundTrip() throws {
        focusCanvasWithSelection()

        let styleTab = app.radioButtons["Style"]
        XCTAssertTrue(styleTab.waitForExistence(timeout: 3))
        styleTab.click()

        var save = element("saveNamedStyleButton")
        if !save.waitForExistence(timeout: 2) {
            save = app.buttons["Save as Style…"]
        }
        XCTAssertTrue(save.waitForExistence(timeout: 3), "Save as Style button")
        if !save.isHittable {
            app.scrollViews.firstMatch.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        save.click()
        let field = element("newStyleNameField")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("urgent")
        element("confirmSaveStyle").click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        XCTAssertTrue(html.contains("named-styles"),
                      "the named-styles section must persist")
        XCTAssertTrue(html.contains("data-name=\"urgent\""),
                      "the custom style 'urgent' must persist")
    }

    /// The Icons page shows the full categorized catalog (96 icons across 8
    /// categories) and toggling one persists to the map.
    func testInspectorIconsPageCatalog() throws {
        focusCanvasWithSelection()

        let iconsTab = app.radioButtons["Icons"]
        XCTAssertTrue(iconsTab.waitForExistence(timeout: 3), "inspector tabs should exist")
        iconsTab.click()
        let page = element("inspectorIconsPage")
        XCTAssertTrue(page.waitForExistence(timeout: 3), "icons page should appear")

        // Categorized grid: ~96 toggle buttons.
        let buttons = page.descendants(matching: .button)
        XCTAssertGreaterThanOrEqual(buttons.count, 90,
                                     "the expanded catalog should offer ~96 icons")

        // Toggle one and verify persistence.
        buttons.firstMatch.click()
        XCTAssertTrue(
            waitForScratchMap { $0.contains("data-icons=") },
            "a toggled icon must persist"
        )
    }

    /// Node colors are sticky too: picking a fill in the inspector makes
    /// subsequently inserted nodes (⌘T) inherit it.
    func testNodeFillColorStickyForNewNodes() throws {
        focusCanvasWithSelection() // a fresh child node is selected

        // Give the selected node a fill via the Style page's picker.
        let styleTab = app.radioButtons["Style"]
        XCTAssertTrue(styleTab.waitForExistence(timeout: 3), "inspector tabs should exist")
        styleTab.click()
        let fill = element("inspectorFillColor")
        XCTAssertTrue(fill.waitForExistence(timeout: 3), "inspector fill picker")
        fill.click()
        let swatch = element("inspectorFillColor-#FFD1E8")
        XCTAssertTrue(swatch.waitForExistence(timeout: 3), "palette should offer pink")
        swatch.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        // Insert a child — it must inherit the fill.
        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        let hits = html.components(separatedBy: "data-fill-color=\"#FFD1E8\"").count - 1
        XCTAssertGreaterThanOrEqual(hits, 2,
            "the styled node AND the new ⌘T child must both carry the sticky fill")
    }

    /// Board tool shortcuts (Photoshop conventions): V/B/H/E/T switch
    /// tools, U cycles the shape library (first press from a non-shape tool
    /// lands on Rectangle). Must not fire while a text session is open.
    func testSketchToolShortcuts() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        func assertTool(_ id: String, _ label: String) {
            XCTAssertTrue(element(id).isSelected, "\(label) should be the active tool")
        }

        app.typeKey(.init("e"), modifierFlags: [])
        assertTool("sketchToolEraser", "E → eraser")
        app.typeKey(.init("h"), modifierFlags: [])
        assertTool("sketchToolMarker", "H → marker")
        app.typeKey(.init("b"), modifierFlags: [])
        assertTool("sketchToolPen", "B → pen")
        app.typeKey(.init("t"), modifierFlags: [])
        assertTool("sketchToolText", "T → text")
        app.typeKey(.init("v"), modifierFlags: [])
        assertTool("sketchToolSelect", "V → select")

        // U from select lands on Rectangle (first shape); another U → Line.
        app.typeKey(.init("u"), modifierFlags: [])
        let menu = element("sketchShapesMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // Letters must NOT switch tools while a text session is open.
        app.typeKey(.init("t"), modifierFlags: [])
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.6)).click()
        let textEditor = element("sketchTextEditor")
        XCTAssertTrue(textEditor.waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)) // focus lands async
        textEditor.click()
        app.typeKey(.init("v"), modifierFlags: [])
        app.typeKey(.init("e"), modifierFlags: [])
        app.typeKey(.init("h"), modifierFlags: [])
        app.typeKey(.init("b"), modifierFlags: [])
        app.typeKey(.init("u"), modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        // TextEditor exposes no AX value — commit and verify the payload.
        element("sketchTextCommit").click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(textEditor.exists, "OK must close the session")
        app.typeKey(.escape, modifierFlags: []) // close the board
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        let matches = html.matches(of: #/<div class="node-sketch-texts" hidden="hidden">([A-Za-z0-9+/=]+)<\/div>/#)
        var lettersLanded = false
        for match in matches {
            guard let data = Data(base64Encoded: String(match.output.1)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }
            if json.contains(where: { ($0["text"] as? String)?.contains("vehbu") == true }) {
                lettersLanded = true
            }
        }
        XCTAssertTrue(lettersLanded,
                      "letters must go into the text field, not the tools")
    }

    /// Shape labels (PPT-style): text tool click on a shape edits its centered
    /// label; commit persists text + font and grows the frame to fit.
    func testSketchShapeLabelCommit() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        app.activate() // another app (browser) can steal focus mid-test
        let menu = element("sketchShapesMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.click()
        let rectItem = app.menuItems["Rectangle"]
        XCTAssertTrue(rectItem.waitForExistence(timeout: 3))
        rectItem.click()
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce

        // Text tool click INSIDE the rect → label editor.
        element("sketchToolText").click()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.6)).click()
        let labelEditor = element("sketchTextEditor")
        XCTAssertTrue(labelEditor.waitForExistence(timeout: 3),
                      "text tool on a shape should open the label editor")
        app.typeText("start here")
        element("sketchTextCommit").click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(labelEditor.exists)

        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let shapes = try decodePersistedShapes()
        let labeled = shapes.first {
            ($0["text"] as? String)?.contains("start here") == true && $0["kind"] as? String == "rect"
        }
        XCTAssertNotNil(labeled, "the rect label must persist on the shape")
        XCTAssertEqual(labeled?["fontFamily"] as? String, "Helvetica")
        XCTAssertGreaterThanOrEqual(labeled?["fontSize"] as? Double ?? 0, 12)
    }

    /// Decode every persisted node-sketch-shapes payload on the scratch map.
    func decodePersistedShapes() throws -> [[String: Any]] {
        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        let matches = html.matches(of: #/<div class="node-sketch-shapes" hidden="hidden">([A-Za-z0-9+/=]+)<\/div>/#)
        var all: [[String: Any]] = []
        for match in matches {
            guard let data = Data(base64Encoded: String(match.output.1)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }
            all.append(contentsOf: json)
        }
        return all
    }

    /// 1.2 Freeform parity: the marker commits PKInk(.marker) strokes.
    func testSketchMarkerInkCommits() throws {
        focusCanvasWithSelection()
        app.typeKey(.init("d"), modifierFlags: [])
        let editor = element("sketchEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        element("sketchToolMarker").click()

        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        RunLoop.current.run(until: Date().addingTimeInterval(2.5)) // autosave
        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        // Scan EVERY sketch payload — the scratch map may carry nodes from
        // earlier runs, and document order is not draw order.
        let matches = html.matches(of: #/<div class="node-sketch" hidden="hidden">([^|<]+)\|([0-9.]+)\|([0-9.]+)<\/div>/#)
        var markerFound = false
        for match in matches {
            guard let data = Data(base64Encoded: String(match.output.1)),
                  let drawing = try? PKDrawing(data: data) else { continue }
            if drawing.strokes.contains(where: { $0.ink.inkType == .marker }) {
                markerFound = true
            }
        }
        XCTAssertTrue(markerFound, "the marker tool must commit a marker-ink stroke")
    }

    /// Moving a shape with the select tool keeps its geometry by
    /// construction (model element — the frame translates, nothing resamples).
    /// Assert the frame actually moved and the kind survives.
    func testSketchMoveKeepsShapeGeometry() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        let menu = element("sketchShapesMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.click()
        let starItem = app.menuItems["Star"]
        XCTAssertTrue(starItem.waitForExistence(timeout: 3))
        starItem.click()

        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce

        // Anchor element: trim normalizes the CONTENT UNION to the padding
        // origin on every commit, so a single-element board would hide the
        // move in absolute coordinates. The anchor at the far left pins the
        // union origin, making the star's rightward move observable in x.
        app.activate() // focus can be stolen between gestures
        let menuAnchor = element("sketchShapesMenu")
        XCTAssertTrue(menuAnchor.waitForExistence(timeout: 3))
        menuAnchor.click()
        let anchorItem = app.menuItems["Rectangle"]
        XCTAssertTrue(anchorItem.waitForExistence(timeout: 3))
        anchorItem.click()
        let anchorStart = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let anchorEnd = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.56))
        anchorStart.press(forDuration: 0.05, thenDragTo: anchorEnd)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce

        // Select the star (tap its center), then drag it aside. Re-activate:
        // a browser window can steal focus mid-test and swallow the clicks.
        app.activate()
        element("sketchToolSelect").click()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let from = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let to = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.68))
        from.press(forDuration: 0.05, thenDragTo: to)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce commit
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let shapes = try decodePersistedShapes()
        let star = shapes.first { $0["kind"] as? String == "star" }
        XCTAssertNotNil(star, "a star must persist")
        // The star moved ~0.12 board-widths right of its draw position; with
        // the anchor pinning the union origin, x must clearly exceed the
        // anchor band (~pad 8 + anchor ~110pt).
        let x = star?["x"] as? Double ?? 0
        XCTAssertGreaterThan(x, 200, "the star's frame should have moved right (got \(x))")
    }

    /// Black ink must STAY black: PKDrawing.image() misreads grayscale
    /// catalog colors (.black/.white) — the gray channel becomes alpha, so
    /// black strokes vanished and white strokes rendered black. Committed
    /// ink colors are converted to sRGB; assert the persisted stroke's ink.
    func testSketchBlackInkStaysBlack() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        element("sketchInk").click() // foreground picker
        let blackSwatch = element("sketchInk-#000000")
        XCTAssertTrue(blackSwatch.waitForExistence(timeout: 3), "palette should offer black")
        blackSwatch.click()
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        let matches = html.matches(of: #/<div class="node-sketch" hidden="hidden">([^|<]+)\|([0-9.]+)\|([0-9.]+)<\/div>/#)
        var blackStrokeFound = false
        for match in matches {
            guard let data = Data(base64Encoded: String(match.output.1)),
                  let drawing = try? PKDrawing(data: data) else { continue }
            for stroke in drawing.strokes {
                let color = stroke.ink.color
                guard let rgb = color.usingColorSpace(.sRGB) else { continue }
                if rgb.redComponent < 0.05, rgb.greenComponent < 0.05, rgb.blueComponent < 0.05,
                   rgb.alphaComponent > 0.9 {
                    blackStrokeFound = true
                }
            }
        }
        XCTAssertTrue(blackStrokeFound, "a black-ink stroke must persist as opaque sRGB black")
    }

    /// 1.2 Freeform parity: the shapes browser offers the full library and
    /// each pick persists a MODEL shape of the right kind.
    func testSketchShapesMenuLibrary() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        func pickShape(_ title: String) {
            let menu = element("sketchShapesMenu")
            XCTAssertTrue(menu.waitForExistence(timeout: 2), "shapes menu button")
            menu.click()
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "menu should offer \(title)")
            item.click()
        }

        func draw() {
            let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.85))
            start.press(forDuration: 0.05, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce
        }

        pickShape("Triangle")
        draw()
        pickShape("Star")
        draw()
        pickShape("Rounded Rectangle")
        draw()
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let shapes = try decodePersistedShapes()
        for kind in ["triangle", "star", "roundedRect"] {
            XCTAssertTrue(
                shapes.contains { $0["kind"] as? String == kind },
                "the shapes library must persist a \(kind) element"
            )
        }
    }

    /// 1.2 Freeform parity: text boxes and sticky notes commit to the model
    /// (node-sketch-texts payload) and reopen with the editor.
    func testSketchTextAndStickyCommit() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        element("sketchToolText").click()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.6)).click()
        let textEditor = element("sketchTextEditor")
        XCTAssertTrue(textEditor.waitForExistence(timeout: 3), "text tool click opens the editor")
        app.typeText("board note")

        // Sticky: give it the yellow background via the color picker popover.
        let sticky = element("sketchTextSticky")
        XCTAssertTrue(sticky.waitForExistence(timeout: 3), "sticky control should exist")
        sticky.click()
        let yellow = element("sketchTextSticky-#FFF685")
        XCTAssertTrue(yellow.waitForExistence(timeout: 3), "palette should offer yellow")
        yellow.click()
        element("sketchTextCommit").click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(textEditor.exists, "OK must close the text editor")

        // Committed element is on the board; close the sketch editor (commit).
        let committed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sketchText-'")).firstMatch
        XCTAssertTrue(committed.waitForExistence(timeout: 3), "committed text should render")
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        let html = try String(contentsOfFile: scratch, encoding: .utf8)
        guard let match = html.firstMatch(
            of: #/<div class="node-sketch-texts" hidden="hidden">([A-Za-z0-9+/=]+)<\/div>/#
        ), let data = Data(base64Encoded: String(match.output.1)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("node-sketch-texts payload should persist"); return
        }
        let element = json.first {
            ($0["text"] as? String)?.contains("board note") == true
        }
        XCTAssertNotNil(element, "the typed text must be persisted")
        XCTAssertEqual(element?["background"] as? String, "#FFF685", "sticky background must persist")
        XCTAssertEqual(element?["fontFamily"] as? String, "Helvetica", "default font must persist")
    }

    /// Picking an ink color must NOT kick the active shape tool back to the
    /// pen — draw a red ellipse next, not a red scribble. Verified
    /// behaviorally: pick Ellipse from the shapes menu, change ink, draw —
    /// the committed stroke must still be a true ellipse.
    func testSketchInkSelectionKeepsShapeTool() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")
        app.typeKey(.init("d"), modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        let menu = element("sketchShapesMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.click()
        let ellipseItem = app.menuItems["Ellipse"]
        XCTAssertTrue(ellipseItem.waitForExistence(timeout: 3))
        ellipseItem.click()

        // Change ink to red via the foreground picker (deterministic hex).
        element("sketchInk").click()
        let redSwatch = element("sketchInk-#FF6B6B")
        XCTAssertTrue(redSwatch.waitForExistence(timeout: 3), "palette should offer red")
        redSwatch.click()

        // Draw: if the ink pick had kicked the tool back to pen, this would
        // commit a scribble instead of a shape element.
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce
        app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // autosave

        let shapes = try decodePersistedShapes()
        // systemRed resolves differently per appearance/process
        // (#FF0000 light / #FF9230 dark) — assert the ink APPLIED (no longer
        // the default black) on an ellipse element.
        let ellipse = shapes.first {
            $0["kind"] as? String == "ellipse"
                && ($0["strokeColor"] as? String)?.uppercased() == "#FF6B6B"
        }
        XCTAssertNotNil(ellipse,
                        "after a red-ink pick the ellipse tool must still draw a red ellipse")
        XCTAssertGreaterThanOrEqual(ellipse?["width"] as? Double ?? 0, 40)
    }

    /// Min distance from a point to a rect's boundary (nearest edge distance
    /// if inside, nearest edge segment if outside).
    static func distance(from p: CGPoint, toPerimeterOf r: CGRect) -> CGFloat {
        if r.contains(p) {
            return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
        }
        let corners = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.minX, y: r.minY),
        ]
        var best = CGFloat.greatestFiniteMagnitude
        for (a, b) in zip(corners, corners.dropFirst()) {
            let abx = b.x - a.x, aby = b.y - a.y
            let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / (abx * abx + aby * aby), 0), 1)
            let closest = CGPoint(x: a.x + abx * t, y: a.y + aby * t)
            best = min(best, hypot(p.x - closest.x, p.y - closest.y))
        }
        return best
    }

    /// Regression: strokes from EVERY editing session must survive commit.
    /// macOS PencilKit corrupts composed PKStroke transforms on encode —
    /// the old re-center-on-open path scattered earlier strokes, so the
    /// second commit persisted only the newest ones (and thumbnails lost
    /// content). Draw in two separate sessions, then decode the persisted
    /// payload: both strokes present, bounds origin-normalized.
    func testSketchTwoSessionsKeepAllStrokes() throws {
        focusCanvasWithSelection()
        let editor = element("sketchEditor")

        func drawStroke(_ from: CGVector, _ to: CGVector) {
            app.typeKey(.init("d"), modifierFlags: [])
            XCTAssertTrue(editor.waitForExistence(timeout: 3), "sketch editor should open")
            // Editor-relative coordinates: the board is clamped into the
            // viewport (not always window-centered), so window-relative
            // drags can miss it entirely.
            let start = editor.coordinate(withNormalizedOffset: from)
            let end = editor.coordinate(withNormalizedOffset: to)
            start.press(forDuration: 0.05, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // debounce commit
            let undo = element("sketchUndo")
            XCTAssertTrue(undo.exists && undo.isEnabled, "drag should record a stroke")
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertFalse(editor.exists)
        }

        drawStroke(CGVector(dx: 0.25, dy: 0.4), CGVector(dx: 0.4, dy: 0.6))
        drawStroke(CGVector(dx: 0.55, dy: 0.4), CGVector(dx: 0.7, dy: 0.6))

        // Autosave is debounced; then read the scratch map from the app
        // container's tmp (this runner is unsandboxed by entitlement).
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let scratch = NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac.dev/Data/tmp/uitesting.swiftmind.html"
        guard let html = try? String(contentsOfFile: scratch, encoding: .utf8),
              let match = html.firstMatch(
                  of: #/<div class="node-sketch" hidden="hidden">([^|<]+)\|([0-9.]+)\|([0-9.]+)<\/div>/#
              ) else {
            XCTFail("scratch map should contain a committed sketch payload")
            return
        }
        let (_, base64, width, height) = match.output
        guard let data = Data(base64Encoded: String(base64)),
              let drawing = try? PKDrawing(data: data) else {
            XCTFail("sketch payload should decode as PKDrawing")
            return
        }
        XCTAssertEqual(drawing.strokes.count, 2, "both sessions' strokes must persist")
        XCTAssertGreaterThanOrEqual(drawing.bounds.minX, 0, "trim must keep content origin-normalized")
        XCTAssertGreaterThanOrEqual(drawing.bounds.minY, 0, "trim must keep content origin-normalized")
        XCTAssertLessThan(drawing.bounds.maxX, (Double(width) ?? 0) + 1)
        XCTAssertLessThan(drawing.bounds.maxY, (Double(height) ?? 0) + 1)
    }
}


    // MARK: - Input source helper

/// Switches the keyboard to a plain ASCII layout while UI tests run so
/// synthesized English keystrokes are not intercepted by a CJK input
/// method's composition buffer.
enum InputSourceHelper {
    /// Selects ABC (or U.S.) and returns the source to restore, if any.
    static func selectASCII() -> TISInputSource? {
        let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        for identifier in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            let criteria = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
            guard let list = TISCreateInputSourceList(criteria, false)?
                .takeRetainedValue() as? [TISInputSource],
                let source = list.first else { continue }
            if TISSelectInputSource(source) == noErr {
                return previous
            }
        }
        return nil
    }

    static func restore(_ source: TISInputSource?) {
        guard let source else { return }
        TISSelectInputSource(source)
    }
}
