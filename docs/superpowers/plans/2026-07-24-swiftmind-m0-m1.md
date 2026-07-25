# SwiftMind M0 + M1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS document app that creates, edits, auto-layouts, saves, and reloads mind maps as `.swiftmind.html`, with outline + canvas views and a basic browser-readable skin.

**Architecture:** UI-free `SwiftMindCore` (SPM) owns model, commands/undo, layout snapshots, and HTML codec. `SwiftMindMac` is a SwiftUI `DocumentGroup` shell that dispatches commands and renders snapshots. No WebView editor; no Freeplane/Java.

**Tech Stack:** Swift 5.10+, Swift Package Manager, XCTest, SwiftUI, AppKit only at the app edge if needed, macOS 14.0 deployment target.

**Spec:** `docs/superpowers/specs/2026-07-24-swiftmind-design.md` (M0 + M1 only).

**Out of scope for this plan:** pin positions, Markdown notes, links, icons, filters, attributes, formulas, scripts, iCloud, Command Palette, `.mm` import.

---

## File map (create these)

```text
swiftmind/
  Package.swift
  Sources/SwiftMindCore/
    Model/NodeID.swift
    Model/NodeSide.swift
    Model/NodeStyle.swift
    Model/Node.swift
    Model/MindMap.swift
    Model/Point2D.swift
    Commands/MapCommand.swift
    Commands/CommandBus.swift
    Commands/SetTextCommand.swift
    Commands/InsertChildCommand.swift
    Commands/InsertSiblingCommand.swift
    Commands/DeleteNodesCommand.swift
    Commands/MoveNodeCommand.swift
    Commands/SetFoldedCommand.swift
    Commands/SetStyleCommand.swift
    Store/SelectionState.swift
    Store/MapStore.swift
    Layout/LayoutConfig.swift
    Layout/MapSnapshot.swift
    Layout/LayoutEngine.swift
    HTML/HTMLCodec.swift
    HTML/HTMLSkin.swift
  Tests/SwiftMindCoreTests/
    NodeModelTests.swift
    CommandBusTests.swift
    HTMLCodecTests.swift
    LayoutEngineTests.swift
    Fixtures/minimal.swiftmind.html
  Apps/SwiftMindMac/
    project.yml                 # XcodeGen
    SwiftMindMac/
      SwiftMindMacApp.swift
      UTType+SwiftMind.swift
      SwiftMindFileDocument.swift
      ContentView.swift
      OutlineMapView.swift
      MapCanvasView.swift
      InspectorView.swift
      Assets.xcassets/...
      Info.plist
  README.md
```

---

### Task 1: SPM package skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/SwiftMindCore/Model/NodeID.swift` (stub ok until Task 2)
- Create: `Tests/SwiftMindCoreTests/SmokeTests.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftMind",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftMindCore", targets: ["SwiftMindCore"])
    ],
    targets: [
        .target(
            name: "SwiftMindCore",
            path: "Sources/SwiftMindCore"
        ),
        .testTarget(
            name: "SwiftMindCoreTests",
            dependencies: ["SwiftMindCore"],
            path: "Tests/SwiftMindCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
```

- [ ] **Step 2: Add temporary smoke types so the package builds**

`Sources/SwiftMindCore/Model/NodeID.swift`:

```swift
public struct NodeID: Hashable, Sendable, Codable, Equatable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> NodeID {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return NodeID(rawValue: "n_" + String(uuid.prefix(16)))
    }
}
```

`Tests/SwiftMindCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import SwiftMindCore

final class SmokeTests: XCTestCase {
    func testNodeIDGenerateIsStableFormat() {
        let id = NodeID.generate()
        XCTAssertTrue(id.rawValue.hasPrefix("n_"))
        XCTAssertEqual(id.rawValue.count, 18) // "n_" + 16 hex chars
    }
}
```

- [ ] **Step 3: Create empty Fixtures directory**

```bash
mkdir -p Tests/SwiftMindCoreTests/Fixtures Sources/SwiftMindCore/Model
touch Tests/SwiftMindCoreTests/Fixtures/.gitkeep
```

- [ ] **Step 4: Run tests**

```bash
cd /Volumes/WD/devwd/swiftmind && swift test
```

Expected: `SmokeTests` PASS; package resolves.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "chore: scaffold SwiftMindCore package"
```

---

### Task 2: Core domain model (Node, MindMap, style)

**Files:**
- Create: `Sources/SwiftMindCore/Model/Point2D.swift`
- Create: `Sources/SwiftMindCore/Model/NodeSide.swift`
- Create: `Sources/SwiftMindCore/Model/NodeStyle.swift`
- Create: `Sources/SwiftMindCore/Model/Node.swift`
- Create: `Sources/SwiftMindCore/Model/MindMap.swift`
- Create: `Tests/SwiftMindCoreTests/NodeModelTests.swift`
- Delete or keep: `SmokeTests.swift` (can leave)

- [ ] **Step 1: Write failing model tests**

`Tests/SwiftMindCoreTests/NodeModelTests.swift`:

```swift
import XCTest
@testable import SwiftMindCore

final class NodeModelTests: XCTestCase {
    func testMindMapStartsWithRoot() {
        let map = MindMap.makeEmpty(title: "Demo")
        XCTAssertEqual(map.title, "Demo")
        XCTAssertEqual(map.schemaVersion, 1)
        XCTAssertEqual(map.root.text, "Central Idea")
        XCTAssertTrue(map.root.children.isEmpty)
    }

    func testFindNodeReturnsNestedChild() {
        var map = MindMap.makeEmpty(title: "T")
        let childID = NodeID(rawValue: "n_child")
        map.root.children.append(
            Node(id: childID, text: "Child", side: .right)
        )
        XCTAssertEqual(map.node(id: childID)?.text, "Child")
        XCTAssertNil(map.node(id: NodeID(rawValue: "missing")))
    }

    func testUpdateNodeTextViaPath() {
        var map = MindMap.makeEmpty(title: "T")
        let childID = NodeID(rawValue: "n_child")
        map.root.children = [Node(id: childID, text: "Old", side: .left)]
        let ok = map.updateNode(id: childID) { $0.text = "New" }
        XCTAssertTrue(ok)
        XCTAssertEqual(map.node(id: childID)?.text, "New")
    }
}
```

- [ ] **Step 2: Run tests — expect FAIL (types missing)**

```bash
swift test --filter NodeModelTests
```

Expected: compile errors for `MindMap` / `Node`.

- [ ] **Step 3: Implement model types**

`Sources/SwiftMindCore/Model/Point2D.swift`:

```swift
public struct Point2D: Equatable, Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)
}
```

`Sources/SwiftMindCore/Model/NodeSide.swift`:

```swift
public enum NodeSide: String, Sendable, Codable, Equatable {
    case auto
    case left
    case right
}
```

`Sources/SwiftMindCore/Model/NodeStyle.swift`:

```swift
public struct NodeStyle: Equatable, Sendable, Codable {
    public var fontSize: Double
    public var isBold: Bool
    /// sRGB 0...1
    public var textRed: Double
    public var textGreen: Double
    public var textBlue: Double
    public var fillRed: Double?
    public var fillGreen: Double?
    public var fillBlue: Double?

