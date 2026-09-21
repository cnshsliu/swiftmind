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
        let pickerLabel = app.descendants(matching: .any)["On launch, open:"]
        XCTAssertTrue(
            pickerLabel.waitForExistence(timeout: 4),
            "⌘, should open Settings with the launch-behavior picker"
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
        if card.waitForExistence(timeout: 3) { card.click() }
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
