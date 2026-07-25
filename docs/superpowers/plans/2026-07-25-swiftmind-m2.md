# SwiftMind M2 Implementation Plan (Daily Driver)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn M1 into a daily-driver macOS mind map: Markdown notes, URL + node links, icons/tags, search, pin/unpin layout, Command Palette (⌘K), multi-window stability, and optional iCloud document container wiring.

**Architecture:** Extend `SwiftMindCore` domain + commands + HTMLCodec (schema **stays 1**, additive fields only) + layout pin path. Mac app gains inspector sections, search UI, palette, canvas pin gestures, and entitlements for iCloud Documents. All mutations still go through `MapCommand` / `MapStore`.

**Tech Stack:** Swift 5.10+, SPM `SwiftMindCore`, XCTest, SwiftUI macOS 14+, existing XcodeGen app. Optional: Apple `Text`/`AttributedString` Markdown for note preview (no new deps).

**Spec:** `docs/superpowers/specs/2026-07-24-swiftmind-design.md` §8 M2.

**Baseline (M1 on `main`):** model, CommandBus, MapStore, HTMLCodec, LayoutEngine, DocumentGroup app with outline/canvas/inspector/toolbar.

**Out of scope for M2:** filters, attribute tables, StyleSheet system, formulas, scripts, encryption, `.mm` import, iPad shell, real-time collab.

---

## File map (new / primary touch points)

```text
Sources/SwiftMindCore/
  Model/
    Node.swift                    # + noteMarkdown, links, icons
    NodeLink.swift                # NEW
    IconRef.swift                 # NEW
  Commands/
    SetNoteCommand.swift          # NEW
    SetLinksCommand.swift         # NEW (or Add/RemoveLink)
    SetIconsCommand.swift         # NEW
    SetPinCommand.swift           # NEW
  Search/
    MapSearch.swift               # NEW
  HTML/HTMLCodec.swift            # encode/decode new fields
  Layout/
    LayoutEngine.swift            # honor positionPin
    MapSnapshot.swift             # hasNote, iconIDs, isPinned on NodeVisual

Tests/SwiftMindCoreTests/
  NoteLinkIconTests.swift         # NEW
  PinLayoutTests.swift            # NEW
  MapSearchTests.swift            # NEW
  HTMLCodecTests.swift            # extend round-trips

Apps/SwiftMindMac/SwiftMindMac/
  InspectorView.swift             # notes, links, icons
  SearchBarView.swift             # NEW
  CommandPaletteView.swift        # NEW
  MapCanvasView.swift             # pin gesture, badges, note corner
  ContentView.swift               # search, palette, sidebar search hits
  EditorToolbar.swift             # search, palette, pin
  SwiftMindMac.entitlements       # iCloud container keys
  project.yml                     # CODE_SIGN / iCloud if needed
README.md                         # M2 section
```

---

### Task 1: Domain — note, links, icons on `Node`

**Files:**
- Create: `Sources/SwiftMindCore/Model/NodeLink.swift`
- Create: `Sources/SwiftMindCore/Model/IconRef.swift`
- Modify: `Sources/SwiftMindCore/Model/Node.swift`
- Create: `Tests/SwiftMindCoreTests/NoteLinkIconTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SwiftMindCore

final class NoteLinkIconTests: XCTestCase {
    func testNodeDefaultsHaveEmptyNoteLinksIcons() {
        let n = Node(text: "Hi")
        XCTAssertEqual(n.noteMarkdown, "")
        XCTAssertTrue(n.links.isEmpty)
        XCTAssertTrue(n.icons.isEmpty)
    }

    func testNodeLinkEqualityAndKinds() {
        let url = NodeLink.url(URL(string: "https://example.com")!)
        let node = NodeLink.node(NodeID(rawValue: "n_x"))
        XCTAssertNotEqual(url, node)
        XCTAssertEqual(url, NodeLink.url(URL(string: "https://example.com")!))
    }

    func testIconRefBuiltin() {
        let icon = IconRef.builtin("flag")
        XCTAssertEqual(icon.id, "flag")
        XCTAssertEqual(IconRef.catalog.map(\.id).sorted().first, "check") // catalog non-empty, has check
        XCTAssertTrue(IconRef.catalog.contains(where: { $0.id == "flag" }))
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Volumes/WD/devwd/swiftmind && swift test --filter NoteLinkIconTests
```