    public init(
        fontSize: Double = 14,
        isBold: Bool = false,
        textRed: Double = 0,
        textGreen: Double = 0,
        textBlue: Double = 0,
        fillRed: Double? = nil,
        fillGreen: Double? = nil,
        fillBlue: Double? = nil
    ) {
        self.fontSize = fontSize
        self.isBold = isBold
        self.textRed = textRed
        self.textGreen = textGreen
        self.textBlue = textBlue
        self.fillRed = fillRed
        self.fillGreen = fillGreen
        self.fillBlue = fillBlue
    }

    public static let rootDefault = NodeStyle(fontSize: 22, isBold: true)
    public static let `default` = NodeStyle()
}
```

`Sources/SwiftMindCore/Model/Node.swift`:

```swift
public struct Node: Identifiable, Equatable, Sendable, Codable {
    public var id: NodeID
    public var text: String
    public var isFolded: Bool
    public var side: NodeSide
    public var style: NodeStyle
    public var positionPin: Point2D?
    public var children: [Node]

    public init(
        id: NodeID = .generate(),
        text: String,
        isFolded: Bool = false,
        side: NodeSide = .auto,
        style: NodeStyle = .default,
        positionPin: Point2D? = nil,
        children: [Node] = []
    ) {
        self.id = id
        self.text = text
        self.isFolded = isFolded
        self.side = side
        self.style = style
        self.positionPin = positionPin
        self.children = children
    }
}
```

`Sources/SwiftMindCore/Model/MindMap.swift`:

```swift
public struct MindMap: Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var schemaVersion: Int
    public var root: Node

    public init(id: String, title: String, schemaVersion: Int = 1, root: Node) {
        self.id = id
        self.title = title
        self.schemaVersion = schemaVersion
        self.root = root
    }

    public static func makeEmpty(title: String) -> MindMap {
        let root = Node(
            text: "Central Idea",
            side: .auto,
            style: .rootDefault
        )
        return MindMap(
            id: "m_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16),
            title: title,
            schemaVersion: 1,
            root: root
        )
    }

    public func node(id: NodeID) -> Node? {
        find(id: id, in: root)
    }

    @discardableResult
    public mutating func updateNode(id: NodeID, _ body: (inout Node) -> Void) -> Bool {
        update(id: id, in: &root, body)
    }

    private func find(id: NodeID, in node: Node) -> Node? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id: id, in: child) { return found }
        }
        return nil
    }

    private mutating func update(id: NodeID, in node: inout Node, _ body: (inout Node) -> Void) -> Bool {
        if node.id == id {
            body(&node)
            return true
        }
        for i in node.children.indices {
            if update(id: id, in: &node.children[i], body) {
                return true
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter NodeModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore Tests/SwiftMindCoreTests
git commit -m "feat(core): add MindMap and Node domain model"
```

---

### Task 3: CommandBus + SetText + InsertChild + Delete

**Files:**
- Create: `Sources/SwiftMindCore/Commands/MapCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/CommandBus.swift`
- Create: `Sources/SwiftMindCore/Commands/SetTextCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/InsertChildCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/DeleteNodesCommand.swift`
- Create: `Tests/SwiftMindCoreTests/CommandBusTests.swift`

- [ ] **Step 1: Write failing command tests**

```swift
import XCTest
@testable import SwiftMindCore

final class CommandBusTests: XCTestCase {
    func testSetTextUndoRedo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let rootID = map.root.id
        let bus = CommandBus()
        try bus.execute(SetTextCommand(nodeID: rootID, newText: "Hello"), on: &map)
        XCTAssertEqual(map.root.text, "Hello")
        try bus.undo(on: &map)
        XCTAssertEqual(map.root.text, "Central Idea")
        try bus.redo(on: &map)
        XCTAssertEqual(map.root.text, "Hello")
    }

    func testInsertChildAndDelete() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let childID = NodeID(rawValue: "n_fixed_child")
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: childID, text: "A", side: .right),
            on: &map
        )
        XCTAssertEqual(map.root.children.count, 1)
        XCTAssertEqual(map.root.children[0].text, "A")
        try bus.execute(DeleteNodesCommand(nodeIDs: [childID]), on: &map)
        XCTAssertTrue(map.root.children.isEmpty)
        try bus.undo(on: &map)
        XCTAssertEqual(map.root.children.count, 1)
    }

    func testCannotDeleteRoot() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        XCTAssertThrowsError(
            try bus.execute(DeleteNodesCommand(nodeIDs: [map.root.id]), on: &map)
        )
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
swift test --filter CommandBusTests
```

- [ ] **Step 3: Implement commands**

`Sources/SwiftMindCore/Commands/MapCommand.swift`:

```swift
public protocol MapCommand {
    var name: String { get }
    func execute(on map: inout MindMap) throws
    func undo(on map: inout MindMap) throws
}

public enum MapCommandError: Error, Equatable {
    case nodeNotFound(NodeID)
    case cannotDeleteRoot
    case invalidParent
}
```

`Sources/SwiftMindCore/Commands/CommandBus.swift`:

```swift
public final class CommandBus: @unchecked Sendable {
    private var undoStack: [any MapCommand] = []
    private var redoStack: [any MapCommand] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func execute(_ command: any MapCommand, on map: inout MindMap) throws {
        try command.execute(on: &map)
        undoStack.append(command)
        redoStack.removeAll()
    }

    public func undo(on map: inout MindMap) throws {
        guard let command = undoStack.popLast() else { return }
        try command.undo(on: &map)
        redoStack.append(command)
    }

    public func redo(on map: inout MindMap) throws {
        guard let command = redoStack.popLast() else { return }
        try command.execute(on: &map)
        undoStack.append(command)
    }

    public func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
```

`Sources/SwiftMindCore/Commands/SetTextCommand.swift` (class so undo state survives redo stacks):

```swift
public final class SetTextCommand: MapCommand {
    public let name = "SetText"
    public let nodeID: NodeID
    public let newText: String
    private var oldText: String?

