# Agent Live Bridge (v2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let external agents operate the live SwiftMind app session — undoable edits, formula results, session introspection — via `swiftmind mcp` (stdio MCP) bridged over a Unix domain socket, with zero network entitlements.

**Architecture:** `agent framework --stdio/MCP--> swiftmind mcp (CLI) --UDS--> AgentBridge (app) --> CompositeAgentCommand (one undo step)`. Spec: `docs/superpowers/specs/2026-09-03-agent-live-bridge-design.md`.

**Tech Stack:** Swift 5.10, Foundation only (POSIX sockets via Darwin), JSON-RPC 2.0 / MCP protocolVersion `2025-06-18`. No new dependencies, no new entitlements.

**Key context:**
- `MapOp`/`BatchOps`/`BatchOpError` live in `Sources/SwiftMindCore/Automation/BatchOps.swift`.
- CLI: `Sources/SwiftMindCLI/{main,MapFile,WriteCommands}.swift`; version constant `swiftmindCLIVersion` in `main.swift` (currently `"1.1.0"`).
- App: single `AppModel` (`Apps/SwiftMindMac/SwiftMindMac/AppModel.swift`) owning one `DocumentSession` (`DocumentSession.swift`); `MapStore.formulaResults() -> [NodeID: FormulaValue]`; `FormulaValue.displayText`.
- Container paths (bundle id `app.swiftmind.mac`): socket dir = `~/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind/` (NOT `Library/Application Support/...` — the longer path risks the 104-byte `sockaddr_un.sun_path` limit; spec §2 is amended accordingly in Task 5).
- After any core change: `swift test`. After any app change: `./scripts/rerun-mac.sh`. CLI smoke: `./scripts/test-cli.sh`.

---

### Task 1: Expose `MapOp.command(in:)` + `affectedIDs` (core refactor)

**Files:**
- Modify: `Sources/SwiftMindCore/Automation/BatchOps.swift`
- Test: `Tests/SwiftMindCoreTests/BatchOpsTests.swift` (existing file; append)

- [ ] **Step 1: Write the failing test**

Append to `BatchOpsTests.swift`:

```swift
    /// command(in:) must produce the same effect as BatchOps.apply.
    func testCommandInMatchesApply() throws {
        var viaApply = Self.makeMap()
        var viaCommand = Self.makeMap()
        let ops: [MapOp] = [
            .addChild(parentID: Self.rootID, newNodeID: NodeID(rawValue: "n_new"), text: "New", side: .auto),
            .setText(nodeID: Self.rootID, text: "Renamed"),
            .setNote(nodeID: Self.rootID, markdown: "note"),
            .setAttribute(nodeID: Self.rootID, name: "status", value: "done"),
            .setAttribute(nodeID: Self.rootID, name: "status", value: ""), // removal path
            .setFormula(nodeID: Self.rootID, formula: "count(children)"),
            .setFolded(nodeID: Self.rootID, isFolded: true),
            .setPin(nodeID: Self.rootID, position: Point2D(x: 1, y: 2)),
            .delete(nodeIDs: ["n_new"]),
        ]
        try BatchOps.apply(ops, to: &viaApply)
        for op in ops {
            try op.command(in: viaCommand).execute(on: &viaCommand)
        }
        XCTAssertEqual(viaApply, viaCommand)
        XCTAssertEqual(ops[0].affectedIDs, [NodeID(rawValue: "n_new")])
        XCTAssertEqual(ops[1].affectedIDs, [Self.rootID])
        XCTAssertEqual(ops[8].affectedIDs, [NodeID(rawValue: "n_new")])
    }
```

Check the top of `BatchOpsTests.swift` for the existing map-fixture helper; if it is not named `makeMap()`/`rootID`, adapt the test to the existing helpers. If `MindMap` is not `Equatable`-comparable across these paths (it is — `MindMap: Equatable`), keep as written.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BatchOpsTests/testCommandInMatchesApply`
Expected: FAIL — `command(in:)` and `affectedIDs` do not exist (compile error).

- [ ] **Step 3: Refactor `BatchOps`**

In `Sources/SwiftMindCore/Automation/BatchOps.swift`, replace `applyOne` with an extension on `MapOp` plus a thin `applyOne`:

```swift
extension MapOp {
    /// Ids this op touches, in order (used for the CLI's `affected` response).
    public var affectedIDs: [NodeID] {
        switch self {
        case .addChild(_, let newNodeID, _, _): return [newNodeID]
        case .addSibling(_, let newNodeID, _): return [newNodeID]
        case .setText(let id, _), .setNote(let id, _), .setAttribute(let id, _, _),
             .setFormula(let id, _), .setFolded(let id, _), .setPin(let id, _):
            return [id]
        case .move(let id, _, _): return [id]
        case .delete(let ids): return ids
        }
    }