Expected: compile errors for missing types / properties.

- [ ] **Step 3: Implement types**

`Sources/SwiftMindCore/Model/NodeLink.swift`:

```swift
import Foundation

public enum NodeLink: Equatable, Sendable, Codable, Hashable {
    case url(URL)
    case node(NodeID)

    public var kindLabel: String {
        switch self {
        case .url: return "url"
        case .node: return "node"
        }
    }
}
```

`Sources/SwiftMindCore/Model/IconRef.swift`:

```swift
public struct IconRef: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var id: String

    public init(id: String) {
        self.id = id
    }

    public static func builtin(_ id: String) -> IconRef {
        IconRef(id: id)
    }

    /// Small fixed catalog for M2 (SF Symbol names used by Mac UI).
    public static let catalog: [IconRef] = [
        IconRef(id: "check"),
        IconRef(id: "flag"),
        IconRef(id: "star"),
        IconRef(id: "warning"),
        IconRef(id: "idea"),
        IconRef(id: "question"),
        IconRef(id: "important"),
        IconRef(id: "todo"),
    ]

    /// Maps catalog id → SF Symbol name for the Mac app (Core stays UI-free).
    public static let sfSymbolNames: [String: String] = [
        "check": "checkmark.circle.fill",
        "flag": "flag.fill",
        "star": "star.fill",
        "warning": "exclamationmark.triangle.fill",
        "idea": "lightbulb.fill",
        "question": "questionmark.circle.fill",
        "important": "exclamationmark.circle.fill",
        "todo": "circle",
    ]
}
```

Update `Node.swift` — add properties with defaults:

```swift
public var noteMarkdown: String
public var links: [NodeLink]
public var icons: [IconRef]

public init(
    id: NodeID = .generate(),
    text: String,
    isFolded: Bool = false,
    side: NodeSide = .auto,
    style: NodeStyle = .default,
    positionPin: Point2D? = nil,
    noteMarkdown: String = "",
    links: [NodeLink] = [],
    icons: [IconRef] = [],
    children: [Node] = []
) {
    // assign all fields including new ones
    ...
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter NoteLinkIconTests
```

Expected: PASS. Full suite still passes:

```bash
swift test
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Model Tests/SwiftMindCoreTests/NoteLinkIconTests.swift
git commit -m "feat(core): node note, links, and icon model"
```

---

### Task 2: Commands — SetNote, SetLinks, SetIcons, SetPin

**Files:**
- Create: `Sources/SwiftMindCore/Commands/SetNoteCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/SetLinksCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/SetIconsCommand.swift`
- Create: `Sources/SwiftMindCore/Commands/SetPinCommand.swift`
- Modify: `Tests/SwiftMindCoreTests/NoteLinkIconTests.swift` (or `CommandBusTests.swift`)

- [ ] **Step 1: Tests**

```swift
func testSetNoteUndo() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    let id = map.root.id
    try bus.execute(SetNoteCommand(nodeID: id, noteMarkdown: "hello **world**"), on: &map)
    XCTAssertEqual(map.root.noteMarkdown, "hello **world**")
    try bus.undo(on: &map)
    XCTAssertEqual(map.root.noteMarkdown, "")
}

func testSetLinksAndIcons() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    let id = map.root.id
    let link = NodeLink.url(URL(string: "https://a.test")!)
    try bus.execute(SetLinksCommand(nodeID: id, links: [link]), on: &map)
    try bus.execute(SetIconsCommand(nodeID: id, icons: [.builtin("flag")]), on: &map)
    XCTAssertEqual(map.root.links, [link])
    XCTAssertEqual(map.root.icons.map(\.id), ["flag"])
}

func testSetPinUndo() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    let id = map.root.id
    let p = Point2D(x: 100, y: -40)
    try bus.execute(SetPinCommand(nodeID: id, positionPin: p), on: &map)
    XCTAssertEqual(map.root.positionPin, p)
    try bus.execute(SetPinCommand(nodeID: id, positionPin: nil), on: &map)
    XCTAssertNil(map.root.positionPin)
    try bus.undo(on: &map)
    XCTAssertEqual(map.root.positionPin, p)
}
```

- [ ] **Step 2: Implement commands** (same class + old-value pattern as `SetTextCommand`)

