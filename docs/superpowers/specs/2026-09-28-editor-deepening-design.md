# Editor Deepening — 1.2 Design (approved 2026-09-28)

Goal: polish the user-facing editing experience to the extreme. No AI, no iOS.

## A. Markdown completion

1. **Strikethrough** inline `~~x~~` — parser, projection (hidden markers, strikethrough style), editing reveal.
2. **Highlight** inline `==x==` — same treatment, yellow background style.
3. **Divider** block `---` / `***` — new block kind; renders a hairline row; editing keeps the marker line.
4. **Tables** — GFM pipe tables: parser block kind `.table(rows:)`, projection with monospaced grid, caret editing maps display cell edits back to source rows. No column alignment syntax beyond `---` separator parsing.
5. **Editor shortcuts**: ⌘1–⌘6 toggle headings; ⌘⇧X strikethrough; ⌘⇧H highlight; toolbar buttons for both.

## B. Sketch board

1. **Color palette** — 8 colors (black, gray, white, red, orange, yellow, green, blue), persisted per session.
2. **Line widths** — thin/medium/thick (2/4/8).
3. **Shape tools** — line, arrow, rectangle, ellipse: drag preview, committed as PKStrokes on release.
4. **Stroke undo/redo** — per-stroke stack in the editor (⌘Z/⇧⌘Z inside sketch), independent of map undo.
5. **Select & move** — lasso-free: tap select tool, tap a stroke (bbox hit test), drag translates it; Del removes selection.

## C. Shortcuts & selection

1. **Multi-select** — ⇧click toggles node in selection; marquee: drag on empty canvas with ⇧, or drag with no node under start; batch ⌫ delete; batch style/ops loop commands as one undo via CompositeAgentCommand-style batch.
2. **Sibling reorder** — ⌥↑ / ⌥↓ moves the selected node among siblings (MoveNodeCommand index ±1).
3. **Fold all / unfold all** — ⌘⇧. toggles.
4. **Outliner keys** — Tab creates child (committing any edit first), Enter creates sibling; in note editor unchanged.

## Testing

- Core: parser/projection/editing-session tests for strikethrough, highlight, divider, table; reorder command tests; multi-select store tests.
- App: UI tests per feature group (extend existing suite patterns).
- Full suites green before finish; incremental commits per phase.

Out of scope: column alignment styling, nested tables, AI features, iOS.