    public init(nodeID: NodeID, newText: String) {
        self.nodeID = nodeID
        self.newText = newText
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        if oldText == nil { oldText = node.text }
        guard map.updateNode(id: nodeID, { $0.text = newText }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldText else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.text = oldText }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
```

Same **class + private old value** pattern for `SetFoldedCommand` and `SetStyleCommand`.

`Sources/SwiftMindCore/Commands/InsertChildCommand.swift`:

```swift
public final class InsertChildCommand: MapCommand {
    public let name = "InsertChild"
    public let parentID: NodeID
    public let newNodeID: NodeID
    public let text: String
    public let side: NodeSide
    private var didInsert = false

    public init(parentID: NodeID, newNodeID: NodeID = .generate(), text: String, side: NodeSide = .auto) {
        self.parentID = parentID
        self.newNodeID = newNodeID
        self.text = text
        self.side = side
    }

    public func execute(on map: inout MindMap) throws {
        let child = Node(id: newNodeID, text: text, side: side)
        var inserted = false
        let ok = map.updateNode(id: parentID) { parent in
            parent.children.append(child)
            inserted = true
        }
        guard ok, inserted else { throw MapCommandError.nodeNotFound(parentID) }
        didInsert = true
    }

    public func undo(on map: inout MindMap) throws {
        guard didInsert else { return }
        let ok = map.updateNode(id: parentID) { parent in
            parent.children.removeAll { $0.id == newNodeID }
        }
        guard ok else { throw MapCommandError.nodeNotFound(parentID) }
    }
}
```

`Sources/SwiftMindCore/Commands/DeleteNodesCommand.swift`:

```swift
public final class DeleteNodesCommand: MapCommand {
    public let name = "DeleteNodes"
    public let nodeIDs: Set<NodeID>
    private struct Removal: Equatable {
        var parentID: NodeID
        var index: Int
        var node: Node
    }
    private var removals: [Removal] = []

    public init(nodeIDs: [NodeID]) {
        self.nodeIDs = Set(nodeIDs)
    }

    public func execute(on map: inout MindMap) throws {
        if nodeIDs.contains(map.root.id) {
            throw MapCommandError.cannotDeleteRoot
        }
        removals = []
        for id in nodeIDs {
            try deleteOne(id, from: &map)
        }
        // Sort by index descending when restoring later
        removals.sort { $0.index > $1.index }
    }

    public func undo(on map: inout MindMap) throws {
        // Restore deepest indices first in reverse removal order
        for removal in removals.sorted(by: { $0.index < $1.index }) {
            let ok = map.updateNode(id: removal.parentID) { parent in
                let i = min(removal.index, parent.children.count)
                parent.children.insert(removal.node, at: i)
            }
            guard ok else { throw MapCommandError.nodeNotFound(removal.parentID) }
        }
    }

    private func deleteOne(_ id: NodeID, from map: inout MindMap) throws {
        guard let parentID = map.parentID(of: id),
              let parent = map.node(id: parentID),
              let index = parent.children.firstIndex(where: { $0.id == id }) else {
            throw MapCommandError.nodeNotFound(id)
        }
        let node = parent.children[index]
        removals.append(Removal(parentID: parentID, index: index, node: node))
        let ok = map.updateNode(id: parentID) { $0.children.removeAll { $0.id == id } }
        guard ok else { throw MapCommandError.nodeNotFound(id) }
    }
}
```

Add helper on `MindMap` in `MindMap.swift`:

```swift
public func parentID(of id: NodeID) -> NodeID? {
    parentID(of: id, in: root, parent: nil)
}

private func parentID(of id: NodeID, in node: Node, parent: NodeID?) -> NodeID? {
    if node.id == id { return parent }
    for child in node.children {
        if let found = parentID(of: id, in: child, parent: node.id) {
            return found
        }
    }
    return nil
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter CommandBusTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore Tests/SwiftMindCoreTests
git commit -m "feat(core): CommandBus with setText, insert, delete"
```

---

### Task 4: MoveNode, SetFolded, SetStyle, InsertSibling

**Files:**
- Create: `Sources/SwiftMindCore/Commands/MoveNodeCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/SetFoldedCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/SetStyleCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/InsertSiblingCommand.swift`
- Modify: `Tests/SwiftMindCoreTests/CommandBusTests.swift`

- [ ] **Step 1: Add tests**

```swift
func testMoveNodeReparents() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    let a = NodeID(rawValue: "n_a")
    let b = NodeID(rawValue: "n_b")
    try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
    try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: b, text: "B", side: .right), on: &map)
    try bus.execute(MoveNodeCommand(nodeID: b, newParentID: a, index: 0), on: &map)
    XCTAssertEqual(map.node(id: a)?.children.map(\.id), [b])
    XCTAssertEqual(map.root.children.map(\.id), [a])
}

func testSetFoldedAndStyle() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    try bus.execute(SetFoldedCommand(nodeID: map.root.id, isFolded: true), on: &map)
    XCTAssertTrue(map.root.isFolded)
    var style = NodeStyle.default
    style.isBold = true
    style.fontSize = 18
    try bus.execute(SetStyleCommand(nodeID: map.root.id, style: style), on: &map)
    XCTAssertEqual(map.root.style.fontSize, 18)
    XCTAssertTrue(map.root.style.isBold)
}
```

- [ ] **Step 2: Implement MoveNodeCommand**

```swift
public final class MoveNodeCommand: MapCommand {
    public let name = "MoveNode"
    public let nodeID: NodeID
    public let newParentID: NodeID
    public let index: Int
    private var oldParentID: NodeID?
    private var oldIndex: Int?
    private var movedNode: Node?

    public init(nodeID: NodeID, newParentID: NodeID, index: Int) {
        self.nodeID = nodeID
        self.newParentID = newParentID
        self.index = index
    }