```swift
public final class SetNoteCommand: MapCommand {
    public let name = "SetNote"
    public let nodeID: NodeID
    public let noteMarkdown: String
    private var old: String?

    public init(nodeID: NodeID, noteMarkdown: String) {
        self.nodeID = nodeID
        self.noteMarkdown = noteMarkdown
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if old == nil { old = node.noteMarkdown }
        guard map.updateNode(id: nodeID, { $0.noteMarkdown = noteMarkdown }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.noteMarkdown = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}
```

Mirror for `SetLinksCommand` (`links: [NodeLink]`), `SetIconsCommand` (`icons: [IconRef]`), `SetPinCommand` (`positionPin: Point2D?`).

- [ ] **Step 3: `swift test` PASS, commit**

```bash
git commit -m "feat(core): note, links, icons, pin commands"
```

---

### Task 3: HTMLCodec additive fields (schema still 1)

**Files:**
- Modify: `Sources/SwiftMindCore/HTML/HTMLCodec.swift`
- Modify: `Tests/SwiftMindCoreTests/HTMLCodecTests.swift`

**HTML shape (additive on each `li`):**

```html
<li data-node-id="..." ... existing attrs ...
    data-pin-x="12.5" data-pin-y="-3"   <!-- omit both if unpinned -->
    data-icons="flag,star">             <!-- comma-separated catalog ids; omit if empty -->
  <span class="node-title">Title</span>
  <div class="node-note" hidden>markdown text escaped</div>
  <ul class="node-links" hidden>
    <li data-link-kind="url" data-href="https://example.com"></li>
    <li data-link-kind="node" data-node-ref="n_other"></li>
  </ul>
  <ul> ... children ... </ul>
</li>
```

Rules:
- Missing note/links/icons/pin on decode → empty / nil (M1 files still open).
- Do **not** bump `data-schema` (remain `1`).
- Escape note text like other text; preserve newlines in note body.
- Pin: only write `data-pin-x` / `data-pin-y` when `positionPin != nil`.

- [ ] **Step 1: Round-trip test**

```swift
func testRoundTripNoteLinksIconsPin() throws {
    var map = MindMap.makeEmpty(title: "N")
    let bus = CommandBus()
    let child = NodeID(rawValue: "n_c")
    try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: child, text: "C", side: .right), on: &map)
    try bus.execute(SetNoteCommand(nodeID: child, noteMarkdown: "line1\n**bold**"), on: &map)
    try bus.execute(SetLinksCommand(nodeID: child, links: [
        .url(URL(string: "https://example.com")!),
        .node(map.root.id)
    ]), on: &map)
    try bus.execute(SetIconsCommand(nodeID: child, icons: [.builtin("star")]), on: &map)
    try bus.execute(SetPinCommand(nodeID: child, positionPin: Point2D(x: 10, y: 20)), on: &map)

    let html = try HTMLCodec.encode(map, includeSkin: true)
    XCTAssertTrue(html.contains("node-note"))
    XCTAssertTrue(html.contains("data-icons=\"star\""))
    XCTAssertTrue(html.contains("data-pin-x"))

    let decoded = try HTMLCodec.decode(html)
    let n = decoded.node(id: child)!
    XCTAssertEqual(n.noteMarkdown, "line1\n**bold**")
    XCTAssertEqual(n.links.count, 2)
    XCTAssertEqual(n.icons.map(\.id), ["star"])
    XCTAssertEqual(n.positionPin?.x, 10, accuracy: 0.001)
    XCTAssertEqual(n.positionPin?.y, 20, accuracy: 0.001)
}

func testLegacyM1HTMLStillDecodes() throws {
    // Use existing Fixtures/minimal.swiftmind.html
    let url = Bundle.module.url(forResource: "minimal", withExtension: "swiftmind.html", subdirectory: nil)
        ?? Bundle.module.url(forResource: "minimal", withExtension: "swiftmind.html")
    // If fixture path differs, load via #file relative path as in existing HTMLCodecTests
    ...
    let map = try HTMLCodec.decode(String(contentsOf: url!))
    XCTAssertFalse(map.root.text.isEmpty)
    XCTAssertEqual(map.root.noteMarkdown, "")
}
```

Reuse the same fixture loading pattern already in `HTMLCodecTests` for the golden file.

- [ ] **Step 2: Implement encode/decode in `HTMLCodec`**

Encode after `node-title`:
- if `!noteMarkdown.isEmpty` emit hidden `div.node-note`
- if `!links.isEmpty` emit `ul.node-links`
- attributes for icons and pin on `li`

