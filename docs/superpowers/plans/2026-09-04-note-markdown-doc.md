# Note as a Markdown Document — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn node notes into full Markdown documents — floating editor anchored to the node (with canvas pan-out/restore), read-only rendered view in the inspector, and per-node expandable rendered cards on the canvas.

**Architecture:** Storage unchanged (`Node.text` + `Node.noteMarkdown`); the H1 is virtual, joined/split by a pure core helper (`NoteDocument`). A new persisted `Node.isNoteExpanded` flag (additive HTML attr) drives a 360pt estimated card size in `LayoutEngine.measure()` and an overlay card in the canvas. The floating editor lives in `MapCanvasView`, commits via 1s-debounced `CompositeAgentCommand` (one undo step per burst), and publishes a live draft through `DocumentSession` so inspector + card render in real time.

**Tech Stack:** Swift 5.10, SwiftUI/AppKit, XCTest, XCUITest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-04-note-markdown-doc-design.md` (approved decisions: bidirectional H1⇄title sync; storage unchanged; expansion persisted + layout-participating; live preview with debounced commit).

---

### Task 1: `Node.isNoteExpanded` model field + HTML codec

**Files:**
- Modify: `Sources/SwiftMindCore/Model/Node.swift`
- Modify: `Sources/SwiftMindCore/HTML/HTMLCodec.swift` (encode ~line 156, decode ~line 510-547)
- Test: `Tests/SwiftMindCoreTests/HTMLCodecTests.swift`

- [x] **Step 1: Write the failing test**

Add to `HTMLCodecTests.swift`:

```swift
func testNoteExpandedRoundTrip() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    try bus.execute(
        InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_x"), text: "X", side: .right),
        on: &map
    )

    // Default false: attribute is not emitted at all (old files byte-compatible).
    var html = try HTMLCodec.encode(map, includeSkin: false)
    XCTAssertFalse(html.contains("data-note-expanded"))

    map.updateNode(id: NodeID(rawValue: "n_x")) { $0.isNoteExpanded = true }
    html = try HTMLCodec.encode(map, includeSkin: false)
    XCTAssertTrue(html.contains("data-note-expanded=\"true\""))

    let decoded = try HTMLCodec.decode(html)
    XCTAssertTrue(decoded.root.children[0].isNoteExpanded)
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter HTMLCodecTests.testNoteExpandedRoundTrip`
Expected: FAIL — compile error, `Node` has no `isNoteExpanded`.

- [x] **Step 3: Implement**

In `Node.swift`, add the field after `positionPin` (line 15) and to the initializer (default `false`, before `children`):

```swift
    public var positionPin: Point2D?
    /// Show the note as a rendered markdown card on the canvas (persisted).
    public var isNoteExpanded: Bool
```

```swift
        positionPin: Point2D? = nil,
        isNoteExpanded: Bool = false,
        children: [Node] = []
```

plus `self.isNoteExpanded = isNoteExpanded` in the init body.

In `HTMLCodec.swift` `encodeNode`, after the `data-pin-x/y` block (~line 156-159):

```swift
        if node.isNoteExpanded {
            out += " data-note-expanded=\"true\""
        }
```

In the decoder, after the `positionPin` block (~line 514):

```swift
            let noteExpanded = attributeDict["data-note-expanded"] == "true"
```

and pass `isNoteExpanded: noteExpanded` into the `Node(...)` call (~line 533-547).

- [x] **Step 4: Run tests**

Run: `swift test --filter HTMLCodecTests`
Expected: PASS, including the golden-fixture round-trip (it has no expanded nodes → no new attribute emitted).

- [x] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Model/Node.swift Sources/SwiftMindCore/HTML/HTMLCodec.swift Tests/SwiftMindCoreTests/HTMLCodecTests.swift
git commit -m "Add Node.isNoteExpanded persisted as data-note-expanded (additive)"
```

---

### Task 2: `SetNoteExpandedCommand`

**Files:**
- Create: `Sources/SwiftMindCore/Commands/SetNoteExpandedCommand.swift`
- Test: `Tests/SwiftMindCoreTests/CommandBusTests.swift`

- [x] **Step 1: Write the failing test**

Add to `CommandBusTests.swift`:

```swift
func testSetNoteExpandedUndoRedo() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    try bus.execute(
        InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_e"), text: "E", side: .right),
        on: &map
    )
    let id = NodeID(rawValue: "n_e")
    XCTAssertFalse(map.node(id: id)!.isNoteExpanded)

    try bus.execute(SetNoteExpandedCommand(nodeID: id, isNoteExpanded: true), on: &map)
    XCTAssertTrue(map.node(id: id)!.isNoteExpanded)

    try bus.undo(on: &map)
    XCTAssertFalse(map.node(id: id)!.isNoteExpanded)
    try bus.redo(on: &map)
    XCTAssertTrue(map.node(id: id)!.isNoteExpanded)
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandBusTests.testSetNoteExpandedUndoRedo`
Expected: FAIL — compile error, type does not exist.

