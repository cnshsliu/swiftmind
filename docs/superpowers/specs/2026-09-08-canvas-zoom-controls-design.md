# Canvas Zoom Controls — Design

Date: 2026-09-08
Status: approved (brainstorming complete), pre-implementation

Pinch-to-zoom already exists on the map canvas (`MagnifyGesture`, clamp 0.25–3). This spec adds the remaining Mac-document zoom surfaces: View menu, ⌘+/⌘-/⌘0, toolbar buttons, ⌘+scroll zoom, and unmodified-scroll pan.

## Goal

Give the map canvas the same zoom controls a Mac document app is expected to have, without changing the HTML schema or the undo stack.

## Non-goals

- Fit-to-window / “zoom to selection”
- Persisting zoom in the `.swiftmind.html` file or UserDefaults
- Changing pinch behavior beyond reading/writing the shared viewport
- Zooming the outline list itself (outline is a list; zoom is canvas view-state)
- Rewriting the canvas onto `NSScrollView`

## Decisions

| Topic | Decision |
|-------|----------|
| Approach | Viewport lives on `DocumentSession`, not `@State` in `MapCanvasView` |
| Anchor | Cursor’s map-space point stays under the cursor; if there is no cursor, use the viewport center |
| Wheel | ⌘ + scroll zooms; unmodified scroll/trackpad pan (2× AppKit deltas) |
| Pinch | Unchanged (already zoom); writes the session viewport |
| Discrete step | Multiply/divide by **1.25**, then clamp to **0.25…3** |
| ⌘0 Actual Size | Scale = **1.0**, still around the cursor (or center) |
| Outline | Shortcuts and menu still work; switching back to Map restores the last scale/pan |
| My Brain | No canvas → zoom menu/toolbar disabled or hidden |
| Undo | Zoom/pan are not `MapCommand`s; ⌘Z does not revert scale |
| Hot reload | Clears undo; **does not** reset the viewport |
| Follow mode (F) | Still pans the selection to center after the current transform |

## Architecture

```
View menu / ⌘+/-/0 / toolbar / ⌘K
        │
        ▼
DocumentSession.viewport: CanvasViewport
        │
        ▼
MapCanvasView  ← pinch, ⌥+scroll, unmodified scroll, existing drag-pan
```

`CanvasViewport` is a UI-free value type in **SwiftMindCore** (next to layout geometry). App UI owns an instance on `DocumentSession`; core tests cover the math without SwiftUI.

### `CanvasViewport`

```text
scale: Double          // default 1, clamped [0.25, 3]
offset: Point2D        // view-space pan; default (0, 0)
```

Mutations (all clamp scale):

- `setScale(_ new: Double, anchorView: Point2D, viewWidth: Double, viewHeight: Double)` — change scale so the map point under `anchorView` stays under `anchorView`
- `zoomByStepping(_ direction: ZoomStep, anchorView: Point2D, viewWidth: Double, viewHeight: Double)` — `in` multiplies by 1.25; `out` divides by 1.25
- `resetToActualSize(anchorView: Point2D, viewWidth: Double, viewHeight: Double)` — `setScale(1, …)`
- `pan(by delta: Point2D)` — add to `offset`

No SwiftUI in core. Offset and anchors use `Point2D`. View size is two `Double`s (no new size type).

Anchor invariant (must be tested):

```
map = viewToMap(anchor, scale, offset, viewSize)
setScale(newScale, anchor, viewSize)
viewToMap(anchor, scale', offset', viewSize) == map   // within 1e-9
```

If `viewSize` is empty (canvas never laid out this session), scale changes **without** adjusting offset.

### `DocumentSession`

Published `viewport: CanvasViewport`. Also keep `lastCanvasSize` (updated by `MapCanvasView` on layout) and `lastAnchorView` (updated from hover while the canvas is mounted).

When a zoom command fires:

1. Anchor = `lastAnchorView` if the pointer is over the canvas, else the center of `lastCanvasSize`.
2. If `lastCanvasSize` is empty, scale-only.
3. Assign the new `viewport` (triggers canvas redraw via `ObservableObject`).

New maps / swapped sessions start at scale 1, offset zero. Switching Map ↔ Outline does **not** reset. Opening a different file uses a different session, so zoom resets.

`MapCanvasView` deletes its local `@State scale` / `offset` / `magnifyBase` and binds to `session.viewport`. Pinch still captures a base scale at gesture begin, then calls `setScale(base * magnification, …)` around the pinch center if available, else last hover / view center.

## UI

### View menu