Decode:
- read `data-icons`, `data-pin-x/y` on `li` start
- on `div` with class `node-note`, accumulate characters into note
- on `li` inside `ul.node-links`, parse link attrs (do not confuse with tree children — use a parser stack flag `inLinksList`)

- [ ] **Step 3: Update HTMLSkin lightly** (optional note badge styles for browser)

```css
.node-note { /* when not using [hidden] for share skin, reveal notes under title */ }
```

For skin: on encode with `includeSkin: true`, either strip `hidden` from note for browser, or add CSS:

```css
.node-note[hidden] { display: block !important; opacity: 0.75; font-size: 0.9em; margin-left: 0.5rem; }
```

Prefer CSS override so app parse still sees `hidden` attribute.

- [ ] **Step 4: `swift test` PASS, commit**

```bash
git commit -m "feat(core): HTMLCodec note, links, icons, pin"
```

---

### Task 4: Layout honors `positionPin`

**Files:**
- Modify: `Sources/SwiftMindCore/Layout/LayoutEngine.swift`
- Modify: `Sources/SwiftMindCore/Layout/MapSnapshot.swift` (`NodeVisual` badges)
- Create: `Tests/SwiftMindCoreTests/PinLayoutTests.swift`

**Behavior:**
- If `node.positionPin != nil`, place that node’s frame so **center** is at `(pin.x, pin.y)` (or top-left at pin — pick center and document it; tests lock center).
- Children of a pinned node still auto-layout relative to the pinned parent frame (existing `placeChildren`).
- Unpinned nodes keep M1 flow.
- Root may be pinned (allowed).
- Add to `NodeVisual`: `hasNote: Bool`, `iconIDs: [String]`, `isPinned: Bool` for canvas badges.

- [ ] **Step 1: Test**

```swift
func testPinnedNodeUsesPinCoordinates() throws {
    var map = MindMap.makeEmpty(title: "T")
    let bus = CommandBus()
    let a = NodeID(rawValue: "n_a")
    try bus.execute(InsertChildCommand(parentID: map.root.id, newNodeID: a, text: "A", side: .right), on: &map)
    try bus.execute(SetPinCommand(nodeID: a, positionPin: Point2D(x: 200, y: -100)), on: &map)
    let snap = LayoutEngine().layout(map: map)
    let v = snap.nodes.first { $0.id == a }!
    XCTAssertEqual(v.frame.midX, 200, accuracy: 0.5)
    XCTAssertEqual(v.frame.midY, -100, accuracy: 0.5)
    XCTAssertTrue(v.isPinned)
}

func testUnpinReturnsToAutoLayoutSide() throws {
    // pin far away, unpin, expect midX > root midX for side .right
    ...
}
```

- [ ] **Step 2: Layout change**

In `placeChildren` / `appendNode` path, when placing each child:

```swift
let size = measure(child)
let frame: Rect2D
if let pin = child.positionPin {
    frame = Rect2D(x: pin.x - size.width/2, y: pin.y - size.height/2, width: size.width, height: size.height)
} else {
    // existing auto x/y from side + cursorY
}
```

When computing `subtreeHeight` / vertical stacking for **unpinned siblings**, skip pinned siblings’ contribution to the auto stack (or include their measured height only in auto branch). M2 rule: **pinned siblings do not consume auto-stack slots**; they only occupy pin position. Auto siblings pack as if pinned ones were absent.

- [ ] **Step 3: Tests PASS, commit**

```bash
git commit -m "feat(core): layout engine respects position pins"
```

---

### Task 5: MapSearch

**Files:**
- Create: `Sources/SwiftMindCore/Search/MapSearch.swift`
- Create: `Tests/SwiftMindCoreTests/MapSearchTests.swift`

```swift
public struct MapSearchHit: Equatable, Sendable, Identifiable {
    public var id: NodeID { nodeID }
    public var nodeID: NodeID
    public var title: String
    public var matchInNote: Bool
}

public enum MapSearch {
    /// Case-insensitive substring match on title and noteMarkdown. Empty query → [].
    public static func search(map: MindMap, query: String) -> [MapSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [MapSearchHit] = []
        walk(map.root, query: q, into: &hits)
        return hits
    }

    private static func walk(_ node: Node, query: String, into hits: inout [MapSearchHit]) {
        let titleHit = node.text.range(of: query, options: .caseInsensitive) != nil
        let noteHit = node.noteMarkdown.range(of: query, options: .caseInsensitive) != nil
        if titleHit || noteHit {
            hits.append(MapSearchHit(nodeID: node.id, title: node.text, matchInNote: noteHit && !titleHit))
        }
        for c in node.children { walk(c, query: query, into: &hits) }
    }
}
```