    /// Build the underlying command. `map` is only read, for ops whose
    /// command needs current state (attribute removal).
    public func command(in map: MindMap) throws -> any MapCommand {
        switch self {
        case let .addChild(parentID, newNodeID, text, side):
            return InsertChildCommand(parentID: parentID, newNodeID: newNodeID, text: text, side: side)
        case let .addSibling(siblingID, newNodeID, text):
            return InsertSiblingCommand(siblingID: siblingID, newNodeID: newNodeID, text: text)
        case let .setText(nodeID, text):
            return SetTextCommand(nodeID: nodeID, newText: text)
        case let .setNote(nodeID, markdown):
            return SetNoteCommand(nodeID: nodeID, noteMarkdown: markdown)
        case let .setAttribute(nodeID, name, value):
            if value.isEmpty {
                guard let node = map.node(id: nodeID) else {
                    throw MapCommandError.nodeNotFound(nodeID)
                }
                let remaining = node.attributes.filter { $0.name != name }
                return SetAttributesCommand(nodeID: nodeID, attributes: remaining)
            }
            return UpsertAttributeCommand(nodeID: nodeID, attribute: NodeAttribute(name: name, value: value))
        case let .setFormula(nodeID, formula):
            let normalized = (formula ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return SetFormulaCommand(nodeID: nodeID, formula: normalized.isEmpty ? nil : normalized)
        case let .setFolded(nodeID, isFolded):
            return SetFoldedCommand(nodeID: nodeID, isFolded: isFolded)
        case let .setPin(nodeID, position):
            return SetPinCommand(nodeID: nodeID, positionPin: position)
        case let .move(nodeID, newParentID, index):
            return MoveNodeCommand(nodeID: nodeID, newParentID: newParentID, index: index)
        case let .delete(nodeIDs):
            return DeleteNodesCommand(nodeIDs: nodeIDs)
        }
    }
}
```

And in `BatchOps`, `applyOne` becomes:

```swift
    private static func applyOne(_ op: MapOp, to map: inout MindMap) throws -> [NodeID] {
        try op.command(in: map).execute(on: &map)
        return op.affectedIDs
    }
```

Check `UpsertAttributeCommand` exists with that exact initializer — it is used by the current `applyOne`; if the real name differs, keep the current call as-is.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: all pass (203 + 1 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Automation/BatchOps.swift Tests/SwiftMindCoreTests/BatchOpsTests.swift
git commit -m "core: expose MapOp.command(in:) and affectedIDs for the live bridge"
```

---

### Task 2: `CompositeAgentCommand` (core)

**Files:**
- Create: `Sources/SwiftMindCore/Commands/CompositeAgentCommand.swift`
- Test: `Tests/SwiftMindCoreTests/CompositeAgentCommandTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `Tests/SwiftMindCoreTests/CompositeAgentCommandTests.swift`:

```swift
import XCTest
@testable import SwiftMindCore

final class CompositeAgentCommandTests: XCTestCase {
    private var map: MindMap!

    override func setUp() {
        map = MindMap.makeEmpty(title: "T")
    }

    private var rootID: NodeID { map.root.id }

