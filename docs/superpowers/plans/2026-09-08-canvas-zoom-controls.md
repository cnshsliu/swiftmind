# Canvas Zoom Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Mac-document zoom to the map canvas: View menu Zoom In/Out/Actual Size, ⌘+/⌘-/⌘0, toolbar cluster, Option+scroll zoom, unmodified-scroll pan — all sharing one session-owned viewport.

**Architecture:** UI-free `CanvasViewport` in SwiftMindCore holds `scale` + `offset` and the anchor math. `DocumentSession` publishes that viewport and exposes `zoomIn` / `zoomOut` / `resetToActualSize` / pan. `MapCanvasView` drops its local `@State scale/offset` and reads/writes the session; pinch, drag-pan, follow-mode, and a new `scrollWheel` monitor all go through the same struct. Zoom is not a `MapCommand` and is not persisted in HTML.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit (`NSEvent` scroll monitor), XCTest via `swift test`. No new packages.

**Spec:** `docs/superpowers/specs/2026-09-08-canvas-zoom-controls-design.md`

---

## File map

| File | Responsibility |
|------|----------------|
| `Sources/SwiftMindCore/Layout/CanvasViewport.swift` | Scale/offset value type, clamp, step 1.25, anchor-preserving `setScale`, pan |
| `Tests/SwiftMindCoreTests/CanvasViewportTests.swift` | Clamp, no-op at limits, actual size, anchor invariant, pan, empty view size, command anchor |
| `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift` | `@Published viewport`, last canvas size/pointer, zoom/pan APIs |
| `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift` | Bind drawing/gestures to session; pinch writes viewport; scroll monitor |
| `Apps/SwiftMindMac/SwiftMindMac/SwiftMindMacApp.swift` | View-menu `CommandGroup` + shortcuts |
| `Apps/SwiftMindMac/SwiftMindMac/ContentView.swift` | Toolbar `ControlGroup` (− / ＋ / 1×) |
| `Apps/SwiftMindMac/SwiftMindMac/CommandPaletteView.swift` | Palette items |
| `README.md` | Gesture/shortcut table |
| `Apps/SwiftMindMac/SwiftMindMac/Resources/help-map.ops.json` | Welcome-map copy; regenerate HTML via `scripts/make-help-map.sh` |

SPM picks up new files under `Sources/SwiftMindCore` and `Tests/` automatically. XcodeGen picks up new files under `Apps/SwiftMindMac/SwiftMindMac/`.

---

### Task 1: `CanvasViewport` math (TDD)

**Files:**
- Create: `Tests/SwiftMindCoreTests/CanvasViewportTests.swift`
- Create: `Sources/SwiftMindCore/Layout/CanvasViewport.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SwiftMindCoreTests/CanvasViewportTests.swift`:

```swift
import XCTest
@testable import SwiftMindCore

final class CanvasViewportTests: XCTestCase {
    private let w = 800.0
    private let h = 600.0
    private let anchor = Point2D(x: 200, y: 150)

    private func mapUnderAnchor(_ v: CanvasViewport) -> Point2D {
        v.mapPoint(fromView: anchor, viewWidth: w, viewHeight: h)
    }

    func testDefaultIsActualSize() {
        let v = CanvasViewport()
        XCTAssertEqual(v.scale, 1)
        XCTAssertEqual(v.offset, .zero)
        XCTAssertTrue(v.isActualSize)
        XCTAssertFalse(v.isAtMinScale)
        XCTAssertFalse(v.isAtMaxScale)
    }

    func testZoomInStepsBy125AndClamps() {
        var v = CanvasViewport()
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, 1.25, accuracy: 1e-12)
        for _ in 0..<20 {
            v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        }
        XCTAssertEqual(v.scale, CanvasViewport.maxScale)
        XCTAssertTrue(v.isAtMaxScale)
        let offsetAtMax = v.offset
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, CanvasViewport.maxScale)
        XCTAssertEqual(v.offset.x, offsetAtMax.x, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, offsetAtMax.y, accuracy: 1e-9)
    }

    func testZoomOutClampsToMin() {
        var v = CanvasViewport()
        for _ in 0..<20 {
            v.zoomByStepping(.out, anchorView: anchor, viewWidth: w, viewHeight: h)
        }
        XCTAssertEqual(v.scale, CanvasViewport.minScale)
        XCTAssertTrue(v.isAtMinScale)
        let offsetAtMin = v.offset
        v.zoomByStepping(.out, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, CanvasViewport.minScale)
        XCTAssertEqual(v.offset.x, offsetAtMin.x, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, offsetAtMin.y, accuracy: 1e-9)
    }

    func testSetScalePreservesMapPointUnderAnchor() {
        var v = CanvasViewport()
        v.pan(by: Point2D(x: 40, y: -15))
        let before = mapUnderAnchor(v)
        v.setScale(2, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(mapUnderAnchor(v).x, before.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, before.y, accuracy: 1e-9)
        let afterSet = mapUnderAnchor(v)
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(mapUnderAnchor(v).x, afterSet.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, afterSet.y, accuracy: 1e-9)
        let afterIn = mapUnderAnchor(v)
        v.zoomByStepping(.out, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(mapUnderAnchor(v).x, afterIn.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, afterIn.y, accuracy: 1e-9)
    }

    func testResetToActualSizePreservesAnchor() {
        var v = CanvasViewport()
        v.setScale(2.5, anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertFalse(v.isActualSize)
        let before = mapUnderAnchor(v)
        v.resetToActualSize(anchorView: anchor, viewWidth: w, viewHeight: h)
        XCTAssertEqual(v.scale, 1, accuracy: 1e-12)
        XCTAssertTrue(v.isActualSize)
        XCTAssertEqual(mapUnderAnchor(v).x, before.x, accuracy: 1e-9)
        XCTAssertEqual(mapUnderAnchor(v).y, before.y, accuracy: 1e-9)
    }

    func testPanDoesNotChangeScale() {
        var v = CanvasViewport()
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: w, viewHeight: h)
        let s = v.scale
        let before = v.offset
        v.pan(by: Point2D(x: 10, y: 20))
        XCTAssertEqual(v.scale, s)
        XCTAssertEqual(v.offset.x, before.x + 10, accuracy: 1e-12)
        XCTAssertEqual(v.offset.y, before.y + 20, accuracy: 1e-12)
    }

    func testEmptyViewSizeChangesScaleOnly() {
        var v = CanvasViewport()
        v.pan(by: Point2D(x: 5, y: 6))
        v.setScale(2, anchorView: anchor, viewWidth: 0, viewHeight: 0)
        XCTAssertEqual(v.scale, 2)
        XCTAssertEqual(v.offset, Point2D(x: 5, y: 6))
        v.zoomByStepping(.in, anchorView: anchor, viewWidth: 0, viewHeight: h)
        XCTAssertEqual(v.scale, 2.5, accuracy: 1e-12)
        XCTAssertEqual(v.offset, Point2D(x: 5, y: 6))
    }

    func testCommandAnchor() {
        let hover = Point2D(x: 10, y: 20)
        XCTAssertEqual(
            CanvasViewport.commandAnchor(
                pointerOverCanvas: true, lastAnchorView: hover, viewWidth: w, viewHeight: h
            ),
            hover
        )
        XCTAssertEqual(
            CanvasViewport.commandAnchor(
                pointerOverCanvas: false, lastAnchorView: hover, viewWidth: w, viewHeight: h
            ),
            Point2D(x: w / 2, y: h / 2)
        )
        XCTAssertEqual(
            CanvasViewport.commandAnchor(
                pointerOverCanvas: true, lastAnchorView: nil, viewWidth: w, viewHeight: h
            ),
            Point2D(x: w / 2, y: h / 2)
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CanvasViewportTests`

Expected: FAIL — `CanvasViewport` does not exist.

- [ ] **Step 3: Implement `CanvasViewport`**

Create `Sources/SwiftMindCore/Layout/CanvasViewport.swift`:

```swift
import Foundation

public enum ZoomStep: Sendable {
    case `in`
    case `out`
}

public struct CanvasViewport: Equatable, Sendable {
    public static let minScale = 0.25
    public static let maxScale = 3.0
    public static let stepFactor = 1.25

    public var scale: Double
    public var offset: Point2D

    public init(scale: Double = 1, offset: Point2D = .zero) {
        self.scale = Self.clamped(scale)
        self.offset = offset
    }

    public var isAtMinScale: Bool { scale <= minScale + 1e-12 }
    public var isAtMaxScale: Bool { scale >= maxScale - 1e-12 }
    public var isActualSize: Bool { abs(scale - 1) < 1e-9 }

    public static func clamped(_ scale: Double) -> Double {
        min(maxScale, max(minScale, scale))
    }

    public func mapPoint(fromView p: Point2D, viewWidth: Double, viewHeight: Double) -> Point2D {
        let s = scale == 0 ? 1 : scale
        return Point2D(
            x: (p.x - viewWidth / 2 - offset.x) / s,
            y: (p.y - viewHeight / 2 - offset.y) / s
        )
    }

    public static func commandAnchor(
        pointerOverCanvas: Bool,
        lastAnchorView: Point2D?,
        viewWidth: Double,
        viewHeight: Double
    ) -> Point2D {
        if pointerOverCanvas, let lastAnchorView {
            return lastAnchorView
        }
        return Point2D(x: viewWidth / 2, y: viewHeight / 2)
    }

    public mutating func setScale(
        _ new: Double,
        anchorView: Point2D,
        viewWidth: Double,
        viewHeight: Double
    ) {
        let clamped = Self.clamped(new)
        if viewWidth <= 0 || viewHeight <= 0 {
            scale = clamped
            return
        }
        let map = mapPoint(fromView: anchorView, viewWidth: viewWidth, viewHeight: viewHeight)
        scale = clamped
        offset = Point2D(
            x: anchorView.x - viewWidth / 2 - map.x * scale,
            y: anchorView.y - viewHeight / 2 - map.y * scale
        )
    }

    public mutating func zoomByStepping(
        _ direction: ZoomStep,
        anchorView: Point2D,
        viewWidth: Double,
        viewHeight: Double
    ) {
        let next: Double
        switch direction {
        case .in: next = scale * Self.stepFactor
        case .out: next = scale / Self.stepFactor
        }
        setScale(next, anchorView: anchorView, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    public mutating func resetToActualSize(
        anchorView: Point2D,
        viewWidth: Double,
        viewHeight: Double
    ) {
        setScale(1, anchorView: anchorView, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    public mutating func pan(by delta: Point2D) {
        offset = Point2D(x: offset.x + delta.x, y: offset.y + delta.y)
    }
}
```

Match existing canvas transform in `MapCanvasView.mapPoint`:

```text
mapX = (location.x - viewSize.width / 2 - offset.width) / scale
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CanvasViewportTests`

Expected: PASS (all tests in the class).

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMindCore/Layout/CanvasViewport.swift Tests/SwiftMindCoreTests/CanvasViewportTests.swift
git commit -m "feat(core): CanvasViewport scale/pan math with cursor anchor"
```

---

### Task 2: Session-owned viewport + zoom commands

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift`

- [ ] **Step 1: Add published viewport and command helpers**

In `DocumentSession`, after `@Published var liveNoteDocument`:

```swift
    /// Canvas pan/zoom. View-state only — not persisted, not undoable.
    @Published var viewport = CanvasViewport()
    /// Last laid-out canvas size (for keyboard zoom when the canvas is unmounted).
    private(set) var lastCanvasWidth: Double = 0
    private(set) var lastCanvasHeight: Double = 0
    private(set) var lastAnchorView: Point2D?
    private(set) var pointerIsOverCanvas = false
```

Always **reassign** the whole `viewport` struct (mutating `viewport.offset =` on `@Published` does not reliably fire `objectWillChange`).

Add methods (near `clearSelection`):

