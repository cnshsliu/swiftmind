# Agent-Operable Maps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let external agent frameworks operate SwiftMind maps through a `swiftmind` CLI + hot-reload in the app, with a `SKILL.md` driver's manual — app stays zero-network.

**Architecture:** Operation primitives (`MapOp` + `BatchOps`) live in SwiftMindCore and apply through the existing `MapCommand` types, all-or-nothing. A new SPM executable target `SwiftMindCLI` (product `swiftmind`) is a thin shell over them: decode `.swiftmind.html` → apply ops → encode with skin → atomic write. The Mac app watches the open document's parent directory and hot-reloads external changes (self-write suppression via content hash, selection preserved, undo history reset per spec). v2 (MCP server over the same layer) is out of scope.

**Tech Stack:** Swift 5.10, SPM, Foundation only (zero third-party deps), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-30-agent-operable-maps-design.md`

---

## File structure

- Create `Sources/SwiftMindCore/Automation/BatchOps.swift` — `MapOp` enum, `BatchOpError`, `BatchOps.apply` runner, `MapOp: Codable` (JSON op format).
- Create `Tests/SwiftMindCoreTests/BatchOpsTests.swift` — op semantics, atomicity, Codable.
- Create `Sources/SwiftMindCLI/main.swift` — arg parsing + dispatch.
- Create `Sources/SwiftMindCLI/MapFile.swift` — load/atomic-save + JSON tree dump.
- Create `Sources/SwiftMindCLI/WriteCommands.swift` — single-op commands + batch.
- Modify `Package.swift` — add `swiftmind` executable product/target.
- Create `Apps/SwiftMindMac/SwiftMindMac/MapFileWatcher.swift` — directory watcher.
- Modify `Apps/SwiftMindMac/SwiftMindMac/AppModel.swift` — watch open doc, hot reload, self-write suppression, selection preservation.
- Create `scripts/install-cli.sh`, `scripts/test-cli.sh`.
- Create `skills/swiftmind/SKILL.md`.
- Modify `README.md`, `AGENTS.md` — document the CLI + reload behavior.

## Key API facts (verified against the codebase)

- Commands: `InsertChildCommand(parentID:newNodeID:text:side:)`, `InsertSiblingCommand(siblingID:newNodeID:text:side:)`, `SetTextCommand(nodeID:newText:)`, `SetNoteCommand(nodeID:noteMarkdown:)`, `UpsertAttributeCommand(nodeID:attribute:)`, `SetAttributesCommand(nodeID:attributes:)` (replaces all), `SetFormulaCommand(nodeID:formula:)` (nil clears), `SetFoldedCommand(nodeID:isFolded:)`, `SetPinCommand(nodeID:positionPin:)`, `MoveNodeCommand(nodeID:newParentID:index:)`, `DeleteNodesCommand(nodeIDs:)` (throws `MapCommandError.cannotDeleteRoot` for root).
- `MapCommand` protocol: `execute(on: inout MindMap) throws`, `undo(on:)`.
- `NodeID(rawValue: String)`, `NodeID.generate()` → `"n_" + 16 hex`.
- `Node` fields: `id, text, noteMarkdown, links, icons, attributes, styleName, formula, isFolded, side, style, positionPin, children`.
- `NodeSide` raw values: `"auto" | "left" | "right"`.
- `MapSearch.search(map:query:)` → `[MapSearchHit(nodeID:title:matchInNote:)]`.
- App: `DocumentSession.syncFromDocument(map)` → `store.replaceMap` (resets selection to root, clears undo). `session.select(_:)`, `session.clearSelection()` exist. `AppModel.saveCurrentMap()` writes with `.atomic`; `openMap(at:recordAsLast:)` reads the file and sets `currentMapURL`.
- `HTMLCodec.encode(_:includeSkin:)` / `decode(_:)`.

---

### Task 1: MapOp + BatchOps runner (core)

**Files:**
- Create: `Sources/SwiftMindCore/Automation/BatchOps.swift`
- Test: `Tests/SwiftMindCoreTests/BatchOpsTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SwiftMindCoreTests/BatchOpsTests.swift`:

```swift
import XCTest
@testable import SwiftMindCore

final class BatchOpsTests: XCTestCase {
    private func makeMap() -> MindMap {
        var map = MindMap.makeEmpty(title: "T")
        map.root.children = [
            Node(id: NodeID(rawValue: "n_a"), text: "A"),
            Node(id: NodeID(rawValue: "n_b"), text: "B"),
        ]
        return map
    }

    func testApplySingleSetText() throws {
        var map = makeMap()
        let affected = try BatchOps.apply([.setText(nodeID: NodeID(rawValue: "n_a"), text: "A2")], to: &map)
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_a"))?.text, "A2")
        XCTAssertEqual(affected, [NodeID(rawValue: "n_a")])
    }

    func testAddChildReturnsNewID() throws {
        var map = makeMap()
        let newID = NodeID(rawValue: "n_new")
        let affected = try BatchOps.apply(
            [.addChild(parentID: NodeID(rawValue: "n_a"), newNodeID: newID, text: "Kid", side: .auto)],
            to: &map
        )
        XCTAssertEqual(map.node(id: NodeID(rawValue: "n_a"))?.children.map(\.id), [newID])
        XCTAssertEqual(affected, [newID])
    }

    func testSetAttributeUpsertAndEmptyValueRemoves() throws {
        var map = makeMap()
        let a = NodeID(rawValue: "n_a")
        try BatchOps.apply([.setAttribute(nodeID: a, name: "status", value: "done")], to: &map)
        XCTAssertEqual(map.node(id: a)?.attributes.first?.value, "done")
        try BatchOps.apply([.setAttribute(nodeID: a, name: "status", value: "wip")], to: &map)
        XCTAssertEqual(map.node(id: a)?.attributes.count, 1)
        XCTAssertEqual(map.node(id: a)?.attributes.first?.value, "wip")
        try BatchOps.apply([.setAttribute(nodeID: a, name: "status", value: "")], to: &map)
        XCTAssertEqual(map.node(id: a)?.attributes.count, 0)
    }

    func testSetFormulaEmptyClears() throws {
        var map = makeMap()
        let a = NodeID(rawValue: "n_a")
        try BatchOps.apply([.setFormula(nodeID: a, formula: "count(children)")], to: &map)
        XCTAssertEqual(map.node(id: a)?.formula, "count(children)")
        try BatchOps.apply([.setFormula(nodeID: a, formula: "")], to: &map)
        XCTAssertNil(map.node(id: a)?.formula)
    }