    func testExecutesAllOpsAndCollectsAffected() throws {
        let command = CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_2"), text: "Two", side: .auto),
            .setText(nodeID: rootID, text: "Renamed"),
        ])
        try command.execute(on: &map)
        XCTAssertEqual(map.root.children.count, 2)
        XCTAssertEqual(map.root.text, "Renamed")
        XCTAssertEqual(command.affected, [NodeID(rawValue: "n_1"), NodeID(rawValue: "n_2"), rootID])
    }

    func testFailureRollsBackAndThrowsBatchOpError() throws {
        let original = map!
        let command = CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .setText(nodeID: NodeID(rawValue: "n_ghost"), text: "boom"),
        ])
        XCTAssertThrowsError(try command.execute(on: &map)) { error in
            guard let batchError = error as? BatchOpError else {
                return XCTFail("expected BatchOpError, got \(error)")
            }
            XCTAssertEqual(batchError.opIndex, 1)
            XCTAssertEqual(batchError.opName, "set-text")
            XCTAssertTrue(batchError.message.contains("n_ghost"))
        }
        XCTAssertEqual(map, original, "failed batch must leave the map untouched")
    }

    func testUndoReversesWholeBatch() throws {
        let original = map!
        let command = CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .setText(nodeID: rootID, text: "Renamed"),
        ])
        try command.execute(on: &map)
        try command.undo(on: &map)
        XCTAssertEqual(map, original)
    }

    func testStoreDispatchIsOneUndoStep() throws {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let original = store.map
        let rootID = store.map.root.id
        try store.dispatch(CompositeAgentCommand(ops: [
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_1"), text: "One", side: .auto),
            .addChild(parentID: rootID, newNodeID: NodeID(rawValue: "n_2"), text: "Two", side: .auto),
        ]))
        XCTAssertEqual(store.map.root.children.count, 2)
        try store.undo()
        XCTAssertEqual(store.map, original)
        XCTAssertFalse(store.canUndo)
        try store.redo()
        XCTAssertEqual(store.map.root.children.count, 2)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CompositeAgentCommandTests`
Expected: FAIL — type does not exist (compile error).

- [ ] **Step 3: Implement**

Create `Sources/SwiftMindCore/Commands/CompositeAgentCommand.swift`:

```swift
/// Applies a batch of agent-authored ops as ONE undoable step.
/// Execute-time rollback: if any op fails, already-executed ops are undone
/// in reverse and the map is left untouched (same guarantee as BatchOps).
public final class CompositeAgentCommand: MapCommand {
    public let name = "AgentEdit"
    public let ops: [MapOp]

    /// Ids touched by the last successful execute, in op order.
    public private(set) var affected: [NodeID] = []

    private var executed: [any MapCommand] = []

    public init(ops: [MapOp]) {
        self.ops = ops
    }

    public func execute(on map: inout MindMap) throws {
        executed = []
        affected = []
        for (index, op) in ops.enumerated() {
            let command = try op.command(in: map)
            do {
                try command.execute(on: &map)
            } catch {
                for past in executed.reversed() {
                    try? past.undo(on: &map)
                }
                executed = []
                throw BatchOpError(
                    opIndex: index,
                    opName: op.name,
                    message: String(describing: error)
                )
            }
            executed.append(command)
            affected.append(contentsOf: op.affectedIDs)
        }
    }

    public func undo(on map: inout MindMap) throws {
        for command in executed.reversed() {
            try command.undo(on: &map)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Commands/CompositeAgentCommand.swift Tests/SwiftMindCoreTests/CompositeAgentCommandTests.swift
git commit -m "core: CompositeAgentCommand — agent batches as one undoable step with rollback"
```

---

### Task 3: Shared map JSON in core (`AgentProtocol`)

The bridge's `read` must return the CLI `read` shape plus computed formula
values. That JSON builder currently lives in the CLI target
(`Sources/SwiftMindCLI/MapFile.swift`, `jsonObject(for:)`/`nodeJSON`) — move
it to core so both targets share it.

**Files:**
- Create: `Sources/SwiftMindCore/Automation/AgentProtocol.swift`
- Modify: `Sources/SwiftMindCLI/MapFile.swift`
- Test: `Tests/SwiftMindCoreTests/AgentProtocolTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/SwiftMindCoreTests/AgentProtocolTests.swift`:

```swift
import XCTest
@testable import SwiftMindCore

final class AgentProtocolTests: XCTestCase {
    func testMapJSONMergesFormulaResults() throws {
        var map = MindMap.makeEmpty(title: "T")
        let child = NodeID(rawValue: "n_c")
        try InsertChildCommand(parentID: map.root.id, newNodeID: child, text: "C", side: .auto)
            .execute(on: &map)
        try SetFormulaCommand(nodeID: map.root.id, formula: "count(children)").execute(on: &map)

        let results: [NodeID: FormulaValue] = [map.root.id: .number(1)]
        let json = AgentProtocol.mapJSON(for: map, formulaResults: results)
        let root = try XCTUnwrap(json["root"] as? [String: Any])
        XCTAssertEqual(root["formula"] as? String, "count(children)")
        XCTAssertEqual(root["formulaResult"] as? String, "1")
        let children = try XCTUnwrap(root["children"] as? [[String: Any]])
        XCTAssertEqual(children.first?["id"] as? String, "n_c")
        XCTAssertEqual(json["title"] as? String, "T")
    }

    func testMapJSONWithoutFormulasOmitsFormulaResult() {
        let map = MindMap.makeEmpty(title: "T")
        let json = AgentProtocol.mapJSON(for: map)
        let root = json["root"] as? [String: Any]
        XCTAssertNil(root?["formulaResult"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter AgentProtocolTests`
Expected: FAIL — `AgentProtocol` does not exist.

- [ ] **Step 3: Implement core side**

Create `Sources/SwiftMindCore/Automation/AgentProtocol.swift`:

```swift
import Foundation

/// Shared JSON tree shape for the CLI `read` command and the app bridge's
/// `read` method. When formula results are provided (live session only),
/// each formula node also carries its computed `formulaResult` display text.
public enum AgentProtocol {
    public static func mapJSON(
        for map: MindMap,
        formulaResults: [NodeID: FormulaValue] = [:]
    ) -> [String: Any] {
        [
            "id": map.id,
            "title": map.title,
            "schemaVersion": map.schemaVersion,
            "root": nodeJSON(map.root, formulaResults: formulaResults),
        ]
    }

    private static func nodeJSON(
        _ node: Node,
        formulaResults: [NodeID: FormulaValue]
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": node.id.rawValue,
            "text": node.text,
        ]
        if !node.noteMarkdown.isEmpty { dict["note"] = node.noteMarkdown }
        if !node.attributes.isEmpty {
            dict["attributes"] = node.attributes.map { ["name": $0.name, "value": $0.value] }
        }
        if let formula = node.formula {
            dict["formula"] = formula
            if let result = formulaResults[node.id] {
                dict["formulaResult"] = result.displayText
            }
        }
        if node.isFolded { dict["folded"] = true }
        if node.side != .auto { dict["side"] = node.side.rawValue }
        if node.positionPin != nil { dict["pinned"] = true }
        if !node.children.isEmpty {
            dict["children"] = node.children.map { nodeJSON($0, formulaResults: formulaResults) }
        }
        return dict
    }
}
```

- [ ] **Step 4: Adopt in the CLI**

In `Sources/SwiftMindCLI/MapFile.swift`, replace the whole `jsonObject(for:)`
and private `nodeJSON(_:)` with:

```swift
    /// JSON tree for `read` (file mode: no computed formula values).
    static func jsonObject(for map: MindMap) -> [String: Any] {
        AgentProtocol.mapJSON(for: map)
    }
```

- [ ] **Step 5: Run tests + CLI smoke**

Run: `swift test && ./scripts/test-cli.sh`
Expected: all pass; smoke OK (read output unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/SwiftMindCore/Automation/AgentProtocol.swift Sources/SwiftMindCLI/MapFile.swift Tests/SwiftMindCoreTests/AgentProtocolTests.swift
git commit -m "core: shared map JSON builder (AgentProtocol) with formula results"
```

---

### Task 4: `swiftmind new` (file mode) + version 1.2.0

**Files:**
- Modify: `Sources/SwiftMindCLI/main.swift`
- Modify: `Sources/SwiftMindCLI/MapFile.swift`
- Modify: `scripts/test-cli.sh`

- [ ] **Step 1: Add smoke coverage first**

In `scripts/test-cli.sh`, insert before the final `echo "CLI smoke test OK"`:

```bash
# new: creates a map, refuses to overwrite
NEWF="$(mktemp -d)/fresh.swiftmind.html"
"$CLI" new "$NEWF" --title "Fresh" >/dev/null || fail "new"
"$CLI" validate "$NEWF" >/dev/null || fail "new output validates"
"$CLI" read "$NEWF" | grep -q '"Fresh"' || fail "new title"
if "$CLI" new "$NEWF" 2>/dev/null; then
  fail "new on existing file should exit non-zero"
fi
```

(The `mcp` assertions belong to Task 6 — do NOT add them here; Task 6 adds
that block and makes it pass.)

- [ ] **Step 2: Run smoke to verify `new` fails**

Run: `./scripts/test-cli.sh`
Expected: FAIL at `new` — unknown command.

- [ ] **Step 3: Implement `new`**

In `Sources/SwiftMindCLI/main.swift`:

Bump the version constant: `let swiftmindCLIVersion = "1.2.0"`.

Add to the usage text, after the `validate` line:

```
      new <file> [--title <t>]         create an empty map file (fails if it exists)
```

Add a `case` in the main `switch command`, before `default:`:

```swift
    case "new":
        let title = flags["title"] ?? "Untitled"
        try MapFile.create(path, title: title)
        MapFile.printJSON(["ok": true, "file": path])
```

In `Sources/SwiftMindCLI/MapFile.swift`, add:

```swift
    /// Create an empty map file; refuses to overwrite an existing file.
    static func create(_ path: String, title: String) throws {
        let url = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.file("file exists: \(path)")
        }
        let map = MindMap.makeEmpty(title: title)
        do {
            let html = try HTMLCodec.encode(map, includeSkin: true)
            try Data(html.utf8).write(to: url, options: .atomic)
        } catch {
            throw CLIError.file("cannot create \(path): \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 4: Run tests + smoke**

Run: `swift test && ./scripts/test-cli.sh`
Expected: all pass; `new` checks green.

- [ ] **Step 5: Reinstall + commit**

```bash
./scripts/install-cli.sh
git add Sources/SwiftMindCLI/main.swift Sources/SwiftMindCLI/MapFile.swift scripts/test-cli.sh
git commit -m "CLI: swiftmind new (1.2.0) — agents can bootstrap map files"
```

---

### Task 5: `AgentBridge` — UDS server in the app

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/AgentBridge.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/AppModel.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift` (add `applyThrowing`)
- Modify: `docs/superpowers/specs/2026-09-03-agent-live-bridge-design.md` (amend socket path)

- [ ] **Step 0: Amend the spec's socket path**

In the spec §2, replace the socket location paragraph with:

```
- Socket location (inside the sandbox container, writable under the existing
  entitlements): `~/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind/agent.sock`
  — deliberately NOT `Library/Application Support/...`: with a long username
  that path exceeds the 104-byte `sockaddr_un.sun_path` limit. If `bind`
  fails with `ENAMETOOLONG`, the bridge logs and disables itself.
```

- [ ] **Step 1: `applyThrowing` on DocumentSession**

In `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift`, after `applyQuiet`, add:

```swift
    /// Bridge path: throws instead of toasting so the caller reports back.
    func applyThrowing(_ command: any MapCommand) throws {
        try store.dispatch(command)
        publishContent()
    }
```

- [ ] **Step 2: `createAndOpenMap(titled:)` on AppModel**

In `Apps/SwiftMindMac/SwiftMindMac/AppModel.swift`, after the existing
`createAndOpenMap(in:)`:

```swift
    /// Bridge path: create a map in the default library with a title; returns
    /// the new file's URL. Used by AgentBridge's `new` method.
    func createAndOpenMap(titled title: String) -> URL? {
        let dir = VaultLibrary.defaultLibraryDirectory
        _ = library.startAccessing(dir)
        let url = VaultLibrary.uniqueMapURL(in: dir, baseName: "Untitled")
        do {
            try VaultLibrary.createEmptyMapIfNeeded(at: url, title: title)
            openMap(at: url)
            return url
        } catch {
            session.showToast("Could not create map: \(error.localizedDescription)", kind: .error)
            return nil
        }
    }
```

- [ ] **Step 3: Implement AgentBridge**

Create `Apps/SwiftMindMac/SwiftMindMac/AgentBridge.swift`:

```swift
import Foundation
import SwiftMindCore

/// Local agent bridge: a Unix-domain-socket server inside the app container.
/// The `swiftmind mcp` CLI process connects here; agents talk MCP over stdio
/// to the CLI. No network, no new entitlements.
/// Spec: docs/superpowers/specs/2026-09-03-agent-live-bridge-design.md
@MainActor
final class AgentBridge {
    /// Bundle id — the CLI derives the container path from this constant.
    /// Keep in sync with `MCPServer.bridgeDirectory` in the CLI target.
    nonisolated static let bundleID = "app.swiftmind.mac"
    nonisolated static let bridgeDirName = "Library/SwiftMind"
    nonisolated static let socketName = "agent.sock"
    nonisolated static let tokenName = "agent.token"
    nonisolated static let maxFrameBytes: UInt32 = 4 * 1024 * 1024

    private let ioQueue = DispatchQueue(label: "app.swiftmind.mac.agent-bridge")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var token = ""
    private weak var appModel: AppModel?

    /// Container-side bridge directory (app view; sandbox-resolved).
    private static func bridgeDirectory() -> URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftMind", isDirectory: true)
    }

    func start(appModel: AppModel) {
        // Kill switch: `defaults write app.swiftmind.mac swiftmind.agentBridge -bool false`
        if let disabled = UserDefaults.standard.object(forKey: "swiftmind.agentBridge") as? Bool,
           !disabled {
            return
        }
        self.appModel = appModel
        token = UUID().uuidString

        let dir = Self.bridgeDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            chmod(dir.path, 0o700)
            let tokenURL = dir.appendingPathComponent(Self.tokenName)
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
            chmod(tokenURL.path, 0o600)
        } catch {
            NSLog("AgentBridge: cannot prepare %@ — bridge disabled", dir.path)
            return
        }

        let socketPath = dir.appendingPathComponent(Self.socketName).path
        unlink(socketPath)  // stale socket from a previous run

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("AgentBridge: socket() failed — bridge disabled")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("AgentBridge: socket path too long — bridge disabled")
            close(listenFD)
            listenFD = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    dest.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, addrLen)
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            NSLog("AgentBridge: bind/listen failed on %@ — bridge disabled", socketPath)
            close(listenFD)
            listenFD = -1
            return
        }
        chmod(socketPath, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler { [listenFD] in
            close(listenFD)
        }
        acceptSource = source
        source.resume()
        NSLog("AgentBridge: listening on %@", socketPath)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        let dir = Self.bridgeDirectory()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.socketName))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.tokenName))
    }

    // MARK: - Connection handling (ioQueue, nonisolated)

    /// One request per connection; the CLI opens a fresh connection per call.
    private nonisolated func acceptOne() {
        let conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        defer { close(conn) }
        guard let requestData = Self.readFrame(conn) else { return }
        let response: [String: Any] = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.handle(requestData)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            Self.writeFrame(conn, data)
        }
    }

    nonisolated private static func readFrame(_ fd: Int32) -> Data? {
        guard let header = readFully(fd, count: 4),
              header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length <= maxFrameBytes else { return nil }
        return readFully(fd, count: Int(length))
    }

    nonisolated private static func readFully(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while data.count < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, min(ptr.count, count - data.count), 0)
            }
            guard n > 0 else { return nil }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    nonisolated private static func writeFrame(_ fd: Int32, _ data: Data) {
        var length = UInt32(data.count).bigEndian
        _ = withUnsafeBytes(of: &length) { send(fd, $0.baseAddress, $0.count, 0) }
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }

    // MARK: - Method dispatch (main actor)

    private func handle(_ requestData: Data) -> [String: Any] {
        let id: Any = (try? JSONSerialization.jsonObject(with: requestData))
            .flatMap { ($0 as? [String: Any])?["id"] } ?? NSNull()
        func failure(_ code: String, _ message: String) -> [String: Any] {
            ["id": id, "ok": false, "error": ["code": code, "message": message]]
        }
        guard let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let method = request["method"] as? String else {
            return failure("usage", "malformed request")
        }
        guard (request["token"] as? String) == token else {
            return failure("unauthorized", "missing or wrong token")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            let result = try execute(method: method, params: params)
            return ["id": id, "ok": true, "result": result]
        } catch let error as BridgeFailure {
            return failure(error.code, error.message)
        } catch let error as BatchOpError {
            return ["id": id, "ok": false, "error": [
                "code": "op_error", "message": error.message,
                "opIndex": error.opIndex, "op": error.opName,
            ]]
        } catch {
            return failure("op_error", String(describing: error))
        }
    }

    private struct BridgeFailure: Error {
        let code: String
        let message: String
    }

    private func execute(method: String, params: [String: Any]) throws -> [String: Any] {
        guard let appModel else {
            throw BridgeFailure(code: "no_session", message: "app is shutting down")
        }
        let session = appModel.session
        switch method {
        case "read":
            return AgentProtocol.mapJSON(
                for: session.store.map,
                formulaResults: session.store.formulaResults()
            )
        case "find":
            guard let query = params["query"] as? String else {
                throw BridgeFailure(code: "usage", message: "find requires query")
            }
            let hits = MapSearch.search(map: session.store.map, query: query)
            return ["hits": hits.map {
                ["id": $0.nodeID.rawValue, "title": $0.title, "matchInNote": $0.matchInNote]
            }]
        case "applyOps":
            guard !session.isBrainMode else {
                throw BridgeFailure(code: "no_session", message: "brain navigator has no editable map")
            }
            guard let opsValue = params["ops"],
                  let opsData = try? JSONSerialization.data(withJSONObject: opsValue) else {
                throw BridgeFailure(code: "usage", message: "applyOps requires ops array")
            }
            let ops: [MapOp]
            do {
                ops = try JSONDecoder().decode([MapOp].self, from: opsData)
            } catch {
                throw BridgeFailure(code: "usage", message: "invalid ops JSON: \(error.localizedDescription)")
            }
            guard !ops.isEmpty else {
                throw BridgeFailure(code: "usage", message: "ops array is empty")
            }
            let command = CompositeAgentCommand(ops: ops)
            try session.applyThrowing(command)
            session.showToast("Agent edit (\(ops.count) ops) · ⌘Z to undo", kind: .success)
            return ["affected": command.affected.map(\.rawValue)]
        case "session":
            return [
                "mapPath": appModel.currentMapURL?.path as Any,
                "title": session.store.map.title,
                "selectedIds": session.store.selection.selectedIDs.map(\.rawValue),
                "canUndo": session.canUndo,
                "canRedo": session.canRedo,
                "isBrainMode": session.isBrainMode,
            ]
        case "new":
            let title = params["title"] as? String ?? "Untitled"
            guard let url = appModel.createAndOpenMap(titled: title) else {
                throw BridgeFailure(code: "file_error", message: "could not create map")
            }
            return ["path": url.path]
        default:
            throw BridgeFailure(code: "usage", message: "unknown method: \(method)")
        }
    }
}
```

- [ ] **Step 4: Wire lifecycle**

In `AppModel.swift`: add a property `let agentBridge = AgentBridge()`
(internal, not `private` — tests/delegate may touch it later) and, as the
last statement of `bootstrap()`:

```swift
        agentBridge.start(appModel: self)
```

Shutdown via NotificationCenter (no AppDelegate change): at the end of
`AgentBridge.start(appModel:)`, register:

```swift
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
```

(`AgentBridge.swift` must `import AppKit` for `NSApplication`.)

- [ ] **Step 5: Build + relaunch + manual smoke**

```bash
./scripts/rerun-mac.sh --no-test
```

Then verify the socket exists and accepts a handshake (from a shell):

```bash
ls -l ~/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind/
# expect: agent.sock (srw-------), agent.token (-rw-------)
```

Expected: app builds, launches, socket + token files exist.

- [ ] **Step 6: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/AgentBridge.swift Apps/SwiftMindMac/SwiftMindMac/AppModel.swift Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift docs/superpowers/specs/2026-09-03-agent-live-bridge-design.md
git commit -m "app: AgentBridge — Unix-socket server for live agent sessions"
```

---

### Task 6: `swiftmind mcp` — stdio MCP server (CLI)

**Files:**
- Create: `Sources/SwiftMindCLI/BridgeClient.swift`
- Create: `Sources/SwiftMindCLI/MCPServer.swift`
- Modify: `Sources/SwiftMindCLI/main.swift` (route `mcp`)
- Modify: `scripts/test-cli.sh` (mcp app-absent checks)

- [ ] **Step 1: Add smoke coverage first**

In `scripts/test-cli.sh`, insert before the final `echo "CLI smoke test OK"`:

```bash
# mcp without the app: initialize works, tool call reports app not running
MCP_OUT=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_map","arguments":{}}}' \
  | "$CLI" mcp)
echo "$MCP_OUT" | grep -q '"serverInfo"' || fail "mcp initialize"
echo "$MCP_OUT" | grep -q 'not running' || fail "mcp app-absent tool error"
```

- [ ] **Step 2: Run smoke to verify `mcp` fails**

Run: `./scripts/test-cli.sh`
Expected: FAIL at `mcp` — unknown command.

- [ ] **Step 3: Implement the bridge client**

Create `Sources/SwiftMindCLI/BridgeClient.swift`:

```swift
import Foundation

/// Client side of the app's AgentBridge Unix socket.
/// Keep paths in sync with `AgentBridge` in the app target.
enum BridgeClient {
    enum Failure: Error, CustomStringConvertible {
        case appNotRunning
        case badResponse(String)

        var description: String {
            switch self {
            case .appNotRunning:
                return "SwiftMind.app is not running (start it, or use the file-mode CLI)"
            case .badResponse(let detail):
                return "bad bridge response: \(detail)"
            }
        }
    }

    private static var bridgeDirectory: String {
        NSHomeDirectory()
            + "/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind"
    }

    /// One request, one short-lived connection.
    static func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let tokenURL = URL(fileURLWithPath: bridgeDirectory + "/agent.token")
        guard let tokenData = try? Data(contentsOf: tokenURL),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw Failure.appNotRunning
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.appNotRunning }
        defer { close(fd) }

        let socketPath = bridgeDirectory + "/agent.sock"
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure.badResponse("socket path too long")
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
        guard connected == 0 else { throw Failure.appNotRunning }

        let request: [String: Any] = [
            "id": 1, "token": token, "method": method, "params": params,
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
            throw Failure.badResponse("request not encodable")
        }
        var length = UInt32(requestData.count).bigEndian
        _ = withUnsafeBytes(of: &length) { send(fd, $0.baseAddress, $0.count, 0) }
        _ = requestData.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

        guard let header = readFully(fd, count: 4), header.count == 4 else {
            throw Failure.appNotRunning
        }
        let responseLength = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard responseLength > 0, responseLength <= 4 * 1024 * 1024,
              let responseData = readFully(fd, count: Int(responseLength)),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw Failure.badResponse("no or malformed frame")
        }
        return response
    }

    private static func readFully(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while data.count < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, min(ptr.count, count - data.count), 0)
            }
            guard n > 0 else { return nil }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }
}
```

- [ ] **Step 4: Implement the MCP server**

Create `Sources/SwiftMindCLI/MCPServer.swift`:

```swift
import Foundation

/// Minimal MCP server on stdio (newline-delimited JSON-RPC 2.0,
/// protocolVersion 2025-06-18). Forwards tool calls to the running app
/// via BridgeClient. Loops until stdin closes.
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static let tools: [[String: Any]] = [
        [
            "name": "read_map",
            "description": "Read the map currently open in SwiftMind as a JSON tree, including computed formula results.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "find_nodes",
            "description": "Case-insensitive search of titles/notes in the open map.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
        ],
        [
            "name": "apply_ops",
            "description": "Apply a batch of map ops (same op objects as `swiftmind batch`) to the open map. All-or-nothing, one undo step in the app.",
            "inputSchema": [
                "type": "object",
                "properties": ["ops": ["type": "array", "items": ["type": "object"]]],
                "required": ["ops"],
            ],
        ],
        [
            "name": "get_session",
            "description": "Session state: open map path/title, selection, undo depth, brain mode.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "new_map",
            "description": "Create a new map in the default library and open it in the app.",
            "inputSchema": [
                "type": "object",
                "properties": ["title": ["type": "string"]],
            ],
        ],
    ]

    /// MCP tool name → bridge method.
    private static let methodForTool = [
        "read_map": "read",
        "find_nodes": "find",
        "apply_ops": "applyOps",
        "get_session": "session",
        "new_map": "new",
    ]

    static func run() -> Never {
        while let line = readLine(stripNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String
            else { continue }
            let id = message["id"]  // nil for notifications

            switch method {
            case "initialize":
                guard let id else { continue }
                respond(id: id, result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "swiftmind", "version": swiftmindCLIVersion],
                ])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "ping":
                guard let id else { continue }
                respond(id: id, result: [:])
            case "tools/list":
                guard let id else { continue }
                respond(id: id, result: ["tools": tools])
            case "tools/call":
                guard let id else { continue }
                let params = message["params"] as? [String: Any] ?? [:]
                handleToolCall(id: id, params: params)
            default:
                guard let id else { continue }
                respondError(id: id, code: -32601, message: "method not found: \(method)")
            }
        }
        exit(0)
    }

    private static func handleToolCall(id: Any, params: [String: Any]) {
        guard let tool = params["name"] as? String,
              let method = methodForTool[tool] else {
            respond(id: id, result: [
                "content": [["type": "text", "text": "unknown tool"]],
                "isError": true,
            ])
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let response = try BridgeClient.call(method: method, params: arguments)
            if let ok = response["ok"] as? Bool, ok,
               let result = response["result"] {
                respond(id: id, result: [
                    "content": [[
                        "type": "text",
                        "text": jsonText(result),
                    ]],
                ])
            } else {
                let error = response["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "bridge error"
                respond(id: id, result: [
                    "content": [["type": "text", "text": message]],
                    "isError": true,
                ])
            }
        } catch {
            respond(id: id, result: [
                "content": [["type": "text", "text": String(describing: error)]],
                "isError": true,
            ])
        }
    }

    private static func jsonText(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    private static func respond(id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func respondError(id: Any, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }
}
```

- [ ] **Step 5: Route `mcp` in main.swift**

In `Sources/SwiftMindCLI/main.swift`, next to the `--version` early-exit, add:

```swift
if args.first == "mcp" {
    MCPServer.run()
}
```

And add to the usage text, after the `new` line:

```
      mcp                              run a stdio MCP server bridged to the live app
```

`swiftmindCLIVersion` is currently declared in `main.swift` as a top-level
`let` — MCPServer.swift references it; top-level globals in the same module
are visible across files, so no change needed beyond keeping the name.

- [ ] **Step 6: Run tests + smoke**

Run: `swift test && ./scripts/test-cli.sh`
Expected: all pass, including the mcp app-absent checks.

- [ ] **Step 7: Reinstall + commit**

```bash
./scripts/install-cli.sh
git add Sources/SwiftMindCLI/BridgeClient.swift Sources/SwiftMindCLI/MCPServer.swift Sources/SwiftMindCLI/main.swift scripts/test-cli.sh
git commit -m "CLI: swiftmind mcp — stdio MCP server bridged to the live app"
```

---

### Task 7: Live end-to-end verification (app + CLI together)

**Files:** none (verification only).

- [ ] **Step 1: Relaunch the app**

```bash
./scripts/rerun-mac.sh --no-test
```

- [ ] **Step 2: Drive the live session over MCP by hand**

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_session","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"apply_ops","arguments":{"ops":[{"op":"add-child","parent":"ROOT_ID","id":"n_mcp","text":"MCP live edit"}]}}}' \
  | ~/.local/bin/swiftmind mcp
```

(First get ROOT_ID via `{"name":"read_map"}` or the file CLI `read`.) Expected:
- `get_session` returns the open map's path/title.
- `apply_ops` returns `{"affected":["n_mcp"]}`; the app canvas shows the new
  node within a second, with toast "Agent edit (1 ops) · ⌘Z to undo".
- ⌘Z in the app removes the node as ONE undo step (the v1 pain point: undo
  stack survives agent edits).

- [ ] **Step 3: Formula visibility check**

On a map with a formula node (create one via the file CLI `set-formula`):
`read_map` over MCP includes `formulaResult` for that node; the file-mode
`swiftmind read` of the same map does not. This is the intended difference.

- [ ] **Step 4: Real agent framework config**

Add to the agent framework's MCP config (Kimi/Claude Code):

```json
{"mcpServers": {"swiftmind": {"command": "/Users/lucas/.local/bin/swiftmind", "args": ["mcp"]}}}
```

Drive one scenario from the framework (e.g. "read my open map and add three
child ideas to the selected node"). Record any friction as follow-up items.

- [ ] **Step 5: Commit any fixes found**

---

### Task 8: Docs + final gate

**Files:**
- Modify: `skills/swiftmind/SKILL.md`
- Modify: `AGENTS.md`
- Modify: `README.md`

- [ ] **Step 1: SKILL.md — live mode section**

Insert a new section after `## Commands`:

```markdown
## Live mode (MCP) — preferred when the app is running

When SwiftMind.app is running, prefer the MCP bridge over file edits: edits
become one ⌘Z step, formula results are computed, and you can see what the
user has open. Register in the agent framework:

    {"mcpServers": {"swiftmind": {"command": "swiftmind", "args": ["mcp"]}}}

Tools: `read_map` (adds `formulaResult` per formula node), `find_nodes`,
`apply_ops` (same op objects as `batch`; one undo step), `get_session`,
`new_map`. If a tool returns "SwiftMind.app is not running", fall back to the
file commands below. Never use `apply_ops` and a file-mode write command on
the same map concurrently — the app's autosave wins the race; do live edits
via MCP only, or stop the app and use file mode.
```

- [ ] **Step 2: AGENTS.md**

- Fix the stale multi-window line: replace the `**Multi-window:**` bullet
  with: `- **Single live session:** the app currently has one shared
  \`AppModel\`/\`DocumentSession\` for all windows — the agent bridge
  (\`AgentBridge.swift\`) and all session-scoped features address that one
  session.`
- Add a bullet after the CLI bullet:

```
- **Agent bridge (live edits).** `AgentBridge` in the app serves a Unix
  socket at `~/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind/agent.sock`
  (token file next to it, regenerated per launch). `swiftmind mcp` bridges
  stdio MCP to it; `applyOps` dispatches one `CompositeAgentCommand` = one
  undo step. No network entitlement anywhere. Kill switch:
  `defaults write app.swiftmind.mac swiftmind.agentBridge -bool false`.
```
- Repository layout: add `AgentBridge.swift` to the app sources line.

- [ ] **Step 3: README**

Add to the feature list: agent live bridge (MCP) with one-undo-step edits;
add `swiftmind new` and `swiftmind mcp` to any CLI command listing.

- [ ] **Step 4: Final gate**

```bash
swift test && ./scripts/verify.sh --skip-ui && ./scripts/test-cli.sh
```

Expected: all green. If a GUI session is available, also `./scripts/test-ui.sh`.

- [ ] **Step 5: Commit**

```bash
git add skills/swiftmind/SKILL.md AGENTS.md README.md
git commit -m "docs: agent live bridge (MCP) in SKILL/AGENTS/README"
```
