import XCTest

/// macOS UI smoke tests (XCUITest — built into Xcode).
///
/// Goal: catch “app won’t open / shortcuts broken / chrome missing”
/// without manual click-through. Canvas geometry is covered by unit tests.
final class SwiftMindMacUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "app.swiftmind.mac.dev")
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
            let digits = text.compactMap(\.wholeNumberValue).prefix(1)
            return digits.first ?? 0
        }

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
}