- [x] **Step 3: Implement** (clone of `SetFoldedCommand`)

Create `Sources/SwiftMindCore/Commands/SetNoteExpandedCommand.swift`:

```swift
public final class SetNoteExpandedCommand: MapCommand {
    public let name = "SetNoteExpanded"
    public let nodeID: NodeID
    public let isNoteExpanded: Bool
    private var old: Bool?

    public init(nodeID: NodeID, isNoteExpanded: Bool) {
        self.nodeID = nodeID
        self.isNoteExpanded = isNoteExpanded
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
        if old == nil { old = node.isNoteExpanded }
        guard map.updateNode(id: nodeID, { $0.isNoteExpanded = isNoteExpanded }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.isNoteExpanded = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
```

- [x] **Step 4: Run test**

Run: `swift test --filter CommandBusTests`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Commands/SetNoteExpandedCommand.swift Tests/SwiftMindCoreTests/CommandBusTests.swift
git commit -m "Add SetNoteExpandedCommand (undoable expansion toggle)"
```

---

### Task 3: `MapOp.setNoteExpanded` + read JSON + agent docs

**Files:**
- Modify: `Sources/SwiftMindCore/Automation/BatchOps.swift`
- Modify: `Sources/SwiftMindCore/Automation/AgentProtocol.swift`
- Modify: `skills/swiftmind/SKILL.md`
- Modify: `scripts/test-cli.sh`
- Test: `Tests/SwiftMindCoreTests/BatchOpsTests.swift`, `Tests/SwiftMindCoreTests/AgentProtocolTests.swift`

Wire names follow the fold/unfold precedent: ops `expand-note` / `collapse-note`.

- [x] **Step 1: Write the failing tests**

Add to `BatchOpsTests.swift`:

```swift
func testExpandNoteOpDecodesAppliesAndUndoesViaComposite() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    try bus.execute(
        InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_b"), text: "B", side: .right),
        on: &map
    )
    let json = #"[{"op":"expand-note","id":"n_b"}]"#.data(using: .utf8)!
    let ops = try JSONDecoder().decode([MapOp].self, from: json)
    XCTAssertEqual(ops, [.setNoteExpanded(nodeID: NodeID(rawValue: "n_b"), isNoteExpanded: true)])

    let command = CompositeAgentCommand(ops: ops)
    try bus.execute(command, on: &map)
    XCTAssertTrue(map.node(id: NodeID(rawValue: "n_b"))!.isNoteExpanded)
    try bus.undo(on: &map)
    XCTAssertFalse(map.node(id: NodeID(rawValue: "n_b"))!.isNoteExpanded)

    let collapse = try JSONDecoder().decode([MapOp].self, from: #"[{"op":"collapse-note","id":"n_b"}]"#.data(using: .utf8)!)
    XCTAssertEqual(collapse, [.setNoteExpanded(nodeID: NodeID(rawValue: "n_b"), isNoteExpanded: false)])
}
```

Add to `AgentProtocolTests.swift` (mirror the style of existing tests in that file):

```swift
func testReadJSONExposesNoteExpanded() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    try bus.execute(
        InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_j"), text: "J", side: .right),
        on: &map
    )
    var json = AgentProtocol.mapJSON(for: map)
    var child = (json["root"] as! [String: Any])["children"] as! [[String: Any]]
    XCTAssertNil(child[0]["noteExpanded"])

    map.updateNode(id: NodeID(rawValue: "n_j")) { $0.isNoteExpanded = true }
    json = AgentProtocol.mapJSON(for: map)
    child = (json["root"] as! [String: Any])["children"] as! [[String: Any]]
    XCTAssertEqual(child[0]["noteExpanded"] as? Bool, true)
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BatchOpsTests.testExpandNoteOpDecodesAppliesAndUndoesViaComposite`
Expected: FAIL — compile error, no such case.

- [x] **Step 3: Implement `MapOp` case**

In `BatchOps.swift`:

1. Enum case, after `setFolded`:

```swift
    case setFolded(nodeID: NodeID, isFolded: Bool)
    case setNoteExpanded(nodeID: NodeID, isNoteExpanded: Bool)
```

2. `name`, after the setFolded line:

```swift
        case .setNoteExpanded(_, let expanded): return expanded ? "expand-note" : "collapse-note"
