# Free dragging + never-blank scrolling — design (2026-09-21)

## Problem

Two inconsistent pan behaviors on the map canvas:

- **Dragging** (background drag, Space/⌘+drag) routes through the `offset`
  setter in `MapCanvasView`, which applies `CanvasViewport.clampedOffset` —
  a rule written as a *poisoned-viewport heal* (content center must stay
  within 80pt of the view's center region). As a pan limit it is far too
  strict: at zoom 1 you can only drag until the content center nears the
  view edge, so the top-most/bottom-most nodes feel unreachable.
- **Scrolling** (wheel/trackpad) calls `DocumentSession.panCanvas` →
  `CanvasViewport.pan` with **no clamp at all** — the map can be scrolled
  entirely offscreen into a blank viewport.

## Decision

One shared rule for both gestures: **content coverage** (the scroll-view
rule), revised after the first cut. The first implementation used "content
bbox must intersect the viewport inset by 25% per axis" — that guarantees
intersection, not coverage: at the pan extreme only a 25% band of content
remained and the rest of the screen was blank, with the band's map-space
size varying by zoom. It felt unnatural at anything but 1:1.

The final rule, per axis:

- Content (scaled) **larger than the view**: the content bounding box must
  *cover* the whole viewport — panning stops **flush at the content edge**,
  so the extreme position still shows a full screen of content (like
  scrolling a PDF).
- Content **smaller than the view**: the bounding box stays *inside* the
  viewport — the map can be positioned anywhere in the window but can never
  be pushed out.

Unified formula per axis: with `minV0 = bounds.min·scale + viewSize/2` and
`maxV0 = (bounds.min + bounds.size)·scale + viewSize/2` (offset-free view
coords), the offset clamps to `[min(a,b), max(a,b)]` where
`a = viewSize − maxV0`, `b = −minV0`. The interval is always non-empty.
Zoom-aware automatically because the bounds are scaled; window resizes and
zoom changes re-apply the clamp.

The existing stricter `clampedOffset` (content-center rule) is unchanged and
remains in use only as the launch-time poison heal alongside
`healRestoredViewport`.

## Changes

### Core — `Sources/SwiftMindCore/Layout/CanvasViewport.swift`

Add `panClampedOffset(contentBounds:viewWidth:viewHeight:) -> Point2D`
implementing the coverage rule above. Degenerate inputs (zero view size,
`scale ≤ 0`) return the offset unchanged.

### App — `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`

- `offset` setter: use `panClampedOffset` instead of `clampedOffset`.
  This one change covers **drag** (the pan branch writes `offset`).
- **Scroll**: the wheel/trackpad monitor stops calling
  `session.panCanvas(by:)` and instead writes through the same `offset`
  setter (`offset += delta`), so scroll inherits the identical clamp.
- **Zoom**: `onChange(of: session.viewport.scale)` re-applies the clamp
  (`offset = offset`) so a zoom-out anchored near an edge cannot strand
  the view blank. Covers pinch, ⌘-scroll, and menu zoom uniformly.
- **Resize**: `onChange(of: geo.size)` also re-clamps — shrinking the
  window can otherwise expose blank space.

`DocumentSession.panCanvas` stays (used by tests/other callers) but the
canvas no longer uses it for interactive scroll.

## Tests

- `Tests/SwiftMindCoreTests/ViewportClampTests.swift`: cases for
  `panClampedOffset` — no-op inside the feasible interval; flush stops at
  both content edges; small content stays inside the viewport at `minScale`
  (0.25); flush stop at `maxScale` (3.0); degenerate view passes through.
- Existing `clampedOffset` heal tests untouched.
- Manual feel-check in the dev app: drag/scroll to map edges at 1:1,
  zoomed in, and zoomed out; confirm the viewport never shows blank beyond
  the content.

## Non-goals

- Rubber-band / elastic overscroll at the boundary.
- Changing the poison-heal rule or the persisted viewport format.
