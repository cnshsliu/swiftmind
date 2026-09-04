# Note as a Markdown Document — Design

Date: 2026-09-04
Status: approved (brainstorming complete)

## Problem

A node note is currently edited in the inspector as a two-part widget: a
`TextEditor` input box with a rendered preview stacked underneath it
(`InspectorView.swift`, "Note" section). It is cramped, duplicates content
vertically, and treats notes as an afterthought rather than a first-class
document.

## Goal

A note **is** a full Markdown document. The node title is always the first
`#` heading of that document. Editing happens in a floating editor anchored
to the node; the inspector shows a read-only rendered view; a node on the
canvas can toggle between one-line title and an inline rendered card.

## Approved decisions (from brainstorming)

1. **H1 ⇄ title: bidirectional sync.** The first H1 of the document *is* the
   node title. Editing either side renames the other.
2. **Storage unchanged.** `Node.text` and `Node.noteMarkdown` stay separate
   fields; the H1 line is virtual — prepended when a document view is built,
   stripped on commit. HTML schema, CLI, and MCP see no title/note change.
3. **Expanded nodes participate in auto layout and persist.** Expansion state
   is written to the file (additive, like fold/pin) and survives reload.
4. **Live preview, debounced commit.** Typing drives rendered views
   immediately from the editor draft; model commits are debounced (1 s) and
   each commit burst is exactly one undo step.

## Design

### 1. Model & persistence (core)

- `Node` gains `public var isNoteExpanded: Bool` (default `false`).
- HTMLCodec emits `data-note-expanded="true"` **only when true** (same
  additive pattern as `data-pin-x/y`); decode treats missing as `false`.
  Old files round-trip byte-identical; the golden fixture is untouched.
- New command `SetNoteExpandedCommand` (modelled on `SetFoldedCommand`,
  capture-old-once semantics).
- No schema version bump: schema 1 additive, unknown attributes ignored.

### 2. Layout (core)

`LayoutEngine.measure()` is the single size source; the expanded card plugs
in there and nowhere else:

- Expanded width: fixed 360 pt (`LayoutConfig.expandedNoteWidth`).
- Expanded height: estimated from the markdown source, not from rendered
  text — core stays UI-free and deterministic. Estimate = title block
  (one line at node style font size) + per-markdown-line height
  (`LayoutConfig.expandedNoteLineHeight`), capped at
  `LayoutConfig.expandedNoteMaxHeight` (~400 pt); the view clips/scrolls
  overflow inside the frame.
- `subtreeHeight` picks up the expanded height automatically because it
  derives from `measure`.

### 3. Virtual H1 split/join (core, pure functions)

`NoteDocument` (new file `Sources/SwiftMindCore/Model/NoteDocument.swift`):

- `compose(title:body:) -> String`: `"# \(title)"` + blank line + body.
- `split(document:) -> (title: String?, body: String)`: parse the first
  ATX H1 line; if absent or malformed, `title` is `nil` (caller keeps the
  existing node title — deleting the H1 never renames to empty) and the
  whole text is treated as body.
- Commit path in the app: `split` → optional `set-text` + `set-note` MapOps
  in one `CompositeAgentCommand` (one undo step per commit burst).
- Unit-tested as pure functions: normal case, empty body, missing H1,
  H1 with leading/trailing whitespace, body containing later H1s.

### 4. Floating editor & canvas pan (app)

- Hotkey (canvas scope, `editingNodeID == nil` guard, same `.onKeyPress`
  pattern as `f`/`hjkl`): `e` toggles the floating editor for the primary
  selected node. Menu mirror: ⇧⌘E.
- Presentation: an in-window panel positioned at the node's view frame
  right edge, top-aligned (`viewFrame(for:viewSize:)` gives the rect).
  Content: monospaced `TextEditor` holding the composed document; first
  line is the H1.
- Pan-to-fit: when the editor opens, stash `(offset, panBase)`, then pan
  the canvas left so node + editor fit the viewport — same
  `withAnimation(.easeOut(0.22))` idiom as `centerPrimary`. On close,
  restore the stashed pair. If the user pans manually while the editor is
  open, the stashed restore is dropped (do not yank the view back).
- Follow mode interaction: while the editor is open, follow-mode
  recentering is suspended; closing the editor restores the offset first.
- Live preview: rendered views (inspector, expanded card) bind to the
  editor's draft while it is open; the model is committed via a 1 s
  debounced task (the `scheduleAutosave` cancellable-Task idiom) and once
  more on close. Each debounced commit is one `CompositeAgentCommand`.

### 5. Inspector (app)

- Note section loses the `TextEditor`; becomes read-only rendered markdown
  using **full** (block-level) `AttributedString(markdown:)` parsing so
  headings/lists render. Empty note shows a hint ("press e to edit").
- The draft/lastSynced machinery stays for the rendered binding but no
  longer commits on blur — committing belongs to the floating editor.

### 6. Canvas expanded card (app)

- Nodes with `isNoteExpanded` render a markdown card inside their layout
  frame (360 pt wide, composed document incl. H1, full block rendering,
  clipped to the estimated height).
- Hotkey `x` toggles expansion for the primary node (canvas scope);
  menu mirror ⌥⌘E. Dispatch: `SetNoteExpandedCommand`.
- Canvas drawing keeps using snapshot frames; the card is a SwiftUI
  overlay at the frame, not a `Canvas` text draw (block markdown needs
  real layout).

### 7. CLI / agent surface

- `MapOp` gains `set-note-expanded` (`id`, `expanded: Bool`), mirroring the
  `fold` op; `BatchOps` maps it to `SetNoteExpandedCommand`.
- Read JSON (`AgentProtocol` shared read) exposes `noteExpanded` per node.
- No new CLI subcommand — `batch` covers it. MCP `apply_ops` inherits it.

### 8. Edge cases

- Empty note + expand: allowed; card renders title only.
- Editor open on a node that gets deleted (by agent/script/undo): editor
  closes, offset restored.
- Multi-selection: hotkeys act on the primary node only.
- Browser skin: expansion has no visual representation in the static HTML
  skin (consistent with fold/pin).

### 9. Testing

- Core unit tests: codec round-trip with `data-note-expanded` (encode only
  when true; missing → false); `measure` expanded width/height + cap;
  `NoteDocument` split/join incl. missing-H1 fallback;
  `SetNoteExpandedCommand` undo; `MapOp` decode of `set-note-expanded`.
- E2E: extend `DailyDriverE2ETests` with an expand/compose/commit flow
  through the store.
- XCUITest: `e` opens the editor, canvas pans left, close restores offset;
  `x` shows the rendered card for a node with a note.

## Explicitly out of scope

- Syntax highlighting in the editor (monospaced plain text is enough).
- True rendered-text measurement for layout (estimation is deliberate).
- WYSIWYG editing on the canvas card (card is read-only; editing happens
  in the floating editor).
- Multiple simultaneous floating editors (one at a time).