```

3. `affectedIDs` — add to the grouped case:

```swift
        case .setText(let id, _), .setNote(let id, _), .setAttribute(let id, _, _),
             .setFormula(let id, _), .setFolded(let id, _), .setPin(let id, _),
             .setNoteExpanded(let id, _):
            return [id]
```

4. `command(in:)`, after the setFolded case:

```swift
        case let .setNoteExpanded(nodeID, isNoteExpanded):
            return SetNoteExpandedCommand(nodeID: nodeID, isNoteExpanded: isNoteExpanded)
```

5. Decoding, after the `"unfold"` case:

```swift
        case "expand-note":
            self = .setNoteExpanded(nodeID: try nodeID(.id), isNoteExpanded: true)
        case "collapse-note":
            self = .setNoteExpanded(nodeID: try nodeID(.id), isNoteExpanded: false)
```

6. Encoding, after the setFolded case (id only, same pattern):

```swift
        case let .setNoteExpanded(nodeID, _):
            try c.encode(nodeID.rawValue, forKey: .id)
```

In `AgentProtocol.swift` `nodeJSON`, next to the `folded` line:

```swift
        if node.isFolded { dict["folded"] = true }
        if node.isNoteExpanded { dict["noteExpanded"] = true }
```

- [x] **Step 4: Run tests**

Run: `swift test --filter BatchOpsTests --filter AgentProtocolTests`
Expected: PASS.

- [x] **Step 5: Update agent docs + CLI smoke**

In `skills/swiftmind/SKILL.md`, line 26-27 area — add `noteExpanded` to the node field list, and after the `fold`/`unfold` line (37) add:

```
- `expand-note` / `collapse-note` (batch ops): `{"op":"expand-note","id":"…"}`
```

In `scripts/test-cli.sh`, after the fold batch check (~line 31-33), add:

```bash
# expand-note / collapse-note via batch; read exposes noteExpanded
echo '[{"op":"expand-note","id":"n_smoke"}]' | "$CLI" batch "$WORK" >/dev/null || fail "expand-note"
"$CLI" read "$WORK" | grep -q "noteExpanded" || fail "read exposes noteExpanded"
echo '[{"op":"collapse-note","id":"n_smoke"}]' | "$CLI" batch "$WORK" >/dev/null || fail "collapse-note"
```

Run: `./scripts/test-cli.sh`
Expected: ends with `CLI smoke test OK`.

- [x] **Step 6: Commit**

```bash
git add Sources/SwiftMindCore/Automation/ Tests/SwiftMindCoreTests/BatchOpsTests.swift Tests/SwiftMindCoreTests/AgentProtocolTests.swift skills/swiftmind/SKILL.md scripts/test-cli.sh
git commit -m "MapOp setNoteExpanded (expand-note/collapse-note) + read JSON + agent docs"
```

---

### Task 4: Layout — expanded card size estimate

**Files:**
- Modify: `Sources/SwiftMindCore/Layout/LayoutConfig.swift`
- Modify: `Sources/SwiftMindCore/Layout/LayoutEngine.swift` (`measure`, lines 86-101)
- Test: `Tests/SwiftMindCoreTests/LayoutEngineTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `LayoutEngineTests.swift`:

```swift
func testExpandedNoteNodeUsesCardSize() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    try bus.execute(
        InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_c"), text: "Card", side: .right),
        on: &map
    )
    map.updateNode(id: NodeID(rawValue: "n_c")) {
        $0.noteMarkdown = "line one\nline two\nline three"
        $0.isNoteExpanded = true
    }

    let snapshot = LayoutEngine().layout(map: map)
    let card = snapshot.nodes.first { $0.id.rawValue == "n_c" }!
    // 3 body lines + 1 virtual H1 line = 4 lines: 40 + 4*20 + 2*12 padding = 144
    XCTAssertEqual(card.frame.width, 360, accuracy: 0.001)
    XCTAssertEqual(card.frame.height, 144, accuracy: 0.001)
}

func testExpandedNoteHeightCapped() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    try bus.execute(
        InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_big"), text: "Big", side: .right),
        on: &map
    )
    map.updateNode(id: NodeID(rawValue: "n_big")) {
        $0.noteMarkdown = (1...100).map { "line \($0)" }.joined(separator: "\n")
        $0.isNoteExpanded = true
    }

    let snapshot = LayoutEngine().layout(map: map)
    let card = snapshot.nodes.first { $0.id.rawValue == "n_big" }!
    XCTAssertEqual(card.frame.height, 400, accuracy: 0.001)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LayoutEngineTests.testExpandedNoteNodeUsesCardSize`
Expected: FAIL (width/height mismatch — expanded flag not handled yet).