    func testAtomicityFailureLeavesMapUntouched() throws {
        var map = makeMap()
        let original = map
        let ops: [MapOp] = [
            .setText(nodeID: NodeID(rawValue: "n_a"), text: "CHANGED"),
            .setText(nodeID: NodeID(rawValue: "n_missing"), text: "boom"),
        ]
        XCTAssertThrowsError(try BatchOps.apply(ops, to: &map)) { error in
            guard let batchError = error as? BatchOpError else {
                return XCTFail("expected BatchOpError, got \(error)")
            }
            XCTAssertEqual(batchError.opIndex, 1)
            XCTAssertEqual(batchError.opName, "set-text")
        }
        XCTAssertEqual(map, original, "failed batch must leave the map byte-identical")
    }

    func testDeleteRootIsRejected() throws {
        var map = makeMap()
        XCTAssertThrowsError(
            try BatchOps.apply([.delete(nodeIDs: [map.root.id])], to: &map)
        )
    }

    func testMoveAndFoldAndPin() throws {
        var map = makeMap()
        let a = NodeID(rawValue: "n_a")
        let b = NodeID(rawValue: "n_b")
        try BatchOps.apply([
            .move(nodeID: a, newParentID: b, index: 0),
            .setFolded(nodeID: b, isFolded: true),
            .setPin(nodeID: b, position: Point2D(x: 10, y: -20)),
        ], to: &map)
        XCTAssertEqual(map.node(id: b)?.children.map(\.id), [a])
        XCTAssertEqual(map.node(id: b)?.isFolded, true)
        XCTAssertEqual(map.node(id: b)?.positionPin, Point2D(x: 10, y: -20))
        try BatchOps.apply([.setPin(nodeID: b, position: nil)], to: &map)
        XCTAssertNil(map.node(id: b)?.positionPin)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BatchOpsTests`
Expected: FAIL — compile error, `BatchOps` / `MapOp` do not exist.

- [ ] **Step 3: Implement BatchOps**

Create `Sources/SwiftMindCore/Automation/BatchOps.swift`:

```swift
import Foundation

/// One machine-authored map operation (CLI batch ops, future MCP calls).
public enum MapOp: Equatable, Sendable {
    case addChild(parentID: NodeID, newNodeID: NodeID, text: String, side: NodeSide)
    case addSibling(siblingID: NodeID, newNodeID: NodeID, text: String)
    case setText(nodeID: NodeID, text: String)
    case setNote(nodeID: NodeID, markdown: String)
    /// Empty value removes the attribute.
    case setAttribute(nodeID: NodeID, name: String, value: String)
    /// nil or empty formula clears it.
    case setFormula(nodeID: NodeID, formula: String?)
    case setFolded(nodeID: NodeID, isFolded: Bool)
    case setPin(nodeID: NodeID, position: Point2D?)
    case move(nodeID: NodeID, newParentID: NodeID, index: Int)
    case delete(nodeIDs: [NodeID])

    /// Stable wire name, also used in error reports.
    public var name: String {
        switch self {
        case .addChild: return "add-child"
        case .addSibling: return "add-sibling"
        case .setText: return "set-text"
        case .setNote: return "set-note"
        case .setAttribute: return "set-attr"
        case .setFormula: return "set-formula"
        case .setFolded(let _, let folded): return folded ? "fold" : "unfold"
        case .setPin(let _, let pos): return pos == nil ? "unpin" : "pin"
        case .move: return "move"
        case .delete: return "delete"
        }
    }
}

/// Batch failure: which op failed and why. The map is left untouched.
public struct BatchOpError: Error, Equatable {
    public let opIndex: Int
    public let opName: String
    public let message: String

    public init(opIndex: Int, opName: String, message: String) {
        self.opIndex = opIndex
        self.opName = opName
        self.message = message
    }
}

/// Applies `MapOp`s through the existing command types — all validation is inherited.
public enum BatchOps {
    /// All-or-nothing: ops run on a copy; `map` is swapped in only on full success.
    /// Returns the ids affected by the run (in op order).
    @discardableResult
    public static func apply(_ ops: [MapOp], to map: inout MindMap) throws -> [NodeID] {
        var working = map
        var affected: [NodeID] = []
        for (index, op) in ops.enumerated() {
            do {
                affected.append(contentsOf: try applyOne(op, to: &working))
            } catch {
                throw BatchOpError(
                    opIndex: index,
                    opName: op.name,
                    message: String(describing: error)
                )
            }
        }
        map = working
        return affected
    }

    private static func applyOne(_ op: MapOp, to map: inout MindMap) throws -> [NodeID] {
        switch op {
        case let .addChild(parentID, newNodeID, text, side):
            try InsertChildCommand(parentID: parentID, newNodeID: newNodeID, text: text, side: side)
                .execute(on: &map)
            return [newNodeID]
        case let .addSibling(siblingID, newNodeID, text):
            try InsertSiblingCommand(siblingID: siblingID, newNodeID: newNodeID, text: text)
                .execute(on: &map)
            return [newNodeID]
        case let .setText(nodeID, text):
            try SetTextCommand(nodeID: nodeID, newText: text).execute(on: &map)
            return [nodeID]
        case let .setNote(nodeID, markdown):
            try SetNoteCommand(nodeID: nodeID, noteMarkdown: markdown).execute(on: &map)
            return [nodeID]
        case let .setAttribute(nodeID, name, value):
            if value.isEmpty {
                guard let node = map.node(id: nodeID) else {
                    throw MapCommandError.nodeNotFound(nodeID)
                }
                let remaining = node.attributes.filter { $0.name != name }
                try SetAttributesCommand(nodeID: nodeID, attributes: remaining).execute(on: &map)
            } else {
                try UpsertAttributeCommand(
                    nodeID: nodeID,
                    attribute: NodeAttribute(name: name, value: value)
                ).execute(on: &map)
            }
            return [nodeID]
        case let .setFormula(nodeID, formula):
            let normalized = (formula ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try SetFormulaCommand(nodeID: nodeID, formula: normalized.isEmpty ? nil : normalized)
                .execute(on: &map)
            return [nodeID]
        case let .setFolded(nodeID, isFolded):
            try SetFoldedCommand(nodeID: nodeID, isFolded: isFolded).execute(on: &map)
            return [nodeID]
        case let .setPin(nodeID, position):
            try SetPinCommand(nodeID: nodeID, positionPin: position).execute(on: &map)
            return [nodeID]
        case let .move(nodeID, newParentID, index):
            try MoveNodeCommand(nodeID: nodeID, newParentID: newParentID, index: index)
                .execute(on: &map)
            return [nodeID]
        case let .delete(nodeIDs):
            try DeleteNodesCommand(nodeIDs: nodeIDs).execute(on: &map)
            return nodeIDs
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BatchOpsTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Automation/BatchOps.swift Tests/SwiftMindCoreTests/BatchOpsTests.swift
git commit -m "feat(core): MapOp + BatchOps all-or-nothing runner for machine-authored ops"
```

---

### Task 2: MapOp JSON Codable (op wire format)

**Files:**
- Modify: `Sources/SwiftMindCore/Automation/BatchOps.swift`
- Test: `Tests/SwiftMindCoreTests/BatchOpsTests.swift`

Wire format (one JSON object per op; `id` optional on add ops — generated when absent):

```json
{"op":"add-child","parent":"n_x","id":"n_new","text":"…","side":"auto"}
{"op":"add-sibling","sibling":"n_x","id":"n_new","text":"…"}
{"op":"set-text","id":"n_x","text":"…"}
{"op":"set-note","id":"n_x","markdown":"…"}
{"op":"set-attr","id":"n_x","name":"status","value":"done"}
{"op":"set-formula","id":"n_x","formula":"sum(children, attr: \"x\")"}
{"op":"fold","id":"n_x"}   {"op":"unfold","id":"n_x"}
{"op":"pin","id":"n_x","x":12.5,"y":-3}   {"op":"unpin","id":"n_x"}
{"op":"move","id":"n_x","to":"n_y","index":0}
{"op":"delete","ids":["n_x","n_y"]}
```

- [ ] **Step 1: Write the failing tests**

Append to `BatchOpsTests.swift`:

```swift
    private func decodeOps(_ json: String) throws -> [MapOp] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([MapOp].self, from: data)
    }

    func testDecodeAllOpKinds() throws {
        let ops = try decodeOps("""
        [
          {"op":"add-child","parent":"n_x","id":"n_new","text":"Kid","side":"left"},
          {"op":"add-sibling","sibling":"n_x","text":"Sib"},
          {"op":"set-text","id":"n_x","text":"T"},
          {"op":"set-note","id":"n_x","markdown":"M"},
          {"op":"set-attr","id":"n_x","name":"status","value":"done"},
          {"op":"set-formula","id":"n_x","formula":"count(children)"},
          {"op":"fold","id":"n_x"},
          {"op":"unfold","id":"n_x"},
          {"op":"pin","id":"n_x","x":12.5,"y":-3},
          {"op":"unpin","id":"n_x"},
          {"op":"move","id":"n_x","to":"n_y","index":2},
          {"op":"delete","ids":["n_x","n_y"]}
        ]
        """)
        XCTAssertEqual(ops.count, 12)
        XCTAssertEqual(ops[0], .addChild(
            parentID: NodeID(rawValue: "n_x"),
            newNodeID: NodeID(rawValue: "n_new"),
            text: "Kid",
            side: .left
        ))
        // add-sibling without id generates one
        if case let .addSibling(_, generated, _) = ops[1] {
            XCTAssertFalse(generated.rawValue.isEmpty)
        } else {
            XCTFail("op[1] should be addSibling")
        }
        XCTAssertEqual(ops[4], .setAttribute(nodeID: NodeID(rawValue: "n_x"), name: "status", value: "done"))
        XCTAssertEqual(ops[6], .setFolded(nodeID: NodeID(rawValue: "n_x"), isFolded: true))
        XCTAssertEqual(ops[7], .setFolded(nodeID: NodeID(rawValue: "n_x"), isFolded: false))
        XCTAssertEqual(ops[8], .setPin(nodeID: NodeID(rawValue: "n_x"), position: Point2D(x: 12.5, y: -3)))
        XCTAssertEqual(ops[9], .setPin(nodeID: NodeID(rawValue: "n_x"), position: nil))
        XCTAssertEqual(ops[10], .move(nodeID: NodeID(rawValue: "n_x"), newParentID: NodeID(rawValue: "n_y"), index: 2))
        XCTAssertEqual(ops[11], .delete(nodeIDs: [NodeID(rawValue: "n_x"), NodeID(rawValue: "n_y")]))
    }

    func testDecodeUnknownOpThrows() {
        XCTAssertThrowsError(try decodeOps(#"[{"op":"explode","id":"n_x"}]"#))
    }

    func testDecodeMissingRequiredFieldThrows() {
        XCTAssertThrowsError(try decodeOps(#"[{"op":"set-text","id":"n_x"}]"#))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BatchOpsTests`
Expected: FAIL — `MapOp` is not `Decodable`.

- [ ] **Step 3: Implement Codable**

Append to `Sources/SwiftMindCore/Automation/BatchOps.swift`:

```swift
extension MapOp: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, parent, sibling, id, ids, text, side, markdown, name, value, formula, folded, x, y, to, index
    }

    private enum WireError: Error, CustomStringConvertible {
        case unknownOp(String)
        case missingField(String, op: String)

        var description: String {
            switch self {
            case .unknownOp(let op): return "unknown op \"\(op)\""
            case .missingField(let field, let op): return "op \"\(op)\" missing required field \"\(field)\""
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)

        func nodeID(_ key: CodingKeys) throws -> NodeID {
            guard let raw = try c.decodeIfPresent(String.self, forKey: key) else {
                throw WireError.missingField(key.rawValue, op: op)
            }
            return NodeID(rawValue: raw)
        }
        func string(_ key: CodingKeys) throws -> String {
            guard let value = try c.decodeIfPresent(String.self, forKey: key) else {
                throw WireError.missingField(key.rawValue, op: op)
            }
            return value
        }
        func generatedID() throws -> NodeID {
            if let raw = try c.decodeIfPresent(String.self, forKey: .id) {
                return NodeID(rawValue: raw)
            }
            return .generate()
        }

        switch op {
        case "add-child":
            let side = try c.decodeIfPresent(String.self, forKey: .side)
                .flatMap { NodeSide(rawValue: $0) } ?? .auto
            self = .addChild(
                parentID: try nodeID(.parent),
                newNodeID: try generatedID(),
                text: try string(.text),
                side: side
            )
        case "add-sibling":
            self = .addSibling(
                siblingID: try nodeID(.sibling),
                newNodeID: try generatedID(),
                text: try string(.text)
            )
        case "set-text":
            self = .setText(nodeID: try nodeID(.id), text: try string(.text))
        case "set-note":
            self = .setNote(nodeID: try nodeID(.id), markdown: try string(.markdown))
        case "set-attr":
            self = .setAttribute(
                nodeID: try nodeID(.id),
                name: try string(.name),
                value: c.decodeIfPresent(String.self, forKey: .value) ?? ""
            )
        case "set-formula":
            self = .setFormula(
                nodeID: try nodeID(.id),
                formula: try c.decodeIfPresent(String.self, forKey: .formula)
            )
        case "fold":
            self = .setFolded(nodeID: try nodeID(.id), isFolded: true)
        case "unfold":
            self = .setFolded(nodeID: try nodeID(.id), isFolded: false)
        case "pin":
            guard let x = try c.decodeIfPresent(Double.self, forKey: .x),
                  let y = try c.decodeIfPresent(Double.self, forKey: .y) else {
                throw WireError.missingField("x/y", op: op)
            }
            self = .setPin(nodeID: try nodeID(.id), position: Point2D(x: x, y: y))
        case "unpin":
            self = .setPin(nodeID: try nodeID(.id), position: nil)
        case "move":
            self = .move(
                nodeID: try nodeID(.id),
                newParentID: try nodeID(.to),
                index: try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
            )
        case "delete":
            if let ids = try c.decodeIfPresent([String].self, forKey: .ids) {
                self = .delete(nodeIDs: ids.map { NodeID(rawValue: $0) })
            } else {
                self = .delete(nodeIDs: [try nodeID(.id)])
            }
        default:
            throw WireError.unknownOp(op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .op)
        switch self {
        case let .addChild(parentID, newNodeID, text, side):
            try c.encode(parentID.rawValue, forKey: .parent)
            try c.encode(newNodeID.rawValue, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(side.rawValue, forKey: .side)
        case let .addSibling(siblingID, newNodeID, text):
            try c.encode(siblingID.rawValue, forKey: .sibling)
            try c.encode(newNodeID.rawValue, forKey: .id)
            try c.encode(text, forKey: .text)
        case let .setText(nodeID, text):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(text, forKey: .text)
        case let .setNote(nodeID, markdown):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(markdown, forKey: .markdown)
        case let .setAttribute(nodeID, name, value):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(value, forKey: .value)
        case let .setFormula(nodeID, formula):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encodeIfPresent(formula, forKey: .formula)
        case let .setFolded(nodeID, isFolded):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(isFolded, forKey: .folded)
        case let .setPin(nodeID, position):
            try c.encode(nodeID.rawValue, forKey: .id)
            if let position {
                try c.encode(position.x, forKey: .x)
                try c.encode(position.y, forKey: .y)
            }
        case let .move(nodeID, newParentID, index):
            try c.encode(nodeID.rawValue, forKey: .id)
            try c.encode(newParentID.rawValue, forKey: .to)
            try c.encode(index, forKey: .index)
        case let .delete(nodeIDs):
            try c.encode(nodeIDs.map(\.rawValue), forKey: .ids)
        }
    }
}
```

Note: `setFolded` encodes its op name as `fold`/`unfold` (via `name`), and decoding accepts those two spellings — round-trip holds.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BatchOpsTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Automation/BatchOps.swift Tests/SwiftMindCoreTests/BatchOpsTests.swift
git commit -m "feat(core): MapOp JSON wire format (Codable) for agent batch ops"
```

---

### Task 3: CLI target skeleton — `read` + `validate`

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SwiftMindCLI/main.swift`
- Create: `Sources/SwiftMindCLI/MapFile.swift`

- [ ] **Step 1: Register the executable target**

Replace `Package.swift` with:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftMind",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftMindCore", targets: ["SwiftMindCore"]),
        .executable(name: "swiftmind", targets: ["SwiftMindCLI"])
    ],
    targets: [
        .target(
            name: "SwiftMindCore",
            path: "Sources/SwiftMindCore"
        ),
        .executableTarget(
            name: "SwiftMindCLI",
            dependencies: ["SwiftMindCore"],
            path: "Sources/SwiftMindCLI"
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

- [ ] **Step 2: Write MapFile.swift (load / atomic save / JSON dump)**

Create `Sources/SwiftMindCLI/MapFile.swift`:

```swift
import Foundation
import SwiftMindCore

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case file(String)
    case op(String)

    var description: String {
        switch self {
        case .usage(let m), .file(let m), .op(let m): return m
        }
    }

    var code: String {
        switch self {
        case .usage: return "usage"
        case .file: return "file_error"
        case .op: return "op_error"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return 1
        case .file: return 2
        case .op: return 3
        }
    }
}

enum MapFile {
    static func load(_ path: String) throws -> MindMap {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            throw CLIError.file("cannot read \(path)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CLIError.file("not UTF-8: \(path)")
        }
        do {
            return try HTMLCodec.decode(html)
        } catch {
            throw CLIError.file("not a SwiftMind map: \(path) (\(error.localizedDescription))")
        }
    }

    /// Atomic write (temp file + rename via .atomic) so the app's file watcher
    /// sees exactly one change event and never a partial file.
    static func save(_ map: MindMap, to path: String) throws {
        let html: String
        do {
            html = try HTMLCodec.encode(map, includeSkin: true)
        } catch {
            throw CLIError.op("encode failed: \(error.localizedDescription)")
        }
        do {
            try Data(html.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw CLIError.file("cannot write \(path): \(error.localizedDescription)")
        }
    }

    /// JSON tree for `read`: id, text, note?, attributes?, formula?, folded?, side, children?
    static func jsonObject(for map: MindMap) -> [String: Any] {
        [
            "id": map.id,
            "title": map.title,
            "schemaVersion": map.schemaVersion,
            "root": nodeJSON(map.root),
        ]
    }

    private static func nodeJSON(_ node: Node) -> [String: Any] {
        var dict: [String: Any] = [
            "id": node.id.rawValue,
            "text": node.text,
        ]
        if !node.noteMarkdown.isEmpty { dict["note"] = node.noteMarkdown }
        if !node.attributes.isEmpty {
            dict["attributes"] = node.attributes.map { ["name": $0.name, "value": $0.value] }
        }
        if let formula = node.formula { dict["formula"] = formula }
        if node.isFolded { dict["folded"] = true }
        if node.side != .auto { dict["side"] = node.side.rawValue }
        if node.positionPin != nil { dict["pinned"] = true }
        if !node.children.isEmpty { dict["children"] = node.children.map(nodeJSON) }
        return dict
    }

    static func printJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data(#"{"error":{"code":"internal","message":"JSON encoding failed"}}"#.utf8))
            exit(3)
        }
        print(text)
    }

    static func fail(_ error: CLIError) -> Never {
        let payload: [String: Any] = ["error": ["code": error.code, "message": error.description]]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
        exit(error.exitCode)
    }
}
```

- [ ] **Step 3: Write main.swift with read + validate dispatch**

Create `Sources/SwiftMindCLI/main.swift`:

```swift
import Foundation
import SwiftMindCore

// swiftmind <command> <file> [flags]
// Commands: read, find, validate, add-child, add-sibling, set-text, set-note,
//           set-attr, set-formula, fold, unfold, pin, unpin, move, delete, batch

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    MapFile.fail(.usage("""
    usage: swiftmind <command> <file> [flags]
      read <file>                      print the map as a JSON tree
      find <file> --query <text>       search titles/notes, print matching node ids
      validate <file>                  decode + re-encode check
      add-child <file> --parent <id> --text <t> [--side auto|left|right] [--id <newid>]
      add-sibling <file> --of <id> --text <t> [--id <newid>]
      set-text <file> --id <id> --text <t>
      set-note <file> --id <id> --markdown <md>
      set-attr <file> --id <id> --name <n> --value <v>   (empty value removes)
      set-formula <file> --id <id> --formula <f>          (empty clears)
      fold|unfold <file> --id <id>
      pin <file> --id <id> --x <n> --y <n> | unpin <file> --id <id>
      move <file> --id <id> --to <parentId> [--index <n>]
      delete <file> --ids <id,id,...>
      batch <file> [ops.json]          ops from file or stdin; all-or-nothing
    """))
}

/// Parse `--flag value` pairs and bare `--flag` booleans (value "true").
func parseFlags(_ args: [String]) -> [String: String] {
    var flags: [String: String] = [:]
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let name = String(arg.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                flags[name] = args[i + 1]
                i += 2
            } else {
                flags[name] = "true"
                i += 1
            }
        } else {
            i += 1
        }
    }
    return flags
}

guard args.count >= 2 else { usage() }
let command = args[0]
let path = args[1]
let flags = parseFlags(Array(args.dropFirst(2)))

do {
    switch command {
    case "read":
        let map = try MapFile.load(path)
        MapFile.printJSON(MapFile.jsonObject(for: map))
    case "validate":
        let map = try MapFile.load(path)
        _ = try HTMLCodec.encode(map, includeSkin: false)
        MapFile.printJSON(["ok": true, "file": path])
    case "find":
        let map = try MapFile.load(path)
        guard let query = flags["query"] else {
            throw CLIError.usage("find requires --query")
        }
        let hits = MapSearch.search(map: map, query: query)
        MapFile.printJSON(hits.map {
            ["id": $0.nodeID.rawValue, "title": $0.title, "matchInNote": $0.matchInNote]
        })
    default:
        try WriteCommands.run(command: command, path: path, flags: flags)
    }
} catch let error as CLIError {
    MapFile.fail(error)
} catch let error as BatchOpError {
    FileHandle.standardError.write(Data(
        ("""
        {"error":{"code":"op_error","message":"\(error.message)","opIndex":\(error.opIndex),"op":"\(error.opName)"}}
        """ + "\n").utf8
    ))
    exit(3)
} catch {
    MapFile.fail(.op(error.localizedDescription))
}
```

- [ ] **Step 4: Stub WriteCommands so it compiles, then build**

Create `Sources/SwiftMindCLI/WriteCommands.swift` with just:

```swift
import Foundation

enum WriteCommands {
    static func run(command: String, path: String, flags: [String: String]) throws {
        throw CLIError.usage("unknown or unimplemented command: \(command)")
    }
}
```

Run: `swift build`
Expected: BUILD SUCCEEDED. (The app target is unaffected — verify `swift test --filter MapStoreTests` still passes.)

- [ ] **Step 5: Smoke-test read/validate by hand**

```bash
swift build
.build/debug/swiftmind read Tests/SwiftMindCoreTests/Fixtures/minimal.swiftmind.html
.build/debug/swiftmind validate Tests/SwiftMindCoreTests/Fixtures/minimal.swiftmind.html
```

Expected: `read` prints a JSON tree with `"root"`; `validate` prints `{"ok": true, ...}`. If the fixture's name differs, `ls Tests/SwiftMindCoreTests/Fixtures/` first.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/SwiftMindCLI/
git commit -m "feat(cli): swiftmind executable — read, find, validate"
```

---

### Task 4: CLI write commands + batch

**Files:**
- Modify: `Sources/SwiftMindCLI/WriteCommands.swift`

- [ ] **Step 1: Implement all write commands**

Replace `Sources/SwiftMindCLI/WriteCommands.swift` with:

```swift
import Foundation
import SwiftMindCore

enum WriteCommands {
    static func run(command: String, path: String, flags: [String: String]) throws {
        func required(_ name: String) throws -> String {
            guard let value = flags[name] else {
                throw CLIError.usage("\(command) requires --\(name)")
            }
            return value
        }
        func id(_ name: String) throws -> NodeID {
            NodeID(rawValue: try required(name))
        }

        let ops: [MapOp]
        switch command {
        case "add-child":
            let side = flags["side"].flatMap { NodeSide(rawValue: $0) } ?? .auto
            ops = [.addChild(
                parentID: try id("parent"),
                newNodeID: flags["id"].map { NodeID(rawValue: $0) } ?? .generate(),
                text: try required("text"),
                side: side
            )]
        case "add-sibling":
            ops = [.addSibling(
                siblingID: try id("of"),
                newNodeID: flags["id"].map { NodeID(rawValue: $0) } ?? .generate(),
                text: try required("text")
            )]
        case "set-text":
            ops = [.setText(nodeID: try id("id"), text: try required("text"))]
        case "set-note":
            ops = [.setNote(nodeID: try id("id"), markdown: try required("markdown"))]
        case "set-attr":
            ops = [.setAttribute(
                nodeID: try id("id"),
                name: try required("name"),
                value: flags["value"] ?? ""
            )]
        case "set-formula":
            ops = [.setFormula(nodeID: try id("id"), formula: flags["formula"])]
        case "fold":
            ops = [.setFolded(nodeID: try id("id"), isFolded: true)]
        case "unfold":
            ops = [.setFolded(nodeID: try id("id"), isFolded: false)]
        case "pin":
            guard let x = Double(try required("x")), let y = Double(try required("y")) else {
                throw CLIError.usage("pin requires numeric --x and --y")
            }
            ops = [.setPin(nodeID: try id("id"), position: Point2D(x: x, y: y))]
        case "unpin":
            ops = [.setPin(nodeID: try id("id"), position: nil)]
        case "move":
            ops = [.move(
                nodeID: try id("id"),
                newParentID: try id("to"),
                index: flags["index"].flatMap { Int($0) } ?? 0
            )]
        case "delete":
            let ids = try required("ids")
                .split(separator: ",")
                .map { NodeID(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else { throw CLIError.usage("delete requires --ids") }
            ops = [.delete(nodeIDs: ids)]
        case "batch":
            ops = try loadBatchOps(path: path, args: flags)
        default:
            throw CLIError.usage("unknown command: \(command)")
        }

        var map = try MapFile.load(path)
        let affected = try BatchOps.apply(ops, to: &map)
        try MapFile.save(map, to: path)
        MapFile.printJSON(["ok": true, "affected": affected.map(\.rawValue)])
    }

    /// `swiftmind batch <file> [ops.json]` — ops from the positional JSON file
    /// or stdin ("-"). Flags arrive positionally after <file>, so we re-read
    /// Process arguments for a non-flag third argument.
    private static func loadBatchOps(path: String, flags: [String: String]) throws -> [MapOp] {
        let positional = CommandLine.arguments.dropFirst(3).filter { !$0.hasPrefix("--") }
        let data: Data
        if let opsPath = positional.first, opsPath != "-" {
            guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: opsPath)) else {
                throw CLIError.file("cannot read ops file \(opsPath)")
            }
            data = fileData
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        do {
            let ops = try JSONDecoder().decode([MapOp].self, from: data)
            guard !ops.isEmpty else { throw CLIError.usage("batch ops array is empty") }
            return ops
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.usage("invalid ops JSON: \(error.localizedDescription)")
        }
    }
}
```

Note: `loadBatchOps` re-reads `CommandLine.arguments` because `parseFlags` drops positional args; `dropFirst(3)` skips `swiftmind batch <file>`.

- [ ] **Step 2: Build and hand-test a mutation on a scratch copy**

```bash
swift build
cp Tests/SwiftMindCoreTests/Fixtures/minimal.swiftmind.html /tmp/sm-test.swiftmind.html
ROOT=$(.build/debug/swiftmind read /tmp/sm-test.swiftmind.html | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"]["id"])')
.build/debug/swiftmind add-child /tmp/sm-test.swiftmind.html --parent "$ROOT" --text "From CLI" --id n_cli1
.build/debug/swiftmind set-attr /tmp/sm-test.swiftmind.html --id n_cli1 --name status --value done
.build/debug/swiftmind find /tmp/sm-test.swiftmind.html --query "CLI"
echo '[{"op":"set-text","id":"n_cli1","text":"Renamed"},{"op":"fold","id":"n_cli1"}]' | .build/debug/swiftmind batch /tmp/sm-test.swiftmind.html
.build/debug/swiftmind read /tmp/sm-test.swiftmind.html | grep -c "Renamed"
```

Expected: every command prints `{"ok":true,...}`; the final grep prints `1`.

Also test failure atomicity:

```bash
echo '[{"op":"set-text","id":"n_cli1","text":"X"},{"op":"delete","ids":["n_nope"]}]' | .build/debug/swiftmind batch /tmp/sm-test.swiftmind.html; echo "exit=$?"
.build/debug/swiftmind read /tmp/sm-test.swiftmind.html | grep -c '"text" : "X"' || echo "unchanged-ok"
```

Expected: `exit=3`, then `unchanged-ok` (the first op was rolled back).

- [ ] **Step 3: Commit**

```bash
git add Sources/SwiftMindCLI/WriteCommands.swift
git commit -m "feat(cli): write commands + atomic batch ops"
```

---

### Task 5: install-cli.sh + test-cli.sh smoke script

**Files:**
- Create: `scripts/install-cli.sh`
- Create: `scripts/test-cli.sh`

- [ ] **Step 1: Write install-cli.sh**

```bash
#!/usr/bin/env bash
# Build and install the swiftmind CLI to ~/.local/bin (no sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product swiftmind
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cp "$ROOT/.build/release/swiftmind" "$BIN_DIR/swiftmind"
echo "Installed swiftmind to $BIN_DIR/swiftmind"
echo "Ensure $BIN_DIR is on your PATH."
```

- [ ] **Step 2: Write test-cli.sh**

```bash
#!/usr/bin/env bash
# Smoke test for the swiftmind CLI against a scratch copy of the golden fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product swiftmind >/dev/null
CLI="$ROOT/.build/debug/swiftmind"
FIXTURE="$(ls "$ROOT"/Tests/SwiftMindCoreTests/Fixtures/*.swiftmind.html | head -1)"
WORK="$(mktemp -d)/smoke.swiftmind.html"
cp "$FIXTURE" "$WORK"

fail() { echo "FAIL: $1" >&2; exit 1; }

# read + validate
"$CLI" read "$WORK" >/dev/null || fail "read"
"$CLI" validate "$WORK" >/dev/null || fail "validate"

ROOT_ID=$("$CLI" read "$WORK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"]["id"])')
[ -n "$ROOT_ID" ] || fail "root id"

# add-child + find
"$CLI" add-child "$WORK" --parent "$ROOT_ID" --text "CLI Smoke Node" --id n_smoke >/dev/null || fail "add-child"
"$CLI" find "$WORK" --query "Smoke" | grep -q n_smoke || fail "find"

# set-attr + set-formula
"$CLI" set-attr "$WORK" --id n_smoke --name status --value done >/dev/null || fail "set-attr"
"$CLI" set-formula "$WORK" --id n_smoke --formula "count(children)" >/dev/null || fail "set-formula"

# batch: rename + fold, then delete via batch
echo '[{"op":"set-text","id":"n_smoke","text":"Renamed Smoke"},{"op":"fold","id":"n_smoke"}]' \
  | "$CLI" batch "$WORK" >/dev/null || fail "batch"
"$CLI" read "$WORK" | grep -q "Renamed Smoke" || fail "batch applied"

# atomicity: failing batch leaves file unchanged
BEFORE=$(shasum "$WORK" | cut -d' ' -f1)
if echo '[{"op":"set-text","id":"n_smoke","text":"X"},{"op":"delete","ids":["n_nope"]}]' | "$CLI" batch "$WORK" 2>/dev/null; then
  fail "failing batch should exit non-zero"
fi
AFTER=$(shasum "$WORK" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] || fail "batch not atomic"

# delete + pin/unpin + move
"$CLI" add-child "$WORK" --parent "$ROOT_ID" --text "To Move" --id n_move >/dev/null
"$CLI" move "$WORK" --id n_move --to n_smoke --index 0 >/dev/null || fail "move"
"$CLI" pin "$WORK" --id n_move --x 10 --y -20 >/dev/null || fail "pin"
"$CLI" unpin "$WORK" --id n_move >/dev/null || fail "unpin"
"$CLI" delete "$WORK" --ids n_move >/dev/null || fail "delete"
"$CLI" find "$WORK" --query "To Move" | grep -q '\[\]' || fail "delete verified"

# validate the final file still parses
"$CLI" validate "$WORK" >/dev/null || fail "final validate"

echo "CLI smoke test OK"
```

- [ ] **Step 3: Run both scripts**

```bash
chmod +x scripts/install-cli.sh scripts/test-cli.sh
./scripts/test-cli.sh
./scripts/install-cli.sh
```

Expected: `CLI smoke test OK`, then `Installed swiftmind to ~/.local/bin/swiftmind`.

- [ ] **Step 4: Commit**

```bash
git add scripts/install-cli.sh scripts/test-cli.sh
git commit -m "chore(scripts): install + smoke-test scripts for the swiftmind CLI"
```

---

### Task 6: App hot reload (MapFileWatcher + AppModel wiring)

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/MapFileWatcher.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/AppModel.swift`

- [ ] **Step 1: Write MapFileWatcher**

Create `Apps/SwiftMindMac/SwiftMindMac/MapFileWatcher.swift`:

```swift
import Foundation

/// Watches a file's parent directory for external modifications.
/// Atomic saves (temp + rename) replace the inode, so the file itself
/// cannot be watched reliably — the directory is.
final class MapFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private(set) var watchedPath: String?
    var onChange: (() -> Void)?

    func watch(url: URL) {
        stop()
        let dir = url.deletingLastPathComponent().path
        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedPath = url.path
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.onChange?()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
        watchedPath = nil
    }

    deinit { stop() }
}
```

- [ ] **Step 2: Wire hot reload into AppModel**

In `Apps/SwiftMindMac/SwiftMindMac/AppModel.swift`:

Add properties (next to `private var saveTask`):

```swift
    private let fileWatcher = MapFileWatcher()
    private var reloadTask: Task<Void, Never>?
    /// Hash of the file content we last read or wrote — watcher events whose
    /// content matches are our own saves and are ignored.
    private var lastKnownFileHash: Int?
```

Add the reload machinery (new section at the end, before the closing brace):

```swift
    // MARK: - External change watching (agent CLI writes)

    private func startWatching(url: URL) {
        fileWatcher.onChange = { [weak self] in
            self?.scheduleExternalReload()
        }
        fileWatcher.watch(url: url)
    }

    private func stopWatching() {
        reloadTask?.cancel()
        reloadTask = nil
        fileWatcher.stop()
        lastKnownFileHash = nil
    }

    private func scheduleExternalReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self.reloadIfExternallyChanged()
        }
    }

    private func reloadIfExternallyChanged() {
        guard !isBrainMode, let url = currentMapURL,
              let data = try? Data(contentsOf: url) else { return }
        let hash = data.hashValue
        guard hash != lastKnownFileHash else { return }
        guard let html = String(data: data, encoding: .utf8),
              let map = try? HTMLCodec.decode(html) else { return }
        lastKnownFileHash = hash

        let selected = session.store.selection.primary
        suppressAutosave = true
        session.syncFromDocument(map)
        if let selected, session.store.map.node(id: selected) != nil {
            session.select(selected)
        } else {
            session.clearSelection()
        }
        suppressAutosave = false
        session.showToast("Updated by external agent", kind: .info)
    }
```

Hook the watcher into the open/save/brain paths:

In `openMap(at:recordAsLast:)`, inside the success path right after `wireSession()`:

```swift
            if let data = try? Data(contentsOf: url) {
                lastKnownFileHash = data.hashValue
            }
            startWatching(url: url)
```

In `saveCurrentMap()`, replace the write so the hash is recorded:

```swift
        do {
            let html = try HTMLCodec.encode(session.exportMap(), includeSkin: true)
            let data = Data(html.utf8)
            try data.write(to: url, options: .atomic)
            lastKnownFileHash = data.hashValue
            library.lastMapURL = url
        } catch {
```

In `showBrain()`, add at the top (right after `persistCurrentMapIfNeeded()`):

```swift
        stopWatching()
```

- [ ] **Step 3: Build the app and hand-verify the loop**

```bash
./scripts/rerun-mac.sh --no-test
# In another terminal, with the app showing the current map:
~/.local/bin/swiftmind read "$HOME/Documents/SwiftMind/Untitled.swiftmind.html" | head -5
ROOT_ID=$(~/.local/bin/swiftmind read "$HOME/Documents/SwiftMind/Untitled.swiftmind.html" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"]["id"])')
~/.local/bin/swiftmind add-child "$HOME/Documents/SwiftMind/Untitled.swiftmind.html" --parent "$ROOT_ID" --text "Added by agent"
```

Expected in the app within ~1s: the new node appears on the canvas and the toast "Updated by external agent" shows. The app must NOT bounce the change back (no save loop — hash suppression covers it).

- [ ] **Step 4: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/MapFileWatcher.swift Apps/SwiftMindMac/SwiftMindMac/AppModel.swift
git commit -m "feat(mac): hot-reload map file on external (agent CLI) changes"
```

---

### Task 7: SKILL.md — the agent driver's manual

**Files:**
- Create: `skills/swiftmind/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

````markdown
---
name: swiftmind
description: Operate SwiftMind mind maps (.swiftmind.html) via the swiftmind CLI — read structure, add/move/delete nodes, set attributes and formulas, batch atomic edits. Use when the user asks to view, brainstorm into, reorganize, summarize, or otherwise modify a SwiftMind map file.
---

# SwiftMind map operations

SwiftMind maps are plain HTML files (`*.swiftmind.html`). **Always modify them
through the `swiftmind` CLI — never hand-edit the HTML.** The CLI validates
every operation and writes atomically; the user's running app hot-reloads the
change onto their canvas within a second.

If `swiftmind` is not on PATH, check `~/.local/bin/swiftmind`; if missing,
build it: `cd <repo> && ./scripts/install-cli.sh`.

## Commands

All commands: `swiftmind <cmd> <file>`. Success prints JSON on stdout, exit 0.
Errors print `{"error":{"code","message"}}` on stderr, exit 1/2/3
(usage/file/operation).

- `read <file>` — full map as a JSON tree (`root` → nested `children`; each
  node: `id`, `text`, optional `note`, `attributes`, `formula`, `folded`,
  `side`, `pinned`).
- `find <file> --query <text>` — case-insensitive title/note search; returns
  matching node ids.
- `add-child <file> --parent <id> --text <t> [--side auto|left|right] [--id <newid>]`
- `add-sibling <file> --of <id> --text <t> [--id <newid>]`
- `set-text <file> --id <id> --text <t>`
- `set-note <file> --id <id> --markdown <md>`
- `set-attr <file> --id <id> --name <n> --value <v>` — empty `--value ""` removes the attribute.
- `set-formula <file> --id <id> --formula <f>` — empty clears. DSL: `count(children)`,
  `sum(children, attr: "x")`, `avg|min|max(...)`, `progress()`, `attr("x")`, arithmetic/comparison/`if(...)`.
- `fold <file> --id <id>` / `unfold`
- `pin <file> --id <id> --x <n> --y <n>` / `unpin`
- `move <file> --id <id> --to <parentId> [--index <n>]`
- `delete <file> --ids <id,id,...>` — cannot delete the root.
- `batch <file> [ops.json]` — ops array from file or stdin; **all-or-nothing**.
- `validate <file>` — decode + re-encode check.

## The batch primitive (preferred for anything non-trivial)

One JSON array = one atomic change set. Op objects:

```json
[
  {"op":"add-child","parent":"n_x","id":"n_new1","text":"Idea","side":"auto"},
  {"op":"set-attr","id":"n_new1","name":"status","value":"todo"},
  {"op":"set-formula","id":"n_x","formula":"count(children)"},
  {"op":"move","id":"n_a","to":"n_new1","index":0},
  {"op":"delete","ids":["n_b"]}
]
```

`id` is optional on `add-child`/`add-sibling` (generated if omitted) — but pass
your own ids (`n_agent1`, …) when later ops in the same batch reference them.

## Recipes

**Expand a node into sub-ideas:**
1. `swiftmind read <file>` — locate the target node id.
2. Think; draft 3–7 children.
3. Pipe a batch of `add-child` ops to `swiftmind batch <file>`.

**Summarize a branch:**
1. `read`, extract the subtree under the target node.
2. Write the summary into the parent: `set-note --id <id> --markdown "…"`.

**Restructure:**
1. `read`; plan the new shape.
2. One `batch` with `move` ops (and `add-child` for new grouping nodes).

## Discipline

- Prefer one `batch` over many single commands — atomicity + one reload.
- After writing, you may `validate` the file; the CLI already validates on
  every write, so this is optional.
- Do not write the file with anything but this CLI.
````

- [ ] **Step 2: Commit**

```bash
git add skills/swiftmind/SKILL.md
git commit -m "docs: SKILL.md — agent driver's manual for the swiftmind CLI"
```

---

### Task 8: Docs + final verification gate

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: README**

Add to the feature bullets (after the "Open Recent" line):

```markdown
- **Agent CLI** (`swiftmind`): external agents/scripts read and edit maps via `read`/`find`/`add-child`/`batch` (all-or-nothing) — the app hot-reloads external changes; see `skills/swiftmind/SKILL.md`
```

- [ ] **Step 2: AGENTS.md**

In the repository-layout block, add after the `Scripts/` line:

```
Sources/SwiftMindCLI/          # swiftmind CLI executable (agent interface to maps)
skills/swiftmind/SKILL.md      # agent driver's manual for the CLI
```

In "Architecture rules", add one bullet:

```
- **External map edits go through the CLI.** `swiftmind` (Sources/SwiftMindCLI) decodes, applies `MapOp`s via `BatchOps` (all-or-nothing, through the existing commands), and atomically rewrites the file. The app watches the open document's parent directory and hot-reloads external changes; this clears the undo stack (spec §hot reload). Never hand-edit `.swiftmind.html` in automation.
```

- [ ] **Step 3: Full gate**

```bash
swift test
./scripts/verify.sh
```

Expected: all unit tests pass (186 + 10 new BatchOps tests = 196), app builds, XCUITest smoke passes, app relaunches.

- [ ] **Step 4: Commit**

```bash
git add README.md AGENTS.md
git commit -m "docs: agent CLI + hot reload in README and AGENTS.md"
```

---

## Self-review notes

- Spec coverage: BatchOps layer (T1–T2), CLI read/write/batch/validate/find (T3–T4), install + smoke scripts (T5), app hot reload with self-write suppression + selection preservation + toast (T6), SKILL.md (T7), docs + gate (T8). v2 MCP explicitly out of scope per spec.
- Error format: spec's structured `{"error":...}` is implemented in `MapFile.fail` and the `BatchOpError` catch in main.swift (with `opIndex`).
- Known simplifications vs spec: `folded` key only appears in `read` output when true; `side` omitted when `auto`; `pinned` is a boolean in read output (coordinates recoverable via the HTML). These keep the JSON minimal; agents needing pin coordinates can read the HTML directly.