Insert into the **existing** system View menu (do not add a second `CommandMenu("View")`). Use `CommandGroup(after: .toolbar)` (or `after: .sidebar` if `.toolbar` placement is empty in this scene):

| Item | Shortcut | Action |
|------|----------|--------|
| Zoom In | ⌘+ (`keyboardShortcut("=", modifiers: .command)` so it displays as ⌘+) | step in |
| Zoom Out | ⌘- | step out |
| Actual Size | ⌘0 | scale 1.0 |

Enable when `documentSession != nil && !isBrainMode`. Do **not** disable Zoom In/Out from the menu based on clamp: same clipboard-menu rule — AppKit evaluates enablement lazily, so a stale disabled flag would swallow the key. Handlers no-op at the clamp. Toolbar buttons *may* disable at the limits (they are not the shortcut source).

### Toolbar

On map documents only (same `if !session.isBrainMode` as `EditorToolbar`), a separate `ControlGroup` in `.automatic` placement (compact cluster, not mixed into Add/Delete/Undo):

- Zoom Out (`minus.magnifyingglass`) — `toolbarZoomOut`
- Zoom In (`plus.magnifyingglass`) — `toolbarZoomIn`
- Actual Size (`1.magnifyingglass`) — `toolbarActualSize`

Help strings include the shortcuts. Disable Out at 0.25, In at 3, Actual Size when `abs(scale - 1) < 1e-9`. Hidden in My Brain.

### Command palette

Three items: Zoom In, Zoom Out, Actual Size, with the same shortcuts in the subtitle. Hidden/no-op in My Brain.

### Wheel and pan

Install an `NSEvent` scroll monitor while the canvas is the hit target (pointer over `mapCanvas`):

- `command` down → zoom around the cursor (convert `NSEvent` location into view space). Mouse wheel: one notch = one 1.25 step (same as ⌘+/-). Trackpad ⌘+scroll: accumulate `deltaY` (line units) and fire one 1.25 step each time the absolute remainder crosses 1.0.
- otherwise → `pan(by:)` using the scroll deltas × 2 (natural-scroll direction as AppKit reports).

Existing drag-pan (empty/root, Space+drag, ⌘+drag) stays. Unmodified two-finger scroll is **new** pan, not a replacement for drag-pan.

Pinch continues via `MagnifyGesture`.

Text fields (title editor, note editor, search, inspector) keep their own scrolling. The monitor only acts when the pointer is over the canvas, so ⌘+scroll over a note editor does not steal the editor’s scroll.

## Edge cases

- In-place node title edit: canvas zoom shortcuts still fire (they are app commands). ⌘+scroll zooms only if the pointer is over the canvas, not over the field.
- Follow mode: after any viewport change, existing follow recentering still runs if F is on.
- External file reload: viewport unchanged.
- Multi-window: today one `AppModel`/`DocumentSession` is shared; one viewport is correct.
- Keyboard zoom in Outline: uses last canvas size + center (or last hover if still valid). User sees the result after switching back to Map.

## Testing

`Tests/SwiftMindCoreTests/CanvasViewportTests.swift`:

- Clamp: 1.25 steps never leave 0.25…3; extra Zoom In at max is a no-op
- Actual Size sets scale 1 without violating the anchor invariant
- Anchor invariant for zoom in, zoom out, and setScale(2)
- Pan adds to offset and does not change scale
- Empty viewSize: scale changes, offset unchanged

No new XCUITest required for v1; add toolbar identifiers so a later smoke can tap them. `./scripts/rerun-mac.sh` after app changes.

## Docs

- `README.md` canvas gestures / shortcuts: ⌘+ / ⌘- / ⌘0, ⌥+scroll zoom, two-finger scroll pan
- Command palette already lists shortcuts via subtitles
- Welcome help map: update `Resources/help-map.ops.json` and regenerate with `scripts/make-help-map.sh` (do not hand-edit the HTML)

## Files (expected)

| Area | File |
|------|------|
| Core math | `Sources/SwiftMindCore/Layout/CanvasViewport.swift` (new) |
| Tests | `Tests/SwiftMindCoreTests/CanvasViewportTests.swift` (new) |
| Session | `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift` |
| Canvas bind + wheel | `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift` |
| Menu | `Apps/SwiftMindMac/SwiftMindMac/SwiftMindMacApp.swift` |
| Toolbar | `Apps/SwiftMindMac/SwiftMindMac/ContentView.swift` and/or `EditorToolbar.swift` |
| Palette | `Apps/SwiftMindMac/SwiftMindMac/CommandPaletteView.swift` |
| README + help map | `README.md`, `Resources/help-map.ops.json` + generated HTML |