- [ ] **Tests:** insert nodes with known text/notes; search `"alpha"` finds title; search note-only text sets `matchInNote`.

```bash
swift test --filter MapSearchTests
git commit -m "feat(core): map title and note search"
```

---

### Task 6: Inspector — Markdown note, links, icons

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/InspectorView.swift`

- [ ] **Step 1: Note section**

Below Title section:

```swift
Section("Note") {
    TextEditor(text: $noteDraft)
        .font(.body)
        .frame(minHeight: 100)
    Button("Apply Note") {
        session.apply(SetNoteCommand(nodeID: node.id, noteMarkdown: noteDraft))
    }
    .disabled(noteDraft == node.noteMarkdown)
    // Optional live preview:
    if let attr = try? AttributedString(markdown: noteDraft) {
        Text(attr)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

Sync `noteDraft` in the same `isSyncing` / `boundNodeID` pattern as title.

- [ ] **Step 2: Links section**

```swift
Section("Links") {
    ForEach(Array(node.links.enumerated()), id: \.offset) { index, link in
        HStack {
            Text(linkDescription(link))
            Spacer()
            Button(role: .destructive) { removeLink(at: index, node: node) } label: { Image(systemName: "trash") }
        }
    }
    TextField("https://…", text: $urlDraft)
    Button("Add URL") { addURL(to: node) }
    Button("Link to Selected…") { /* open simple sheet listing other node ids/titles */ }
}
```

For M2 minimum: **URL add/remove only** in inspector; **node links** via Command Palette action “Link selection → …” or a second text field accepting `n_…` id. Prefer:

- Add URL from string
- Add Node link: pick from `session.store.map` flattened list (Menu)

```swift
Menu("Link to Node") {
    ForEach(flatten(session.store.map.root).filter { $0.id != node.id }, id: \.id) { other in
        Button(other.text) {
            var links = node.links
            links.append(.node(other.id))
            session.apply(SetLinksCommand(nodeID: node.id, links: links))
        }
    }
}
```

- [ ] **Step 3: Icons section**

```swift
Section("Icons") {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 28))]) {
        ForEach(IconRef.catalog) { icon in
            let on = node.icons.contains(icon)
            Button {
                toggleIcon(icon, on: node)
            } label: {
                Image(systemName: IconRef.sfSymbolNames[icon.id] ?? "questionmark")
                    .symbolVariant(on ? .fill : .none)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
```

- [ ] **Step 4: Build app**

```bash
cd Apps/SwiftMindMac && xcodegen generate
xcodebuild -scheme SwiftMindMac -destination 'platform=macOS' CODE_SIGN_IDENTITY=- build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(mac): inspector notes, links, and icons"
```

---

### Task 7: Canvas badges + pin interaction

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/EditorToolbar.swift`

**Canvas:**
- Draw small note glyph if `visual.hasNote` (top-right of frame).
- Draw up to 3 SF Symbols for `iconIDs` left of title (shrink text frame).
- Draw pin badge if `isPinned`.

**Pin interaction (M2):**
- Menu/toolbar **Pin / Unpin** for selection:  
  - Pin: `SetPinCommand(nodeID:, positionPin: Point2D(x: frame.midX, y: frame.midY))` using current snapshot frame.  
  - Unpin: `positionPin: nil`.
- **Option+drag** on a node: while dragging, update visual; on release `SetPinCommand` with map coordinates (and ensure node is pinned). If not option, keep M1 reparent-or-pan behavior.

```swift
// On option+drag end:
session.apply(SetPinCommand(nodeID: id, positionPin: Point2D(x: mapX, y: mapY)))
```

- [ ] **Step 1: Implement drawing badges in Canvas `context.draw`**

- [ ] **Step 2: Toolbar button**

```swift
Button(isPinned ? "Unpin" : "Pin") { ... }
.keyboardShortcut("p", modifiers: [.command, .shift])
```

- [ ] **Step 3: Build + manual checklist in commit message, commit**

```bash
git commit -m "feat(mac): canvas badges and pin interaction"
```

---

### Task 8: Search UI

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/SearchBarView.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/ContentView.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/EditorToolbar.swift`

```swift
struct SearchBarView: View {
    @ObservedObject var session: DocumentSession
    @Binding var query: String
    @State private var hits: [MapSearchHit] = []

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, q in
                    hits = MapSearch.search(map: session.store.map, query: q)
                }
                .onChange(of: session.revision) { _, _ in
                    hits = MapSearch.search(map: session.store.map, query: query)
                }
            List(hits) { hit in
                Button {
                    session.select(hit.nodeID)
                } label: {
                    VStack(alignment: .leading) {
                        Text(hit.title)
                        if hit.matchInNote {
                            Text("Note match").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
```

Place search in **sidebar** under map title (replace placeholder “Nodes” block). Toolbar: focus search with `⌘F` via `@FocusState` if practical, else button that sets `sidebarSearchFocused`.

- [ ] **Build + commit**

```bash
git commit -m "feat(mac): search UI for titles and notes"
```

---

### Task 9: Command Palette ⌘K

**Files:**
- Create: `Apps/SwiftMindMac/SwiftMindMac/CommandPaletteView.swift`
- Modify: `ContentView.swift`, `SwiftMindMacApp.swift` or toolbar

**Model (app-layer):**

```swift
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let run: () -> Void
}

enum PaletteBuilder {
    static func items(session: DocumentSession, query: String, dismiss: @escaping () -> Void) -> [PaletteItem] {
        var items: [PaletteItem] = []
        // Commands
        items.append(PaletteItem(id: "add-child", title: "Add Child", subtitle: "⌘T") {
            // same as toolbar; then dismiss()
        })
        items.append(/* Add Sibling, Delete, Fold, Pin, Unpin, Undo, Redo */)
        // Jump to node by title
        for hit in MapSearch.search(map: session.store.map, query: query.isEmpty ? " " : query) {
            // if query empty, list first N nodes via flatten instead
        }
        // Filter items by query on title
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false) }
    }
}
```

For empty query node jump list:

```swift
static func flatten(_ node: Node) -> [Node] {
    [node] + node.children.flatMap { flatten($0) }
}
```

**UI:**

```swift
.sheet(isPresented: $palettePresented) {
    CommandPaletteView(session: session, isPresented: $palettePresented)
}
.keyboardShortcut("k", modifiers: .command) // on button + menu
```

`CommandPaletteView`: `TextField` + `List` of filtered items; Return runs first/selected; Escape dismisses.

Also add menu **View → Command Palette** with ⌘K.

- [ ] **Build + commit**

```bash
git commit -m "feat(mac): command palette"
```

---

### Task 10: Multi-window / document session stability

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/ContentView.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/SwiftMindFileDocument.swift` if needed

**Issues to fix (M1 concerns):**
1. Each window must own its own `DocumentSession` (already `@StateObject` per ContentView — verify two windows don’t share).
2. When document file reloads / external change: call `session.syncFromDocument(document.map)` when binding identity changes.

```swift
.onChange(of: document.map.id) { _, _ in
    session.syncFromDocument(document.map)
}
```

Note: `MindMap` is a struct; file reload may keep same id. Prefer:

```swift
// After open, ContentView init already loads map.
// On revert:
.onReceive(NotificationCenter.default.publisher(for: NSDocument.didReadNotification)) { ... }
```

M2 practical approach:
- Store `documentEpoch` on session; when `exportMap` writes back, fine.
- Add `ContentView.onAppear` to re-sync if `session.exportMap() != document.map` is expensive; instead compare `session.store.revision == 0` only at init.

**Required fix:** title field for **map title** (document name vs `map.title`):

```swift
// Sidebar
TextField("Map Title", text: mapTitleBinding) // updates document.map.title via a small SetMapTitleCommand OR direct mutate through new command
```

Add `SetMapTitleCommand` in Core:

```swift
public final class SetMapTitleCommand: MapCommand {
    public let name = "SetMapTitle"
    public let newTitle: String
    private var old: String?
    public func execute(on map: inout MindMap) throws {
        if old == nil { old = map.title }
        map.title = newTitle
    }
    public func undo(on map: inout MindMap) throws {
        if let old { map.title = old }
    }
}
```

- [ ] **Manual test plan in README:** open two maps side by side; edit each; undo independent.

- [ ] **Commit**

```bash
git commit -m "fix(mac): multi-window session stability and map title"
```

---

### Task 11: Optional iCloud Documents wiring

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/SwiftMindMac.entitlements`
- Modify: `Apps/SwiftMindMac/project.yml` (add `CODE_SIGN_ENTITLEMENTS` already present; add iCloud capability metadata if XcodeGen supports)
- Create: `Apps/SwiftMindMac/SwiftMindMac/iCloudNotes.md` **or** section in README only (prefer README only — no extra md unless useful)
- Modify: `README.md`

**Entitlements (optional; enable when team ID known):**

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.app.swiftmind.mac</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.app.swiftmind.mac</string>
</array>
```

**M2 behavior:**
- Do **not** force iCloud. Keep user-selected files.
- Document that users can save to **iCloud Drive** folder via standard Save panel.
- If signing lacks iCloud capability, leave entitlements commented in README snippet rather than breaking local ad-hoc builds.

**project.yml** — leave container disabled by default; document how to enable:

```yaml
# To enable iCloud: add com.apple.developer.icloud-* to entitlements
# and set DEVELOPMENT_TEAM in project.yml settings.
```

Add `DEVELOPMENT_TEAM: ""` comment in project.yml for the human.

- [ ] **Step 1: README section “iCloud (optional)”**

- [ ] **Step 2: Ensure local `CODE_SIGN_IDENTITY=-` still builds without iCloud keys** (if keys require provisioning, **do not** add keys to committed entitlements; only document).

**Decision for agents:** Prefer **documentation-only** for iCloud in M2 if adding entitlements breaks unsigned local builds. Commit:

```bash
git commit -m "docs(mac): optional iCloud Drive usage for M2"
```

If entitlements can be added safely without team:

```bash
git commit -m "feat(mac): optional iCloud containers entitlements"
```

---

### Task 12: M2 acceptance + README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Automated**

```bash
cd /Volumes/WD/devwd/swiftmind && swift test
cd Apps/SwiftMindMac && xcodegen generate
xcodebuild -scheme SwiftMindMac -destination 'platform=macOS' CODE_SIGN_IDENTITY=- build
```

Expected: all tests pass, BUILD SUCCEEDED.

- [ ] **Step 2: Manual checklist (human or agent with UI)**

| Criterion | Pass? |
|-----------|-------|
| Add Markdown note, save, reopen, note present | |
| Add URL + node link, click/open URL works | |
| Toggle icons, visible on canvas, round-trip HTML | |
| Search finds title and note matches; select jumps | |
| Pin node, move with Option+drag, unpin restores auto layout | |
| ⌘K runs Add Child and jump-to-node | |
| Two windows, independent undo | |
| Browser open still shows hierarchy (+ notes if skin shows) | |

- [ ] **Step 3: README M2 features list**

- [ ] **Step 4: Tag**

```bash
git tag m2-complete
git commit -m "docs: M2 daily-driver feature notes"  # if README changed without prior commit
```

---

## Spec coverage (M2)

| Spec M2 item | Tasks |
|--------------|-------|
| Markdown notes in inspector | 1–3, 6 |
| URL + node links | 1–3, 6 |
| Icons/tags small set | 1–3, 6–7 |
| Search | 5, 8 |
| Pin/unpin | 2–4, 7 |
| Command Palette ⌘K | 9 |
| Multi-window stability | 10 |
| Optional iCloud wiring | 11 |
| Exit: daily use / no silent data loss | 3 round-trip, 12 |

## Non-goals (explicit)

- Filters, attributes registry, StyleSheet, formulas, scripts, encryption
- Freeplane `.mm`
- Pixel-perfect browser map layout

## Type consistency

| Name | Shape |
|------|--------|
| `Node.noteMarkdown` | `String` (empty default) |
| `Node.links` | `[NodeLink]` |
| `NodeLink` | `.url(URL)` / `.node(NodeID)` |
| `IconRef.id` | catalog string; SF map in `IconRef.sfSymbolNames` |
| `SetPinCommand` | `positionPin: Point2D?` |
| `MapSearch.search(map:query:)` | `[MapSearchHit]` |
| `NodeVisual.hasNote` / `iconIDs` / `isPinned` | canvas badges |
| HTML schema | **1** additive |

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-25-swiftmind-m2.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — this session, batch with checkpoints  

Which approach?