- [ ] **Step 3: Implement**

In `LayoutConfig.swift`, add fields (and matching init params with the same defaults):

```swift
    /// Fixed width of an expanded note card (spec 2026-09-04).
    public var expandedNoteWidth: Double = 360
    /// Estimated height per markdown line in an expanded card.
    public var expandedNoteLineHeight: Double = 20
    /// Title block (virtual H1) height in an expanded card.
    public var expandedNoteTitleHeight: Double = 40
    /// Expanded cards never grow taller than this; the view clips overflow.
    public var expandedNoteMaxHeight: Double = 400
```

In `LayoutEngine.measure`, right after `let style = ...`:

```swift
        if node.isNoteExpanded {
            // Deterministic estimate (core stays UI-free): virtual H1 title
            // block + one line per markdown line, padded and capped. The
            // canvas clips any overflow inside this frame.
            let bodyLines = node.noteMarkdown.isEmpty
                ? 0
                : node.noteMarkdown.split(separator: "\n", omittingEmptySubsequences: false).count
            let estimated = config.expandedNoteTitleHeight
                + Double(bodyLines) * config.expandedNoteLineHeight
                + config.paddingX * 2
            return (
                config.expandedNoteWidth,
                min(config.expandedNoteMaxHeight, max(config.nodeHeight, estimated))
            )
        }
```

Note the estimate math: empty note → 40 + 0 + 24 = 64; the test's 3-line note → 40 + 3*20 + 24 = 124... **recheck against the test**: test asserts 144 with 4 lines counted. Use `bodyLines + 1` (virtual H1 is a line too) — i.e. `Double(bodyLines + 1) * config.expandedNoteLineHeight` and drop the separate title height from the estimate, keeping `expandedNoteTitleHeight` out of `measure` (the card view uses it for rendering). Final formula: `min(maxHeight, max(nodeHeight, Double(bodyLines + 1) * lineHeight + paddingX * 2))` → 3-line note = 4*20+24 = 104. **Fix the test expectation to 104** (and empty note → 1*20+24=44 → clamped to nodeHeight 32? no, 44 > 32 → 44). Decide in implementation; make code and test agree: use the formula above and expect **104** in the test.

- [ ] **Step 4: Run tests**

Run: `swift test --filter LayoutEngineTests`
Expected: PASS (existing pin/fold layout tests unaffected — flag defaults to false).

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Layout/ Tests/SwiftMindCoreTests/LayoutEngineTests.swift
git commit -m "LayoutEngine: fixed-width estimated card size for expanded notes"
```

---

### Task 5: `NoteDocument` split/join (virtual H1)

**Files:**
- Create: `Sources/SwiftMindCore/Model/NoteDocument.swift`
- Test: `Tests/SwiftMindCoreTests/NoteDocumentTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SwiftMindCoreTests/NoteDocumentTests.swift`:

```swift
import XCTest
@testable import SwiftMindCore

final class NoteDocumentTests: XCTestCase {
    func testComposeWithBody() {
        let doc = NoteDocument.compose(title: "Ideas", body: "first\nsecond")
        XCTAssertEqual(doc, "# Ideas\n\nfirst\nsecond\n")
    }

    func testComposeEmptyBody() {
        XCTAssertEqual(NoteDocument.compose(title: "Solo", body: ""), "# Solo\n")
    }

    func testSplitRoundTrip() {
        let doc = NoteDocument.compose(title: "Ideas", body: "first\nsecond")
        let (title, body) = NoteDocument.split(doc)
        XCTAssertEqual(title, "Ideas")
        XCTAssertEqual(body, "first\nsecond")
    }

    func testSplitMissingH1KeepsTitleNilAndWholeBody() {
        let (title, body) = NoteDocument.split("no heading here\nbody")
        XCTAssertNil(title)
        XCTAssertEqual(body, "no heading here\nbody")
    }

    func testSplitEmptyH1KeepsTitleNil() {
        let (title, body) = NoteDocument.split("#\n\nbody")
        XCTAssertNil(title)
        XCTAssertEqual(body, "body")
    }

    func testSplitTrimsTitleWhitespace() {
        let (title, _) = NoteDocument.split("#   Spaced   \nbody")
        XCTAssertEqual(title, "Spaced")
    }

    func testSplitPreservesLaterHeadingsInBody() {
        let (title, body) = NoteDocument.split("# Top\n\n## Sub\n\ntext\n# Another\n")
        XCTAssertEqual(title, "Top")
        XCTAssertEqual(body, "## Sub\n\ntext\n# Another")
    }