```swift
    func rememberCanvasLayout(width: Double, height: Double) {
        lastCanvasWidth = width
        lastCanvasHeight = height
    }

    func rememberCanvasPointer(overCanvas: Bool, viewPoint: Point2D?) {
        pointerIsOverCanvas = overCanvas
        if overCanvas {
            lastAnchorView = viewPoint
        }
    }

    func setCanvasOffset(_ offset: Point2D) {
        var next = viewport
        next.offset = offset
        viewport = next
    }

    func setCanvasScale(_ scale: Double, around viewPoint: Point2D, width: Double, height: Double) {
        var next = viewport
        next.setScale(scale, anchorView: viewPoint, viewWidth: width, viewHeight: height)
        viewport = next
    }

    func panCanvas(by delta: Point2D) {
        var next = viewport
        next.pan(by: delta)
        viewport = next
    }

    func zoomIn() {
        applyZoomStep(.in)
    }

    func zoomOut() {
        applyZoomStep(.out)
    }

    func resetToActualSize() {
        guard !isBrainMode else { return }
        var next = viewport
        let anchor = zoomAnchor()
        next.resetToActualSize(
            anchorView: anchor,
            viewWidth: lastCanvasWidth,
            viewHeight: lastCanvasHeight
        )
        viewport = next
    }

    private func applyZoomStep(_ step: ZoomStep) {
        guard !isBrainMode else { return }
        var next = viewport
        next.zoomByStepping(
            step,
            anchorView: zoomAnchor(),
            viewWidth: lastCanvasWidth,
            viewHeight: lastCanvasHeight
        )
        viewport = next
    }

    private func zoomAnchor() -> Point2D {
        CanvasViewport.commandAnchor(
            pointerOverCanvas: pointerIsOverCanvas,
            lastAnchorView: lastAnchorView,
            viewWidth: lastCanvasWidth,
            viewHeight: lastCanvasHeight
        )
    }
```

Do **not** reset `viewport` in `syncFromDocument` (hot reload keeps pan/zoom). New `DocumentSession(map:)` already starts at scale 1 / offset zero.

- [ ] **Step 2: Compile the app sources that already import SwiftMindCore**

No dedicated app unit-test target. Core tests still pass:

Run: `swift test --filter CanvasViewportTests`

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift
git commit -m "feat(mac): session-owned canvas viewport and zoom commands"
```

---

### Task 3: Bind `MapCanvasView` to the session viewport

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`

- [ ] **Step 1: Replace local scale/offset with session accessors**

Remove:

```swift
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
```

Keep `@State private var magnifyBase` and `@State private var panBase` (gesture baselines). Keep `minScale`/`maxScale` **or** delete them and use `CanvasViewport.minScale` / `maxScale` everywhere those constants are referenced (pinch clamp).

Add computed accessors on `MapCanvasView` (they mutate the class-backed session, so the setter is `nonmutating`):

```swift
    private var scale: CGFloat { CGFloat(session.viewport.scale) }

    private var offset: CGSize {
        get {
            CGSize(width: session.viewport.offset.x, height: session.viewport.offset.y)
        }
        nonmutating set {
            session.setCanvasOffset(Point2D(x: Double(newValue.width), y: Double(newValue.height)))
        }
    }
```

Existing `offset = …` sites (`centerPrimary`, `ensurePrimaryVisible`, drag pan, note-editor pan stash) keep compiling.

- [ ] **Step 2: Publish layout + hover to the session**

In the existing `.onAppear` / `.onChange(of: geo.size)` that set `canvasSize`, also:

```swift
session.rememberCanvasLayout(width: Double(geo.size.width), height: Double(geo.size.height))
```

and the same in `onChange` with `newSize`.

In `onContinuousHover`:

```swift
case .active(let point):
    hoverLocation = point
    session.rememberCanvasPointer(
        overCanvas: true,
        viewPoint: Point2D(x: Double(point.x), y: Double(point.y))
    )
case .ended:
    hoverLocation = nil
    session.rememberCanvasPointer(overCanvas: false, viewPoint: nil)
```

On `.onDisappear`, after the existing note-editor cleanup:

```swift
session.rememberCanvasPointer(overCanvas: false, viewPoint: nil)
```

