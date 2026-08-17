# SwiftMind M3 Implementation Plan (Power Layer / 1.0 candidate)

> **For agentic workers:** Use subagent-driven-development or execute task-by-task. Checkboxes track progress.

**Goal:** Ship power-user workflows: named styles, attributes, filters, bookmarks, basic conditional styles, and layout that respects filter hide/highlight — without formulas/scripts (M4/M5).

**Architecture:** Extend `SwiftMindCore` with StyleSheet + AttributeRegistry + Filter + Bookmarks on `MindMap`; resolve styles for layout/render; HTML schema stays **1** with additive sections. Mac UI: inspector panels, filter bar, bookmark list, palette actions.

**Tech Stack:** Existing Swift 5.10 / SPM / SwiftUI / XCTest / XCUITest.

**Out of scope:** encryption, clouds, formulas, scripts, `.mm` import, iPad.

---

## File map (M3)

```text
Sources/SwiftMindCore/
  Model/
    NodeAttribute.swift          # NEW
    AttributeRegistry.swift      # NEW
    StyleSheet.swift             # NEW (named styles)
    MapFilter.swift              # NEW
    Bookmark.swift               # NEW
    Node.swift                   # + attributes, styleName?
    MindMap.swift                # + registry, stylesheet, filter, bookmarks
  Style/
    StyleResolver.swift          # NEW — merge named + local + conditional
  Filter/
    FilterEvaluator.swift        # NEW
  Commands/
    SetAttributesCommand.swift
    RegisterAttributeCommand.swift
    SetStyleNameCommand.swift
    SetFilterCommand.swift
    AddBookmarkCommand.swift
    RemoveBookmarkCommand.swift
  HTML/HTMLCodec.swift           # encode/decode new sections
  Layout/LayoutEngine.swift      # skip hidden filtered nodes
  Layout/MapSnapshot.swift       # isHighlighted?

Apps/SwiftMindMac/
  AttributeInspectorSection.swift
  FilterBarView.swift
  BookmarksSidebar.swift
  InspectorView / ContentView / CommandPalette updates
```

---

### Task 1: Attributes model + commands + tests

**Files:** Create `NodeAttribute.swift`, `AttributeRegistry.swift`; modify `Node`, `MindMap`; create commands; tests.

- [x] `NodeAttribute` `{ name, value }` (string storage)
- [x] `AttributeRegistry` list of names (and optional type: string/number/bool)
- [x] `Node.attributes: [NodeAttribute]`
- [x] `MindMap.attributeRegistry`
- [x] `SetAttributesCommand`, `UpsertAttributeCommand` (+ remove via set empty)
- [x] Unit tests for mutate + undo

### Task 2: HTML encode/decode attributes (schema 1 additive)

- [x] Per-node `node-attrs` list
- [x] Map-level `attribute-registry` section
- [x] Round-trip tests; legacy files still decode

### Task 3: Named styles (StyleSheet)

- [x] `StyleSheet` = `[String: NodeStyle]` + default names (`topic`, `important`, `note`)
- [x] `Node.styleName: String?` + local `Node.style` overrides
- [x] `StyleResolver.resolve(node, sheet)` → effective `NodeStyle`
- [x] Layout/canvas use resolved style
- [x] Commands: `SetStyleNameCommand`
- [x] HTML: `data-style-name="topic"` (custom stylesheet section deferred)

### Task 4: Filter model + evaluator

- [x] `MapFilter` with `mode: hide | highlight` and `FilterRule` cases
- [x] `FilterEvaluator.matches` / `matchesIncludingDescendants`
- [x] `MindMap.activeFilter`
- [x] `SetFilterCommand` / clear
- [x] Unit tests

### Task 5: Layout + snapshot respect filter

- [x] Hide mode: path-to-root visibility
- [x] Highlight mode: `NodeVisual.isHighlighted`
- [x] Tests for hide path-to-root

### Task 6: Bookmarks

- [x] `Bookmark { id, nodeID, label }`
- [x] `MindMap.bookmarks`
- [x] Add/Remove commands
- [x] HTML section
- [x] Unit tests

### Task 7: Mac UI — attributes inspector

- [x] Section: table of attrs for selection; add/remove
- [x] Auto-register new names into registry

### Task 8: Mac UI — filter bar

- [x] Sidebar: text / `attr=value` filter + mode toggle
- [x] Clear filter
- [x] Status shows filter counts

### Task 9: Mac UI — bookmarks + palette

- [x] Sidebar bookmarks list → select + unfold path
- [x] Palette: bookmark, go to bookmark, named styles, clear filter

### Task 10: Conditional styles (basic)

- [ ] Rules: `if hasIcon(x) apply styleName` or `if attr status==done apply style` — **deferred** (post-M3 polish)
- [ ] Applied in `StyleResolver` after named style
- [ ] HTML encode rules
- [ ] Simple UI: list rules in inspector/settings

### Task 11: Performance baseline

- [ ] Snapshot culling optional if > N nodes (viewport) — only if needed
- [x] Avoid full document rewrite on selection (already done)

### Task 12: Verify + docs

- [x] Unit tests for M3 power layer
- [x] README M3 section
- [ ] Tag `m3-complete` when exit criteria met

**M3 exit:** User can tag nodes with attributes, filter the map, jump via bookmarks, and apply named styles in a real project map without data loss.

---

## Implementation order (dependency)

```text
T1 Attributes → T2 HTML attrs
T3 Named styles (parallel after T1)
T4 Filter → T5 Layout filter
T6 Bookmarks (parallel)
T7–T9 UI
T10 Conditional styles
T11–T12 polish
```