    public func execute(on map: inout MindMap) throws {
        if nodeID == map.root.id { throw MapCommandError.cannotDeleteRoot }
        // Prevent moving into own descendant
        if isDescendant(nodeID, possibleDescendant: newParentID, map: map) {
            throw MapCommandError.invalidParent
        }
        guard let oldParent = map.parentID(of: nodeID),
              let parentNode = map.node(id: oldParent),
              let idx = parentNode.children.firstIndex(where: { $0.id == nodeID }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        oldParentID = oldParent
        oldIndex = idx
        movedNode = parentNode.children[idx]
        guard map.updateNode(id: oldParent, { $0.children.removeAll { $0.id == nodeID } }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        guard var moving = movedNode else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: newParentID, { parent in
            let i = min(max(0, index), parent.children.count)
            parent.children.insert(moving, at: i)
        }) else {
            throw MapCommandError.nodeNotFound(newParentID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldParentID, let oldIndex, let movedNode else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        guard map.updateNode(id: newParentID, { $0.children.removeAll { $0.id == nodeID } }) else {
            throw MapCommandError.nodeNotFound(newParentID)
        }
        guard map.updateNode(id: oldParentID, { parent in
            let i = min(oldIndex, parent.children.count)
            parent.children.insert(movedNode, at: i)
        }) else {
            throw MapCommandError.nodeNotFound(oldParentID)
        }
    }

    private func isDescendant(_ ancestor: NodeID, possibleDescendant: NodeID, map: MindMap) -> Bool {
        guard let node = map.node(id: ancestor) else { return false }
        return contains(possibleDescendant, in: node)
    }

    private func contains(_ id: NodeID, in node: Node) -> Bool {
        if node.id == id { return true }
        return node.children.contains { contains(id, in: $0) }
    }
}
```

`SetFoldedCommand` / `SetStyleCommand`: same class pattern as `SetTextCommand` storing old value.

`InsertSiblingCommand`: find parent + index of `siblingID`, insert after it under same parent (reuse insert logic).

- [ ] **Step 3: Run all command tests — PASS, commit**

```bash
swift test --filter CommandBusTests
git add Sources/SwiftMindCore Tests/SwiftMindCoreTests
git commit -m "feat(core): move, fold, style, sibling commands"
```

---

### Task 5: MapStore + Selection

**Files:**
- Create: `Sources/SwiftMindCore/Store/SelectionState.swift`
- Create: `Sources/SwiftMindCore/Store/MapStore.swift`
- Create: `Tests/SwiftMindCoreTests/MapStoreTests.swift`

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import SwiftMindCore

final class MapStoreTests: XCTestCase {
    func testDispatchUpdatesMapAndSelection() throws {
        let store = MapStore(map: MindMap.makeEmpty(title: "T"))
        let root = store.map.root.id
        store.select(root)
        try store.dispatch(InsertChildCommand(parentID: root, text: "Kid", side: .right))
        XCTAssertEqual(store.map.root.children.count, 1)
        let child = store.map.root.children[0].id
        XCTAssertEqual(store.selection.primary, child) // InsertChild should select new node — set this in store after insert if command doesn't
        try store.undo()
        XCTAssertTrue(store.map.root.children.isEmpty)
    }
}
```

**Selection rule for M1:** After `InsertChild` / `InsertSibling`, `MapStore.dispatch` sets selection to the new node id if the command exposes it. Simplest approach: in `MapStore.dispatch`, after execute, if command is `InsertChildCommand`, select `newNodeID`.

- [ ] **Step 2: Implement**

```swift
public struct SelectionState: Equatable, Sendable {
    public var selectedIDs: Set<NodeID>
    public var primary: NodeID?

    public init(selectedIDs: Set<NodeID> = [], primary: NodeID? = nil) {
        self.selectedIDs = selectedIDs
        self.primary = primary
    }

    public mutating func select(_ id: NodeID, additive: Bool = false) {
        if additive {
            selectedIDs.insert(id)
            primary = id
        } else {
            selectedIDs = [id]
            primary = id
        }
    }

    public mutating func clear() {
        selectedIDs = []
        primary = nil
    }
}

public final class MapStore {
    public private(set) var map: MindMap
    public private(set) var selection: SelectionState
    public private(set) var revision: UInt64 = 0
    private let bus = CommandBus()

    public init(map: MindMap) {
        self.map = map
        self.selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
    }

    public func select(_ id: NodeID, additive: Bool = false) {
        selection.select(id, additive: additive)
        revision &+= 1
    }

    public func dispatch(_ command: any MapCommand) throws {
        try bus.execute(command, on: &map)
        if let insert = command as? InsertChildCommand {
            selection.select(insert.newNodeID)
        } else if let insert = command as? InsertSiblingCommand {
            selection.select(insert.newNodeID)
        }
        revision &+= 1
    }

    public func undo() throws {
        try bus.undo(on: &map)
        revision &+= 1
    }

    public func redo() throws {
        try bus.redo(on: &map)
        revision &+= 1
    }

    public var canUndo: Bool { bus.canUndo }
    public var canRedo: Bool { bus.canRedo }

    public func replaceMap(_ map: MindMap) {
        self.map = map
        bus.clearHistory()
        selection = SelectionState(selectedIDs: [map.root.id], primary: map.root.id)
        revision &+= 1
    }
}
```

Expose `newNodeID` as `public let` on insert commands (already is).

For SwiftUI later, wrap with `ObservableMapStore: ObservableObject` in the **app** target, not Core (keeps Core free of SwiftUI). Core `MapStore` stays a plain class; app observes `revision`.

- [ ] **Step 3: `swift test --filter MapStoreTests` PASS, commit**

```bash
git commit -m "feat(core): MapStore and selection"
```

---

### Task 6: HTMLCodec encode + decode round-trip

**Files:**
- Create: `Sources/SwiftMindCore/HTML/HTMLCodec.swift`
- Create: `Sources/SwiftMindCore/HTML/HTMLSkin.swift`
- Create: `Tests/SwiftMindCoreTests/HTMLCodecTests.swift`
- Create: `Tests/SwiftMindCoreTests/Fixtures/minimal.swiftmind.html` (optional golden)

- [ ] **Step 1: Write round-trip test**

```swift
import XCTest
@testable import SwiftMindCore

final class HTMLCodecTests: XCTestCase {
    func testRoundTripPreservesTreeAndStyle() throws {
        var map = MindMap.makeEmpty(title: "Roadmap")
        let bus = CommandBus()
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_a"), text: "Alpha", side: .right),
            on: &map
        )
        try bus.execute(
            InsertChildCommand(parentID: NodeID(rawValue: "n_a"), newNodeID: NodeID(rawValue: "n_b"), text: "Beta", side: .right),
            on: &map
        )
        map.updateNode(id: NodeID(rawValue: "n_a")) {
            $0.isFolded = true
            $0.style = NodeStyle(fontSize: 16, isBold: true, textRed: 0.1, textGreen: 0.2, textBlue: 0.3, fillRed: 0.9, fillGreen: 0.9, fillBlue: 1.0)
        }

        let html = try HTMLCodec.encode(map, includeSkin: false)
        XCTAssertTrue(html.contains("data-schema=\"1\""))
        XCTAssertTrue(html.contains("n_a"))
        XCTAssertTrue(html.contains("Alpha"))

        let decoded = try HTMLCodec.decode(html)
        XCTAssertEqual(decoded.title, "Roadmap")
        XCTAssertEqual(decoded.root.children.count, 1)
        XCTAssertEqual(decoded.root.children[0].id.rawValue, "n_a")
        XCTAssertEqual(decoded.root.children[0].text, "Alpha")
        XCTAssertTrue(decoded.root.children[0].isFolded)
        XCTAssertEqual(decoded.root.children[0].children[0].text, "Beta")
        XCTAssertEqual(decoded.root.children[0].style.fontSize, 16, accuracy: 0.001)
    }

    func testDecodeRejectsUnknownDocument() {
        XCTAssertThrowsError(try HTMLCodec.decode("<html><body>hi</body></html>"))
    }
}
```

- [ ] **Step 2: Implement HTMLCodec**

Use `SwiftSoup` **only if** you add a dependency. For M1 **prefer zero dependencies**: encode with string builder; decode with `Foundation.XMLParser` **or** a small regex-free scanner.

**Recommended for M1:** encode as XHTML-ish HTML string; decode with `XMLParser` by wrapping encode output as well-formed XML.

Encode algorithm:
1. Escape text: `& < > " '`
2. Emit:

```html
<!DOCTYPE html>
<html lang="en" data-swiftmind-version="1">
<head>
<meta charset="utf-8"/>
<title>{escaped title}</title>
{optional skin}
</head>
<body>
<article class="swiftmind-map" data-schema="1" data-map-id="{id}">
<ul class="mind-root" data-node-id="{root.id}" data-side="auto" data-folded="false" data-font-size="22" data-bold="true" data-text-color="#000000">
<li> ... wait: root is the mind-root ul's single conceptual node — encode root as the outer ul's data attributes AND first title div, children as nested li.
```

**Canonical structure (freeze this):**

```html
<article class="swiftmind-map" data-schema="1" data-map-id="m_xxx">
  <div class="map-title" hidden>Roadmap</div>
  <!-- root node -->
  <ul class="node" data-node-id="n_root" data-side="auto" data-folded="false"
      data-font-size="22" data-bold="true" data-text-color="#000000" data-fill-color="">
    <li class="node-self">
      <div class="node-title">Central Idea</div>
    </li>
    <li class="node-children">
      <ul class="node" data-node-id="n_a" ...>
        <li class="node-self"><div class="node-title">Alpha</div></li>
        <li class="node-children">...</li>
      </ul>
    </li>
  </ul>
</article>
```

Simpler **nested list** form (use this — easier):

```html
<article class="swiftmind-map" data-schema="1" data-map-id="...">
<ul>
  <li data-node-id="n_root" data-side="auto" data-folded="false"
      data-font-size="22" data-bold="true" data-text-color="#000000">
    <span class="node-title">Central Idea</span>
    <ul>
      <li data-node-id="n_a" data-side="right" ...>
        <span class="node-title">Alpha</span>
        <ul>
          <li data-node-id="n_b" ...><span class="node-title">Beta</span></li>
        </ul>
      </li>
    </ul>
  </li>
</ul>
</article>
```

Decoder: walk with XMLParser, on `li` start push node attrs, on `span` class node-title capture characters, on `li` end pop and attach to parent.

Color helpers: `#RRGGBB` ↔ doubles.

```swift
public enum HTMLCodecError: Error {
    case notSwiftMindDocument
    case invalidSchema
    case parseFailed(String)
}

public enum HTMLCodec {
    public static func encode(_ map: MindMap, includeSkin: Bool) throws -> String { ... }
    public static func decode(_ html: String) throws -> MindMap { ... }
}
```

`HTMLSkin.swift`:

```swift
enum HTMLSkin {
    static let readOnlyCSS: String = """
    body { font-family: -apple-system, system-ui, sans-serif; margin: 24px; }
    .swiftmind-map ul { list-style: none; padding-left: 1.25rem; border-left: 2px solid #ccc; }
    .swiftmind-map li { margin: 0.35rem 0; }
    .node-title { padding: 0.15rem 0.4rem; border-radius: 6px; }
    """

    static func headFragment(includeSkin: Bool) -> String {
        guard includeSkin else { return "" }
        return "<style>\n\(readOnlyCSS)\n</style>\n"
    }
}
```

- [ ] **Step 3: Run HTMLCodecTests — PASS**

```bash
swift test --filter HTMLCodecTests
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(core): HTMLCodec encode/decode round-trip"
```

---

### Task 7: LayoutEngine + MapSnapshot

**Files:**
- Create: `Sources/SwiftMindCore/Layout/LayoutConfig.swift`
- Create: `Sources/SwiftMindCore/Layout/MapSnapshot.swift`
- Create: `Sources/SwiftMindCore/Layout/LayoutEngine.swift`
- Create: `Tests/SwiftMindCoreTests/LayoutEngineTests.swift`

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import SwiftMindCore

final class LayoutEngineTests: XCTestCase {
    func testRootCenteredAndChildrenOffset() {
        var map = MindMap.makeEmpty(title: "T")
        _ = map // insert two children right/left
        let bus = CommandBus()
        try! bus.execute(InsertChildCommand(parentID: map.root.id, text: "R", side: .right), on: &map)
        try! bus.execute(InsertChildCommand(parentID: map.root.id, text: "L", side: .left), on: &map)

        let snapshot = LayoutEngine().layout(map: map)
        let rootV = snapshot.nodes.first { $0.id == map.root.id }!
        XCTAssertEqual(rootV.frame.x, 0, accuracy: 0.1) // center of root box at origin policy: use top-left of root at -width/2
        // Assert at least: right child center.x > root center.x, left child center.x < root center.x
        let r = map.root.children.first { $0.text == "R" }!
        let l = map.root.children.first { $0.text == "L" }!
        let rv = snapshot.nodes.first { $0.id == r.id }!
        let lv = snapshot.nodes.first { $0.id == l.id }!
        XCTAssertGreaterThan(rv.frame.midX, rootV.frame.midX)
        XCTAssertLessThan(lv.frame.midX, rootV.frame.midX)
        XCTAssertEqual(snapshot.edges.count, 2)
    }

    func testFoldedHidesDescendants() {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        let a = NodeID(rawValue: "n_a")
        try! bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
        try! bus.execute(InsertChildCommand(parentID: a, text: "Hidden", side: .right), on: &map)
        try! bus.execute(SetFoldedCommand(nodeID: a, isFolded: true), on: &map)
        let snapshot = LayoutEngine().layout(map: map)
        XCTAssertNil(snapshot.nodes.first { $0.text == "Hidden" })
        XCTAssertNotNil(snapshot.nodes.first { $0.id == a })
    }
}
```

Add `midX` on frame type.

- [ ] **Step 2: Implement geometry + engine**

```swift
public struct Rect2D: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct NodeVisual: Equatable, Sendable, Identifiable {
    public var id: NodeID
    public var text: String
    public var frame: Rect2D
    public var style: NodeStyle
    public var depth: Int
    public var side: NodeSide
    public var isFolded: Bool
    public var isSelected: Bool
}

public struct EdgeVisual: Equatable, Sendable, Identifiable {
    public var id: String { from.rawValue + "->" + to.rawValue }
    public var from: NodeID
    public var to: NodeID
    public var fromPoint: Point2D
    public var toPoint: Point2D
}

public struct MapSnapshot: Equatable, Sendable {
    public var nodes: [NodeVisual]
    public var edges: [EdgeVisual]
    public var bounds: Rect2D
}

public struct LayoutConfig: Equatable, Sendable {
    public var horizontalGap: Double = 48
    public var verticalGap: Double = 16
    public var minNodeWidth: Double = 48
    public var nodeHeight: Double = 32
    public var charWidth: Double = 8
    public var paddingX: Double = 12
    public init() {}
}

public struct LayoutEngine: Sendable {
    public var config: LayoutConfig
    public init(config: LayoutConfig = LayoutConfig()) {
        self.config = config
    }

    public func layout(map: MindMap, selection: SelectionState = SelectionState()) -> MapSnapshot {
        var nodes: [NodeVisual] = []
        var edges: [EdgeVisual] = []
        let rootSize = measure(map.root)
        let rootFrame = Rect2D(
            x: -rootSize.width / 2,
            y: -rootSize.height / 2,
            width: rootSize.width,
            height: rootSize.height
        )
        appendNode(map.root, frame: rootFrame, depth: 0, selection: selection, into: &nodes)
        placeChildren(
            of: map.root,
            parentFrame: rootFrame,
            depth: 1,
            selection: selection,
            nodes: &nodes,
            edges: &edges
        )
        let bounds = nodes.map(\.frame).reduce(rootFrame) { $0.union($1) }.inset(by: -40)
        return MapSnapshot(nodes: nodes, edges: edges, bounds: bounds)
    }

    private func measure(_ node: Node) -> (width: Double, height: Double) {
        let cw = max(8.0, node.style.fontSize * 0.55)
        let width = max(config.minNodeWidth, Double(node.text.count) * cw + config.paddingX * 2)
        let height = max(config.nodeHeight, node.style.fontSize + 16)
        return (width, height)
    }

    private func resolvedSide(_ node: Node, index: Int) -> NodeSide {
        if node.side != .auto { return node.side }
        return index % 2 == 0 ? .right : .left
    }

    private func subtreeHeight(_ node: Node) -> Double {
        let selfH = measure(node).height
        guard !node.isFolded, !node.children.isEmpty else { return selfH }
        let kids = node.children.map { subtreeHeight($0) }.reduce(0, +)
            + Double(max(0, node.children.count - 1)) * config.verticalGap
        return max(selfH, kids)
    }

    private func placeChildren(
        of parent: Node,
        parentFrame: Rect2D,
        depth: Int,
        selection: SelectionState,
        nodes: inout [NodeVisual],
        edges: inout [EdgeVisual]
    ) {
        guard !parent.isFolded else { return }
        let totalH = subtreeHeight(parent)
        var cursorY = parentFrame.midY - totalH / 2
        for (index, child) in parent.children.enumerated() {
            let side = resolvedSide(child, index: index)
            let size = measure(child)
            let blockH = subtreeHeight(child)
            let centerY = cursorY + blockH / 2
            let x: Double
            if side == .left {
                x = parentFrame.x - config.horizontalGap - size.width
            } else {
                x = parentFrame.x + parentFrame.width + config.horizontalGap
            }
            let frame = Rect2D(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
            appendNode(child, frame: frame, depth: depth, selection: selection, into: &nodes)
            let from = Point2D(
                x: side == .left ? parentFrame.x : parentFrame.x + parentFrame.width,
                y: parentFrame.midY
            )
            let to = Point2D(
                x: side == .left ? frame.x + frame.width : frame.x,
                y: frame.midY
            )
            edges.append(EdgeVisual(from: parent.id, to: child.id, fromPoint: from, toPoint: to))
            placeChildren(
                of: child,
                parentFrame: frame,
                depth: depth + 1,
                selection: selection,
                nodes: &nodes,
                edges: &edges
            )
            cursorY += blockH + config.verticalGap
        }
    }

    private func appendNode(
        _ node: Node,
        frame: Rect2D,
        depth: Int,
        selection: SelectionState,
        into nodes: inout [NodeVisual]
    ) {
        nodes.append(
            NodeVisual(
                id: node.id,
                text: node.text,
                frame: frame,
                style: node.style,
                depth: depth,
                side: node.side,
                isFolded: node.isFolded,
                isSelected: selection.selectedIDs.contains(node.id)
            )
        )
    }
}

// Add on Rect2D:
// func union(_ other: Rect2D) -> Rect2D
// func inset(by: Double) -> Rect2D  // negative by expands
```

Ignore `positionPin` in M1 (field exists on `Node`; layout does not read it until M2).

- [ ] **Step 3: Tests PASS, commit**

```bash
git commit -m "feat(core): LayoutEngine and MapSnapshot"
```

---

### Task 8: Wire MapStore.snapshot helper

**Files:**
- Modify: `Sources/SwiftMindCore/Store/MapStore.swift`

- [ ] **Step 1: Add**

```swift
private let layoutEngine = LayoutEngine()

public func snapshot() -> MapSnapshot {
    layoutEngine.layout(map: map, selection: selection)
}
```

Pass selection into layout so `NodeVisual.isSelected` is set.

- [ ] **Step 2: Small test that snapshot marks selection, commit**

```bash
git commit -m "feat(core): MapStore.snapshot"
```

---

### Task 9: macOS app via XcodeGen

**Files:**
- Create: `Apps/SwiftMindMac/project.yml`
- Create: app sources listed below
- Create: `README.md` at repo root

- [ ] **Step 1: Install/use XcodeGen**

```bash
which xcodegen || brew install xcodegen
```

- [ ] **Step 2: Write project.yml**

```yaml
name: SwiftMindMac
options:
  bundleIdPrefix: app.swiftmind
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.10"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
packages:
  SwiftMind:
    path: ../../
targets:
  SwiftMindMac:
    type: application
    platform: macOS
    sources:
      - SwiftMindMac
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.swiftmind.mac
        PRODUCT_NAME: SwiftMind
        INFOPLIST_FILE: SwiftMindMac/Info.plist
        CODE_SIGN_ENTITLEMENTS: SwiftMindMac/SwiftMindMac.entitlements
        GENERATE_INFOPLIST_FILE: false
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
        COMBINE_HIDPI_IMAGES: true
    dependencies:
      - package: SwiftMind
        product: SwiftMindCore
    scheme:
      testTargets: []
```

- [ ] **Step 3: Info.plist document type**

`Apps/SwiftMindMac/SwiftMindMac/Info.plist` — include:

- `CFBundleDocumentTypes` for `SwiftMind Map` extension `swiftmind.html`
- `UTExportedTypeDeclarations` for `app.swiftmind.html` conforming to `public.html` / `public.data`
- `CFBundleName` SwiftMind

Minimal entitlements file (empty dict or app sandbox with user-selected files):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
</dict>
</plist>
```

- [ ] **Step 4: UTType + FileDocument**

`UTType+SwiftMind.swift`:

```swift
import UniformTypeIdentifiers

extension UTType {
    static var swiftmindHTML: UTType {
        UTType(exportedAs: "app.swiftmind.html")
    }
}
```

`SwiftMindFileDocument.swift`:

```swift
import SwiftUI
import SwiftMindCore
import UniformTypeIdentifiers

struct SwiftMindFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.swiftmindHTML, .html] }

    var map: MindMap

    init(map: MindMap = .makeEmpty(title: "Untitled")) {
        self.map = map
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let html = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.map = try HTMLCodec.decode(html)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let html = try HTMLCodec.encode(map, includeSkin: true)
        let data = Data(html.utf8)
        return .init(regularFileWithContents: data)
    }
}
```

`SwiftMindMacApp.swift`:

```swift
import SwiftUI

@main
struct SwiftMindMacApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { SwiftMindFileDocument() }) { file in
            ContentView(document: file.$document)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) { } // wire later via environment
        }
    }
}
```

- [ ] **Step 5: Generate and build**

```bash
cd Apps/SwiftMindMac && xcodegen generate
xcodebuild -scheme SwiftMindMac -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED (ContentView can be a stub `Text(document.map.title)` first).

- [ ] **Step 6: Commit**

```bash
git add Apps Package.swift README.md
git commit -m "feat(mac): DocumentGroup app shell with HTML file type"
```

---

### Task 10: Observable document bridge + outline view

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift`
- Create: `Apps/SwiftMindMac/SwiftMindMac/OutlineMapView.swift`
- Modify: `ContentView.swift`

- [ ] **Step 1: DocumentSession**

```swift
import SwiftUI
import SwiftMindCore

@MainActor
final class DocumentSession: ObservableObject {
    @Published private(set) var store: MapStore
    @Published var viewMode: ViewMode = .map

    enum ViewMode: String, CaseIterable, Identifiable {
        case map, outline
        var id: String { rawValue }
    }

    init(map: MindMap) {
        self.store = MapStore(map: map)
    }

    func syncFromDocument(_ map: MindMap) {
        store.replaceMap(map)
    }

    func exportMap() -> MindMap { store.map }

    func apply(_ command: any MapCommand) {
        do {
            try store.dispatch(command)
            objectWillChange.send()
        } catch {
            // present alert later; for M1 print
            print("command failed: \(error)")
        }
    }
}
```

**Binding pattern:** `ContentView` holds `@Binding var document: SwiftMindFileDocument` and `@StateObject private var session`. On `session.store.revision` change, set `document.map = session.exportMap()`. On document open, init session from `document.map`.

```swift
struct ContentView: View {
    @Binding var document: SwiftMindFileDocument
    @StateObject private var session: DocumentSession

    init(document: Binding<SwiftMindFileDocument>) {
        self._document = document
        _session = StateObject(wrappedValue: DocumentSession(map: document.wrappedValue.map))
    }

    var body: some View {
        NavigationSplitView {
            Text("SwiftMind")
        } detail: {
            VStack {
                Picker("View", selection: $session.viewMode) {
                    Text("Map").tag(DocumentSession.ViewMode.map)
                    Text("Outline").tag(DocumentSession.ViewMode.outline)
                }
                .pickerStyle(.segmented)
                .padding()

                switch session.viewMode {
                case .outline:
                    OutlineMapView(session: session)
                case .map:
                    MapCanvasView(session: session)
                }
            }
        }
        .onChange(of: session.store.revision) { _, _ in
            document.map = session.exportMap()
        }
        .toolbar { EditorToolbar(session: session) }
    }
}
```

Note: `MapStore.revision` must be reachable; if `store` is not observable, publish `revision` on session after each apply:

```swift
@Published private(set) var revision: UInt64 = 0
func apply(...) {
  try store.dispatch(...)
  revision = store.revision
  document sync via onChange(of: revision)
}
```

- [ ] **Step 2: OutlineMapView**

Recursive `List` or manual `OutlineGroup`-like stack:

```swift
struct OutlineMapView: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        List(selection: selectionBinding) {
            OutlineRow(node: session.store.map.root, session: session)
        }
    }
}

struct OutlineRow: View {
    let node: Node
    @ObservedObject var session: DocumentSession

    var body: some View {
        DisclosureGroup(isExpanded: foldBinding) {
            ForEach(node.children) { child in
                OutlineRow(node: child, session: session)
            }
        } label: {
            TextField("Title", text: textBinding)
        }
    }
}
```

Bindings dispatch `SetTextCommand` / `SetFoldedCommand` on commit.

- [ ] **Step 3: Build app, manual test outline edit + save, commit**

```bash
git commit -m "feat(mac): outline view bound to MapStore commands"
```

---

### Task 11: Map canvas renderer + selection + zoom/pan

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`

- [ ] **Step 1: Implement Canvas**

```swift
struct MapCanvasView: View {
    @ObservedObject var session: DocumentSession
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        let snapshot = session.store.snapshot()
        Canvas { context, size in
            context.translateBy(x: size.width/2 + offset.width, y: size.height/2 + offset.height)
            context.scaleBy(x: scale, y: scale)
            for edge in snapshot.edges {
                var path = Path()
                path.move(to: CGPoint(x: edge.fromPoint.x, y: edge.fromPoint.y))
                path.addLine(to: CGPoint(x: edge.toPoint.x, y: edge.toPoint.y))
                context.stroke(path, with: .color(.secondary), lineWidth: 1.5)
            }
            for node in snapshot.nodes {
                let rect = CGRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
                let path = Path(roundedRect: rect, cornerRadius: 8)
                if let fr = node.style.fillRed, let fg = node.style.fillGreen, let fb = node.style.fillBlue {
                    context.fill(path, with: .color(Color(red: fr, green: fg, blue: fb)))
                } else {
                    context.fill(path, with: .color(Color(nsColor: .controlBackgroundColor)))
                }
                context.stroke(path, with: .color(node.isSelected ? Color.accentColor : Color.secondary.opacity(0.5)), lineWidth: node.isSelected ? 2 : 1)
                context.draw(
                    Text(node.text).font(.system(size: node.style.fontSize, weight: node.style.isBold ? .bold : .regular)),
                    in: rect.insetBy(dx: 6, dy: 4)
                )
            }
        }
        .gesture(DragGesture().onChanged { value in
            // M1: background pan when no node hit — simplify: Option+drag pans always via simultaneous MagnifyGesture
            offset = CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height)
        })
        .gesture(MagnificationGesture().onChanged { value in
            scale = max(0.25, min(3, value))
        })
        .onTapGesture { location in
            // convert location to map coords and hit-test snapshot.nodes
            if let id = hitTest(location, snapshot: snapshot, viewSize: ...) {
                session.select(id)
            }
        }
    }
}
```

Implement hit-test by inverting pan/zoom transform. For M1, using a `GeometryReader` and storing last `size` is fine.

- [ ] **Step 2: Build, visually verify nodes and edges, commit**

```bash
git commit -m "feat(mac): canvas map renderer with pan/zoom/select"
```

---

### Task 12: Toolbar actions + keyboard shortcuts

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/EditorToolbar.swift`
- Modify: `SwiftMindMacApp.swift` / `ContentView.swift`

- [ ] **Step 1: Toolbar**

Actions:
- Add Child → `InsertChildCommand(parentID: selection.primary ?? root, text: "New Idea", side: .auto)`
- Add Sibling → `InsertSiblingCommand(...)` (if primary is root, disable or add child instead)
- Delete → `DeleteNodesCommand(nodeIDs: Array(selection.selectedIDs))`
- Fold/Unfold toggle
- Undo / Redo

```swift
.keyboardShortcut("t", modifiers: [.command]) // add child — pick shortcuts and document in README
.keyboardShortcut(.delete, modifiers: [])
.keyboardShortcut("z", modifiers: [.command]) // undo
```

Wire undo through `session.undo()` that also bumps revision and syncs document.

- [ ] **Step 2: Manual test, commit**

```bash
git commit -m "feat(mac): editor toolbar and shortcuts"
```

---

### Task 13: Drag reparent on canvas (M1 minimum)

**Files:**
- Modify: `MapCanvasView.swift`
- Uses existing `MoveNodeCommand`

- [ ] **Step 1: Interaction**

1. Mouse down on node → remember `dragID`, select it.
2. Mouse drag → show rubber-band position (visual only, optional).
3. Mouse up over another node → `MoveNodeCommand(nodeID: dragID, newParentID: target, index: end)`.
4. Mouse up over empty → cancel (no pin in M1).

- [ ] **Step 2: Unit test MoveNode already covers model; manual canvas test; commit**

```bash
git commit -m "feat(mac): drag to reparent on canvas"
```

---

### Task 14: In-place title edit + inspector basic style

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/InspectorView.swift`
- Modify: `ContentView.swift`, `MapCanvasView.swift`

- [ ] **Step 1: Double-click node → overlay TextField**

On submit: `SetTextCommand`. Escape cancels.

- [ ] **Step 2: Inspector**

```swift
Form {
  TextField("Title", text: ...)
  Slider font size 10...28
  Toggle Bold
  ColorPicker text color
  ColorPicker fill color
}
```

Dispatch `SetStyleCommand` / `SetTextCommand` on change (debounce style if needed).

- [ ] **Step 3: Put inspector in `NavigationSplitView` trailing column or `.inspector`**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(mac): in-place edit and basic style inspector"
```

---

### Task 15: Browser skin verification + README

**Files:**
- Modify: `Sources/SwiftMindCore/HTML/HTMLSkin.swift` (improve CSS if thin)
- Create: `README.md`
- Create: golden fixture after encode

- [ ] **Step 1: Ensure `includeSkin: true` on document save** (Task 9 already)

- [ ] **Step 2: Manual check**

```bash
# After saving a map from the app, open the file in Safari.
# Expect: nested indented list, titles visible, no need for SwiftMind installed.
```

- [ ] **Step 3: README**

```markdown
# SwiftMind

Native macOS mind mapping (Swift). Documents use `.swiftmind.html`.

## Develop

```bash
swift test
cd Apps/SwiftMindMac && xcodegen generate
open SwiftMindMac.xcodeproj
```

## M1 features

- Outline + map canvas
- Auto layout, fold, reparent drag
- Basic styles
- HTML save/load + read-only browser skin
```

- [ ] **Step 4: Full test + build gate**

```bash
cd /Volumes/WD/devwd/swiftmind && swift test
cd Apps/SwiftMindMac && xcodegen generate && xcodebuild -scheme SwiftMindMac -destination 'platform=macOS' build
```

Expected: all tests pass, app builds.

- [ ] **Step 5: Final commit**

```bash
git add README.md Sources Apps
git commit -m "docs: README and M1 browser skin verification notes"
```

---

### Task 16: M0/M1 acceptance checklist (no new code)

- [ ] **Step 1: Run through exit criteria**

| Criterion | Verify |
|-----------|--------|
| New map | DocumentGroup Untitled |
| Edit tree | Add child/sibling, delete, rename |
| Layout | Right/left sides, edges drawn |
| Fold | Child hidden in canvas when folded |
| Outline | Same data as canvas |
| Styles | Bold/size/color persist in HTML |
| Save/reopen | Round-trip via app |
| Browser | Open HTML, see hierarchy |
| Undo | ⌘Z restores structure/text |

- [ ] **Step 2: Tag milestone (optional)**

```bash
git tag m1-complete
```

---

## Spec coverage (M0/M1)

| Spec item | Tasks |
|-----------|-------|
| SwiftMindCore package, no UI | 1–8 |
| CommandBus + undo | 3–5 |
| HTML codec + schema v1 | 6 |
| Optional read-only skin | 6, 9, 15 |
| DocumentGroup + UTType | 9 |
| LayoutEngine + Snapshot | 7–8 |
| Canvas renderer | 11 |
| Outline shared selection | 10 |
| Insert/delete/reparent/fold | 3–4, 12–13 |
| Basic styles | 2, 4, 14 |
| Zoom/pan/select | 11 |
| macOS first, multiplatform seams | Core free of SwiftUI; intents can wait M2 for formal enum |
| Pin, notes, iCloud, formulas… | Explicitly **not** in this plan |

---

## Type consistency notes

- `NodeID.rawValue` (not `raw`)
- `MindMap.makeEmpty(title:)`
- `MapCommand` + class-based undo state
- `HTMLCodec.encode(_:includeSkin:)` / `decode(_:)`
- `LayoutEngine.layout(map:selection:)` → `MapSnapshot`
- `MapStore.dispatch` / `snapshot()` / `revision`
- Document type: `SwiftMindFileDocument` with `var map: MindMap`

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-24-swiftmind-m0-m1.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — execute tasks in this session with checkpoints  

Which approach?