Do **not** zero `lastCanvasWidth/Height` on disappear — Outline-mode ⌘+/- needs the last size.

- [ ] **Step 3: Pinch writes `setCanvasScale` around the pinch location**

Replace `magnifyGesture` with:

```swift
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let next = Double(magnifyBase) * Double(value.magnification)
                let anchor: Point2D = {
                    if let hover = hoverLocation {
                        return Point2D(x: Double(hover.x), y: Double(hover.y))
                    }
                    return Point2D(x: Double(canvasSize.width) / 2, y: Double(canvasSize.height) / 2)
                }()
                session.setCanvasScale(
                    next,
                    around: anchor,
                    width: Double(canvasSize.width),
                    height: Double(canvasSize.height)
                )
            }
            .onEnded { _ in
                magnifyBase = scale
            }
    }
```

`MagnifyGesture` does not always give a centroid; hover / view center matches the spec fallback.

- [ ] **Step 4: Confirm follow-mode still recenters using `scale`/`offset` accessors**

`centerPrimary` already assigns `offset = target`. That now writes the session. No formula change. `keepPrimaryInFrame` still runs on selection/content changes (existing `onChange`s).

- [ ] **Step 5: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift
git commit -m "feat(mac): canvas reads session viewport for pan/pinch"
```

---

### Task 4: Option+scroll zoom and unmodified-scroll pan

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`

- [ ] **Step 1: Add a scroll-wheel monitor beside the key monitor**

Add state:

```swift
    @State private var scrollMonitor: Any?
```

In `installKeyMonitor()`, after installing the key monitor, also install:

```swift
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [session] event in
            guard session.pointerIsOverCanvas else { return event }
            if let fr = event.window?.firstResponder as? NSView,
               fr is NSTextView || fr is NSTextField,
               let content = event.window?.contentView {
                let p = content.convert(event.locationInWindow, from: nil)
                if let hit = content.hitTest(p), hit === fr || hit.isDescendant(of: fr) {
                    return event
                }
            }
            if event.modifierFlags.contains(.option) {
                session.handleOptionScroll(
                    deltaY: Double(event.scrollingDeltaY),
                    precise: event.hasPreciseScrollingDeltas
                )
            } else {
                session.panCanvas(
                    by: Point2D(x: Double(event.scrollingDeltaX), y: Double(event.scrollingDeltaY))
                )
            }
            return nil
        }
```

Do not call instance methods on `MapCanvasView` from the monitor (stale struct). Remainder lives on the session:

Add to `DocumentSession`:

```swift
    var optionScrollRemainder: Double = 0

    func handleOptionScroll(deltaY: Double, precise: Bool) {
        guard !isBrainMode else { return }
        if precise {
            optionScrollRemainder += deltaY
            while optionScrollRemainder >= 1 {
                optionScrollRemainder -= 1
                zoomIn()
            }
            while optionScrollRemainder <= -1 {
                optionScrollRemainder += 1
                zoomOut()
            }
        } else {
            if deltaY > 0 { zoomIn() }
            else if deltaY < 0 { zoomOut() }
        }
    }
```

Then the monitor calls `session.handleOptionScroll(deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)`.

Positive `scrollingDeltaY` = zoom in (two-finger up / wheel away, matching Preview).

- [ ] **Step 2: Remove the scroll monitor on disappear**

Extend `removeKeyMonitor()` (or add `removeScrollMonitor()` called from the same places):

```swift
    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }
```

Reset `session.optionScrollRemainder = 0` on disappear.

- [ ] **Step 3: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift Apps/SwiftMindMac/SwiftMindMac/DocumentSession.swift
git commit -m "feat(mac): Option+scroll zoom and two-finger pan on canvas"
```

---

### Task 5: View menu Zoom In / Out / Actual Size + shortcuts

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/SwiftMindMacApp.swift`

- [ ] **Step 1: Insert zoom commands into the existing View menu**

In `SwiftMindMacApp` `.commands`, after `CommandGroup(after: .sidebar)` (command palette), add:

```swift
            CommandGroup(after: .toolbar) {
                SessionZoomCommands()
            }
```

