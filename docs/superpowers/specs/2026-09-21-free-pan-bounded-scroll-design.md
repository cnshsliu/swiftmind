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

One shared rule for both gestures: **content edge + margin**.

The scaled content bounding box must always intersect the viewport inset by
25% per axis (the "safe rect"). Panning is free inside that envelope; at the
boundary it is a hard stop (no rubber-banding for now — YAGNI). Zoom-aware
automatically because the bounds are scaled before comparison.

The existing stricter `clampedOffset` (content-center rule) is unchanged and
remains in use only as the launch-time poison heal alongside
`healRestoredViewport`.

## Changes

### Core — `Sources/SwiftMindCore/Layout/CanvasViewport.swift`

Add `visibleClampedOffset(contentBounds:viewWidth:viewHeight:) -> Point2D`:

- Safe rect = viewport inset by `margin = 0.25 × view dimension` per axis.
- Content bbox in view coords is `p_map × scale + viewSize/2 + offset`;
  clamp `offset.x` to `[margin − maxXv, viewW − margin − minXv]` (same for y).
  The feasible interval is always non-empty (width = `viewW − 2·margin +
  contentW·scale`).
- Degenerate inputs (view too small, `scale ≤ 0`) return the offset
  unchanged.

### App — `Apps/SwiftMindMac/SwiftMindMac/MapCanvasView.swift`

- `offset` setter: use `visibleClampedOffset` instead of `clampedOffset`.
  This one change covers **drag** (the pan branch writes `offset`).
- **Scroll**: the wheel/trackpad monitor stops calling
  `session.panCanvas(by:)` and instead writes through the same `offset`
  setter (`offset += delta`), so scroll inherits the identical clamp.
- **Zoom**: after each `setCanvasScale` call site (pinch magnify, ⌘-scroll
  zoom, zoom commands) re-apply the clamp (`offset = offset`) so a zoom-out
  anchored near an edge cannot strand the view blank.

`DocumentSession.panCanvas` stays (used by tests/other callers) but the
canvas no longer uses it for interactive scroll.

## Tests

- `Tests/SwiftMindCoreTests/ViewportClampTests.swift`: new cases for
  `visibleClampedOffset` — no-op when content is comfortably visible;
  clamped at both extremes on both axes; correct at `minScale` (0.25) and
  `maxScale` (3.0); degenerate view size passes through.
- Existing `clampedOffset` heal tests untouched.
- Manual feel-check in the dev app: drag to map edges at several zoom
  levels; scroll until the stop; confirm the viewport never goes blank.

## Non-goals

- Rubber-band / elastic overscroll at the boundary.
- Changing the poison-heal rule or the persisted viewport format.