    func testSplitEmptyDocument() {
        let (title, body) = NoteDocument.split("")
        XCTAssertNil(title)
        XCTAssertEqual(body, "")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NoteDocumentTests`
Expected: FAIL — compile error, `NoteDocument` does not exist.

- [ ] **Step 3: Implement**

Create `Sources/SwiftMindCore/Model/NoteDocument.swift`:

```swift
import Foundation

/// Virtual-H1 view of a node's note: the document shown in the floating
/// editor is `# <title>` + blank line + body (`noteMarkdown`). Storage keeps
/// title and body in separate fields; this is the split/join layer.
/// Spec: docs/superpowers/specs/2026-09-04-note-markdown-doc-design.md
public enum NoteDocument {
    /// Document text for the editor — the first line is always `# <title>`.
    public static func compose(title: String, body: String) -> String {
        let head = "# \(title)"
        let trimmed = body.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? head + "\n" : head + "\n\n" + trimmed + "\n"
    }

    /// Inverse of `compose`. `title` is nil when the first line is not a
    /// well-formed H1 (`# ` + non-empty text) — callers keep the existing
    /// node title in that case, so deleting the H1 never erases a title.
    public static func split(_ document: String) -> (title: String?, body: String) {
        guard !document.isEmpty else { return (nil, "") }
        var lines = document.components(separatedBy: "\n")
        let first = lines[0]
        guard first == "#" || first.hasPrefix("# ") else {
            return (nil, document)
        }
        let rawTitle = first == "#" ? "" : String(first.dropFirst(2))
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        // Drop the blank separator line(s) between the H1 and the body.
        while let head = lines.first, head.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        var body = lines.joined(separator: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        return (title.isEmpty ? nil : title, body)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter NoteDocumentTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Model/NoteDocument.swift Tests/SwiftMindCoreTests/NoteDocumentTests.swift
git commit -m "NoteDocument: virtual-H1 compose/split for node notes"
```

---

### Task 6: Canvas expanded card (read-only overlay)

**Files:**
- Modify: `Sources/SwiftMindCore/Layout/MapSnapshot.swift` (`NodeVisual`)
- Modify: `Sources/SwiftMindCore/Layout/LayoutEngine.swift` (`appendNode`, ~line 351)
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`

- [ ] **Step 1: Core — flag on `NodeVisual`**

In `MapSnapshot.swift`, add to `NodeVisual` (field + init param with default, mirroring `isPinned`):

```swift
    /// True when the source node renders its note as a markdown card.
    public var isNoteExpanded: Bool
```

(default `false` in the initializer). In `LayoutEngine.appendNode`, add `isNoteExpanded: node.isNoteExpanded` to the `NodeVisual(...)` call.

Run: `swift test`
Expected: PASS (snapshot equality unaffected — default false everywhere).

- [ ] **Step 2: App — card overlay**

In `MapCanvasView.swift` body ZStack, after the `editOverlay` block (~line 92-95):

```swift
                ForEach(snapshot.nodes.filter(\.isNoteExpanded)) { visual in
                    noteCard(for: visual, viewSize: geo.size)
                }
```

Add the view builder (near `editOverlay`, ~line 686):

```swift
    /// Read-only rendered markdown card for an expanded node. Hit-testing is
    /// off so canvas selection/gestures keep working through the card.
    @ViewBuilder
    private func noteCard(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let markdown = session.store.map.node(id: visual.id)?.noteMarkdown ?? ""
        let document = NoteDocument.compose(title: visual.text, body: markdown)
        let rendered = try? AttributedString(markdown: document)
        ScrollView(.vertical) {
            Text(rendered ?? AttributedString(document))
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .scrollDisabled(true) // overflow is clipped; layout height is an estimate
        .frame(width: frame.width, height: frame.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityIdentifier("noteCard-\(visual.id.rawValue)")
    }
```

Note: cards skip the Canvas-drawn title — in `draw()`, the title draw block (~line 585-600) must skip expanded nodes: wrap it with `if editingNodeID != node.id && !node.isNoteExpanded { ... }`. Leave badges (note glyph, pin, fold, formula) as-is.

- [ ] **Step 3: Verify build + manual smoke**

Run: `./scripts/rerun-mac.sh --no-test`
Expected: BUILD SUCCEEDED; dev app relaunches. Manually: not automatable yet — checked via XCUITest in Task 9.

- [ ] **Step 4: Commit**

```bash
git add Sources/SwiftMindCore/Layout/MapSnapshot.swift Sources/SwiftMindCore/Layout/LayoutEngine.swift Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift
git commit -m "Render expanded notes as read-only markdown cards on the canvas"
```

---

### Task 7: Inspector note section → read-only rendered view

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/InspectorView.swift`

- [ ] **Step 1: Replace the Note section (lines 52-70)**

```swift
                Section("Note") {
                    let bodyMarkdown = node.noteMarkdown
                    if !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let attr = try? AttributedString(markdown: bodyMarkdown) {
                        Text(attr)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("notePreview")
                    } else {
                        Text("No note — select the node on the canvas and press E to edit")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
```

(Full block-level parsing now — no `inlineOnlyPreservingWhitespace` option.)

- [ ] **Step 2: Remove the dead editing machinery**

Delete: `@State private var noteDraft`, `@State private var lastSyncedNote`, `@FocusState private var noteFocused`, the `commitNote(for:)` method, and the note-related lines in `syncFromSelection` (`noteDraft = node.noteMarkdown`, `lastSyncedNote = ...` in both branches, and the "same node" refresh block for notes). Title/style drafts stay untouched.

- [ ] **Step 3: Verify build**

Run: `./scripts/rerun-mac.sh --no-test`
Expected: BUILD SUCCEEDED. Inspector shows rendered note (or the hint) for the selected node.

- [ ] **Step 4: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/InspectorView.swift
git commit -m "Inspector note section is now a read-only rendered view"
```

---

### Task 8: Floating note editor + pan/restore + live preview + hotkeys

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/InspectorView.swift` (live binding)
- Modify: `Apps/SwiftMindMac/SwiftMindMac/SwiftMindMacApp.swift` (`SessionNodeCommands`, ~line 192-211)

- [ ] **Step 1: `DocumentSession` live draft channel**

Add after the `toast` property:

```swift
    /// Live floating-editor draft (virtual-H1 document) while the note editor
    /// is open; rendered views prefer it over the stored model values.
    @Published var liveNoteDocument: (nodeID: NodeID, document: String)?
```

- [ ] **Step 2: Canvas state + hotkeys**

In `MapCanvasView.swift`, add state near the follow-mode state (~line 41):

```swift
    // MARK: Floating note editor
    @State private var noteEditorNodeID: NodeID?
    @State private var noteEditorDraft: String = ""
    @State private var noteCommitTask: Task<Void, Never>?
    /// Canvas offset stashed when the editor opened (restored on close).
    @State private var preEditorPan: CGSize?
    /// The offset we panned to; restore only if the user hasn't panned since.
    @State private var editorPanTarget: CGSize?
    @FocusState private var noteEditorFocused: Bool
    private static let noteEditorWidth: CGFloat = 420
```

Add hotkeys next to the `f` handler (~line 167-171):

```swift
            // Note editor (E) and note card expansion (X) for the primary node.
            .onKeyPress(.init("e")) {
                guard editingNodeID == nil else { return .ignored }
                toggleNoteEditor()
                return .handled
            }
            .onKeyPress(.init("x")) {
                guard editingNodeID == nil else { return .ignored }
                toggleNoteExpansion()
                return .handled
            }
```

Suspend follow-mode recentering while the editor is open — in `keepPrimaryInFrame` (~line 361), first line:

```swift
        guard noteEditorNodeID == nil else { return }
```

Auto-close when the node disappears — in the `contentRevision` onChange (~line 196-203), next to the edit-cancel block:

```swift
            if let id = noteEditorNodeID, session.store.map.node(id: id) == nil {
                noteCommitTask?.cancel()
                noteEditorNodeID = nil
                session.liveNoteDocument = nil
                preEditorPan = nil
                editorPanTarget = nil
            }
```

- [ ] **Step 3: Editor overlay + logic**

Add to the ZStack, after the noteCard ForEach:

```swift
                if let editorID = noteEditorNodeID,
                   let visual = snapshot.nodes.first(where: { $0.id == editorID }) {
                    noteEditorOverlay(for: visual, viewSize: geo.size)
                }
```

Add the methods (near `noteCard`):

```swift
    /// Floating markdown editor: right of the node, top-aligned. The first
    /// line is the virtual H1 (the node title) — see NoteDocument.
    @ViewBuilder
    private func noteEditorOverlay(for visual: NodeVisual, viewSize: CGSize) -> some View {
        let frame = viewFrame(for: visual.frame, viewSize: viewSize)
        let width = Self.noteEditorWidth
        let height = min(480, max(200, viewSize.height - frame.minY - 24))
        TextEditor(text: $noteEditorDraft)
            .font(.system(size: 13, design: .monospaced))
            .padding(8)
            .frame(width: width, height: height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .position(x: frame.maxX + 16 + width / 2, y: frame.minY + height / 2)
            .focused($noteEditorFocused)
            .focusEffectDisabled()
            .onExitCommand { closeNoteEditor() }
            .onChange(of: noteEditorDraft) { _, newValue in
                session.liveNoteDocument = (visual.id, newValue)
                scheduleNoteCommit()
            }
            .accessibilityIdentifier("noteEditor")
    }

    private func toggleNoteEditor() {
        if noteEditorNodeID != nil {
            closeNoteEditor()
            return
        }
        guard let primary = session.store.selection.primary,
              let node = session.store.map.node(id: primary) else { return }
        noteEditorNodeID = primary
        noteEditorDraft = NoteDocument.compose(title: node.text, body: node.noteMarkdown)
        session.liveNoteDocument = (primary, noteEditorDraft)
        stashAndPanForEditor()
        DispatchQueue.main.async { noteEditorFocused = true }
    }

    private func closeNoteEditor() {
        noteCommitTask?.cancel()
        commitNoteEditorDraft()
        noteEditorNodeID = nil
        session.liveNoteDocument = nil
        // Restore the pre-editor pan only if the user hasn't panned since.
        if let saved = preEditorPan, let target = editorPanTarget, offset == target {
            let apply = { offset = saved; panBase = saved }
            if reduceMotion { apply() } else {
                withAnimation(.easeOut(duration: 0.22)) { apply() }
            }
        }
        preEditorPan = nil
        editorPanTarget = nil
        canvasFocused = true
    }

    /// Pan the canvas left so the editor fits right of the node.
    private func stashAndPanForEditor() {
        guard let id = noteEditorNodeID,
              let visual = session.store.snapshot().nodes.first(where: { $0.id == id }) else { return }
        let frame = viewFrame(for: visual.frame, viewSize: canvasSize)
        let overflow = frame.maxX + 16 + Self.noteEditorWidth - (canvasSize.width - 16)
        guard overflow > 0 else { return }
        preEditorPan = offset
        let target = CGSize(width: offset.width - overflow, height: offset.height)
        editorPanTarget = target
        let apply = { offset = target; panBase = target }
        if reduceMotion { apply() } else {
            withAnimation(.easeOut(duration: 0.22)) { apply() }
        }
    }

    private func toggleNoteExpansion() {
        guard let primary = session.store.selection.primary,
              let node = session.store.map.node(id: primary) else { return }
        session.applyQuiet(SetNoteExpandedCommand(nodeID: primary, isNoteExpanded: !node.isNoteExpanded))
    }

    /// 1s debounce — each typing burst is one CompositeAgentCommand, i.e. one
    /// undo step (the scheduleAutosave idiom from AppModel).
    private func scheduleNoteCommit() {
        noteCommitTask?.cancel()
        noteCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            commitNoteEditorDraft()
        }
    }

    private func commitNoteEditorDraft() {
        guard let id = noteEditorNodeID,
              let node = session.store.map.node(id: id) else { return }
        let (title, body) = NoteDocument.split(noteEditorDraft)
        var ops: [MapOp] = []
        if let title, title != node.text { ops.append(.setText(nodeID: id, text: title)) }
        if body != node.noteMarkdown { ops.append(.setNote(nodeID: id, markdown: body)) }
        guard !ops.isEmpty else { return }
        session.applyQuiet(CompositeAgentCommand(ops: ops))
    }
```

- [ ] **Step 4: Live binding in card + inspector**

In `noteCard` (Task 6), replace the `document` line:

```swift
        let live = session.liveNoteDocument
        let document = live?.nodeID == visual.id
            ? live!.document
            : NoteDocument.compose(title: visual.text, body: markdown)
```

In `InspectorView.swift` Note section, replace the `bodyMarkdown` line:

```swift
                    let live = session.liveNoteDocument
                    let bodyMarkdown = live?.nodeID == node.id
                        ? NoteDocument.split(live!.document).body
                        : node.noteMarkdown
```

- [ ] **Step 5: Menu items + notifications**

Find the `Notification.Name` extension at the bottom of `MapCanvasView.swift` (~line 991) and add:

```swift
    static let swiftMindToggleNoteEditor = Notification.Name("swiftMindToggleNoteEditor")
    static let swiftMindToggleNoteExpansion = Notification.Name("swiftMindToggleNoteExpansion")
```

In `MapCanvasView` body, next to the existing `.onReceive` blocks (~line 206):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindToggleNoteEditor)) { _ in
            guard editingNodeID == nil else { return }
            toggleNoteEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMindToggleNoteExpansion)) { _ in
            guard editingNodeID == nil else { return }
            toggleNoteExpansion()
        }
```

In `SwiftMindMacApp.swift` `SessionNodeCommands`, after the "Toggle Fold" button:

```swift
        Button("Edit Note") {
            NotificationCenter.default.post(name: .swiftMindToggleNoteEditor, object: nil)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(session?.store.selection.primary == nil || (session?.isBrainMode ?? false))

        Button("Toggle Note Expansion") {
            NotificationCenter.default.post(name: .swiftMindToggleNoteExpansion, object: nil)
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(session?.store.selection.primary == nil || (session?.isBrainMode ?? false))
```

- [ ] **Step 6: Verify build + run**

Run: `./scripts/rerun-mac.sh --no-test`
Expected: BUILD SUCCEEDED; dev app relaunches. (Dev instance only — the Release install is untouched, per the canary split.)

- [ ] **Step 7: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/
git commit -m "Floating markdown note editor with pan-out/restore, live preview, e/x hotkeys"
```

---

### Task 9: XCUITest + docs + full verification

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMacUITests/SwiftMindMacUITests.swift`
- Modify: `README.md` (keyboard shortcuts), `AGENTS.md` (model + shortcuts)
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift` (only if the tests expose issues)

- [ ] **Step 1: Write the UI tests**

Add to `SwiftMindMacUITests.swift` (follow the existing test style; `app` is set up in `setUpWithError`, `element(_:)` is the existing helper):

```swift
func testFloatingNoteEditorOpensAndCloses() throws {
    XCTAssertTrue(element("mapCanvas").waitForExistence(timeout: 5))
    // ⌘T adds a child and selects it (existing behavior, see testAddChildViaCommandT).
    app.typeKey("t", modifierFlags: .command)
    app.typeKey(.escape, modifierFlags: []) // leave any in-place title edit
    // E opens the floating editor for the selected node.
    app.typeText("e")
    let editor = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier == %@", "noteEditor"))
        .firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 3), "note editor should open")
    // Esc closes it.
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(editor.waitForNonExistence(timeout: 3), "note editor should close")
}

func testToggleNoteExpansionShowsCard() throws {
    XCTAssertTrue(element("mapCanvas").waitForExistence(timeout: 5))
    app.typeKey("t", modifierFlags: .command)
    app.typeKey(.escape, modifierFlags: [])
    app.typeText("x")
    let card = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH %@", "noteCard-"))
        .firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 3), "expanded note card should appear")
    app.typeText("x")
    XCTAssertTrue(card.waitForNonExistence(timeout: 3), "card should collapse")
}
```

If `e`/`x` reach the title-edit field instead of the canvas (focus race), mirror the pattern used for Return/Delete: post through the key monitor — but first try as written; adjust only if the tests actually fail.

- [ ] **Step 2: Run UI tests**

Run: `./scripts/test-ui.sh`
Expected: `UI tests PASSED` (13 tests: existing 11 + 2 new).

- [ ] **Step 3: Docs**

`README.md` keyboard shortcuts table (search for the existing shortcut list): add rows — `E` floating note editor, `X` toggle note card, `⇧⌘E` Edit Note (menu), `⌥⌘E` Toggle Note Expansion (menu). If there's a features section describing notes, update the one-liner: notes are full markdown documents; title = first H1.

`AGENTS.md`:
- Model line for `Node` (repository layout section): add `NoteDocument` to `Model/`.
- Architecture rules: add a bullet — "**Notes are virtual-H1 markdown documents.** Storage keeps `Node.text` and `Node.noteMarkdown` separate; `NoteDocument.compose/split` joins them for the editor. `isNoteExpanded` (persisted `data-note-expanded`) renders the note as a read-only card on the canvas; editing happens only in the floating editor (canvas key `e`), which commits via debounced `CompositeAgentCommand`."

- [ ] **Step 4: Full gate**

Run: `./scripts/verify.sh`
Expected: all four stages pass (core tests, CLI smoke, app build, XCUITest).

- [ ] **Step 5: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMacUITests/SwiftMindMacUITests.swift README.md AGENTS.md
git commit -m "Note markdown doc: UI tests + docs"
```

---

## Self-review notes (resolved)

- Spec coverage: §1→Task 1-2, §2→Task 4, §3→Task 5, §4+§6 live/pan→Task 8, §5→Task 7, §6 card→Task 6, §7→Task 3, §8 edge cases→Tasks 5 (missing H1), 8 (node deleted, multi-selection via primary-only), §9→Tasks 1-5, 9.
- Task 4's estimate formula and test expectation were aligned inline (4 lines → 104pt; see Task 4 note).
- Naming: `SetNoteExpandedCommand(nodeID:isNoteExpanded:)` used consistently in Tasks 2, 3, 8; `MapOp.setNoteExpanded` in Tasks 3, 8; `liveNoteDocument` in Tasks 8 (defined Step 1, consumed Step 4).