If a debug run shows a second empty group instead of View-menu items, switch the placement to `CommandGroup(after: .sidebar)` **below** the palette group (same View menu). Do **not** add `CommandMenu("View")`.

Add at the bottom of `SwiftMindMacApp.swift` (same file as `SessionNodeCommands`):

```swift
private struct SessionZoomCommands: View {
    @FocusedValue(\.documentSession) private var session

    var body: some View {
        Button("Zoom In") {
            session?.zoomIn()
        }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(session == nil || (session?.isBrainMode ?? false))

        Button("Zoom Out") {
            session?.zoomOut()
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(session == nil || (session?.isBrainMode ?? false))

        Button("Actual Size") {
            session?.resetToActualSize()
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(session == nil || (session?.isBrainMode ?? false))
    }
}
```

Do **not** disable Zoom In/Out from clamp (clipboard-menu rule). Brain mode disables the whole group.

- [ ] **Step 2: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/SwiftMindMacApp.swift
git commit -m "feat(mac): View menu zoom in/out/actual size (⌘+/⌘-/⌘0)"
```

---

### Task 6: Toolbar zoom cluster

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/ContentView.swift`

- [ ] **Step 1: Add a ControlGroup next to Commands/Search/Inspector**

Inside `SessionWorkspace`'s `.toolbar`, **only** in the `if !session.isBrainMode` branch (map documents). Insert **before** the existing `ToolbarItem(placement: .automatic)` that holds Commands/Search/Inspector:

```swift
                ToolbarItem(placement: .automatic) {
                    ControlGroup {
                        Button {
                            session.zoomOut()
                        } label: {
                            Label("Zoom Out", systemImage: "minus.magnifyingglass")
                        }
                        .help("Zoom Out (⌘-)")
                        .disabled(session.viewport.isAtMinScale)
                        .accessibilityIdentifier("toolbarZoomOut")

                        Button {
                            session.zoomIn()
                        } label: {
                            Label("Zoom In", systemImage: "plus.magnifyingglass")
                        }
                        .help("Zoom In (⌘+)")
                        .disabled(session.viewport.isAtMaxScale)
                        .accessibilityIdentifier("toolbarZoomIn")

                        Button {
                            session.resetToActualSize()
                        } label: {
                            Label("Actual Size", systemImage: "1.magnifyingglass")
                        }
                        .help("Actual Size (⌘0)")
                        .disabled(session.viewport.isActualSize)
                        .accessibilityIdentifier("toolbarActualSize")
                    }
                }
```

Do **not** mix these into `EditorToolbar` (Add/Delete/Undo). Hidden automatically in My Brain because the item sits inside `if !session.isBrainMode`.

- [ ] **Step 2: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/ContentView.swift
git commit -m "feat(mac): toolbar zoom in/out/actual size cluster"
```

---

### Task 7: Command palette zoom actions

**Files:**
- Modify: `Apps/SwiftMindMac/SwiftMindMac/CommandPaletteView.swift`

- [ ] **Step 1: Append three palette items after Redo**

In `PaletteBuilder.items`, after the Redo item:

```swift
        if !session.isBrainMode {
            items.append(PaletteItem(id: "zoom-in", title: "Zoom In", subtitle: "⌘+", systemImage: "plus.magnifyingglass") {
                session.zoomIn()
                dismiss()
            })
            items.append(PaletteItem(id: "zoom-out", title: "Zoom Out", subtitle: "⌘-", systemImage: "minus.magnifyingglass") {
                session.zoomOut()
                dismiss()
            })
            items.append(PaletteItem(id: "zoom-actual", title: "Actual Size", subtitle: "⌘0", systemImage: "1.magnifyingglass") {
                session.resetToActualSize()
                dismiss()
            })
        }
```

- [ ] **Step 2: Commit**

```bash
git add Apps/SwiftMindMac/SwiftMindMac/CommandPaletteView.swift
git commit -m "feat(mac): command palette zoom in/out/actual size"
```

---

### Task 8: README + Welcome help map

**Files:**
- Modify: `README.md`
- Modify: `Apps/SwiftMindMac/SwiftMindMac/Resources/help-map.ops.json`
- Modify (generated): `Apps/SwiftMindMac/SwiftMindMac/Resources/Welcome to SwiftMind.swiftmind.html`

- [ ] **Step 1: README shortcuts / gestures**

In `### Canvas gestures (polish)` table, keep Pinch, and add:

```markdown
| **⌥ + scroll** | Zoom around the pointer |
| Two-finger scroll | Pan |
```

Add a short keyboard line near that table (or in the Navigate / M1 list):

```markdown
- **Zoom:** ⌘+ in, ⌘- out, ⌘0 actual size (100%). Also View menu, toolbar, and ⌘K. Pinch still zooms. Range 25%–300%.
```

- [ ] **Step 2: Help map ops**

In `help-map.ops.json`, under Navigate (`n_help_navigate`), after `n_help_nav_keys`:

```json
  {"op": "add-child", "parent": "n_help_navigate", "id": "n_help_nav_zoom", "text": "⌘+ / ⌘- / ⌘0 zoom · pinch · ⌥-scroll · two-finger pan"},
```

Under the folded keyboard reference, after `n_help_k11`:

```json
  {"op": "add-child", "parent": "n_help_keys", "id": "n_help_k12", "text": "⌘+ / ⌘- / ⌘0 — zoom in / out / actual size"},
```

- [ ] **Step 3: Regenerate the Welcome HTML (do not hand-edit it)**

Run: `scripts/make-help-map.sh`

Expected: `Wrote Apps/SwiftMindMac/SwiftMindMac/Resources/Welcome to SwiftMind.swiftmind.html`

- [ ] **Step 4: Commit**

```bash
git add README.md \
  "Apps/SwiftMindMac/SwiftMindMac/Resources/help-map.ops.json" \
  "Apps/SwiftMindMac/SwiftMindMac/Resources/Welcome to SwiftMind.swiftmind.html"
git commit -m "docs: canvas zoom shortcuts in README and Welcome map"
```

---

### Task 9: Verify

**Files:** none new

- [ ] **Step 1: Core tests**

Run: `swift test --filter CanvasViewportTests`

Expected: PASS.

- [ ] **Step 2: Full core suite**

Run: `swift test`

Expected: PASS (existing ~200 tests plus the new class).

- [ ] **Step 3: App loop**

Run: `./scripts/rerun-mac.sh`

Expected: tests pass, Debug app rebuilds and launches. Manually: pinch still zooms; ⌘+ / ⌘- / ⌘0; toolbar buttons disable at 25% / 300% / 100%; Option+scroll zooms under the cursor; two-finger scroll pans; switch Outline and back — scale/pan remain; My Brain hides the cluster and disables the menu.

No new XCUITest in this plan. Identifiers `toolbarZoomIn` / `toolbarZoomOut` / `toolbarActualSize` are in place for a later smoke.

---

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| `CanvasViewport` in core, clamp 0.25–3, step 1.25 | 1 |
| Anchor invariant + empty viewSize | 1 |
| Session-owned viewport, not HTML, not undo | 2 |
| Hot reload does not reset viewport | 2 (`syncFromDocument` untouched) |
| Outline keeps viewport; keyboard uses last size/center | 2 + 3 (no reset on disappear) |
| My Brain disables commands | 5, 6, 7 |
| MapCanvasView binds pinch/pan/follow | 3 |
| Option+scroll zoom, unmodified scroll pan, text-field pass-through | 4 |
| View menu, not a second View menu; ⌘+/⌘-/⌘0 | 5 |
| Toolbar ControlGroup + identifiers | 6 |
| Command palette | 7 |
| README + help map regenerate | 8 |
| `rerun-mac.sh` / `swift test` | 9 |
| No fit-to-window, no NSScrollView rewrite | not scheduled |

Type names used throughout: `CanvasViewport`, `ZoomStep`, `zoomIn()`, `zoomOut()`, `resetToActualSize()`, `setCanvasScale(_:around:width:height:)`, `panCanvas(by:)`, `rememberCanvasLayout`, `rememberCanvasPointer`.
