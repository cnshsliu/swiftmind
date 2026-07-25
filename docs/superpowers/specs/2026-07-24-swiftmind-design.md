# SwiftMind Design Spec

> Native macOS mind-mapping app (pure Swift), inspired by Freeplane’s power — not a Java/Swing port.  
> Date: 2026-07-24  
> Status: Draft for user review (brainstorming complete)

## 1. Product intent

### 1.1 What we are building

**SwiftMind** is a modern mind-mapping application for Apple platforms, starting with **macOS**, written in **pure Swift**, with a **native Apple UI** (SwiftUI + system materials / Liquid Glass-class chrome where the OS provides it).

It takes **inspiration** from [Freeplane](https://www.freeplane.org/) (structure, power-user depth, open local files) but is a **greenfield** product:

- No JVM, Swing, OSGi, or Groovy.
- No attempt to pixel-match Freeplane’s UI.
- Freeplane `.mm` may become an **optional importer** later; it is **not** the native format.

### 1.2 Product positioning decisions

| Topic | Decision |
|-------|----------|
| Positioning | **Modern mind map first**; Freeplane compatibility later/optional |
| Native format | **HTML** as serialization of the mind-map model |
| Browser open | **Bonus**: same file should be shareable as **read-only** presentation when possible |
| Human-editability | Inherent to text/HTML; not a primary product pillar |
| Platform order | **macOS first**; architecture must not block **iPad / iPhone** |
| Feature depth | **Power-user (Freeplane-class “C”)** as **north star** |
| Shipping | **Phased releases** — every milestone is installable and useful |
| Layout | **Auto mind-map layout + pin/free positions + outline view** |
| Storage | **Local files first** + **optional iCloud** container |
| Node content | **Plain-text title** + **style/icons/links/attrs as data** + **Markdown notes** |
| Formula / script | **L0–L2 first**; **L3 = sandboxed JS** (not Groovy), later |

### 1.3 What “HTML storage” means

HTML is the **persistence format**, not the product runtime:

- From the **model’s** point of view: tags, attributes, and classes record mind-map data so the app can **read/write and implement all map features**.
- The model does **not** care about browser layout/CSS as a source of truth.
- If the saved HTML can also open in a browser with a **read-only** rendering close to the app, that is highly desirable for sharing.
- Editing always happens in the native app (pointer, keyboard, later touch).

---

## 2. Goals and non-goals

### 2.1 Goals

1. Delightful, modern **macOS** mind mapping (auto layout, outline, inspector, shortcuts).
2. Reliable **open local document** model with **HTML** round-trip.
3. Architecture ready for **power features**: styles, attributes, filters, formulas, scripts.
4. Architecture ready for **iPad/iPhone**: shared core, input intents, optional iCloud.
5. Optional **read-only** browser view of the same file for sharing.

### 2.2 Non-goals (at least through power-user 1.0 / M3)

- Porting Freeplane Java/Swing/OSGi code.
- WebView as the primary editor.
- Real-time multiplayer collaboration.
- 100% Freeplane shortcut/menu/plugin compatibility.
- In-browser editing of the document.
- Linux/Windows clients.
- Pixel-perfect parity between Canvas renderer and browser CSS skin.

---

## 3. Architecture (Approach 1 — recommended, accepted)

### 3.1 One-liner

**UI-free mind-map core (Swift Package) + native macOS shell; HTML is a codec; the canvas consumes layout snapshots and never owns business truth.**

### 3.2 Module diagram

```text
┌─────────────────────────────────────────────────────────────┐
│  SwiftMindMac (App target)                                  │
│  • DocumentGroup / UTType / optional iCloud                 │
│  • Menu · shortcuts · toolbar · Settings · multi-window     │
│  • Outline · Inspector · Search · Command Palette           │
│  • MapCanvasHost (SwiftUI wrapping a MapRenderer)           │
│  • Pointer / trackpad / keyboard → InputIntent              │
└────────────────────────────┬────────────────────────────────┘
                             │ Commands / MapStore observation
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  SwiftMindCore (Swift Package · no AppKit/UIKit/SwiftUI)    │
│  Model · Commands · Selection · Layout · Filter/Style       │
│  Formula hooks (L0→L1) · ScriptRuntime protocol (L3 later)  │
│  HTMLCodec · future Import (.mm)                            │
└────────────────────────────┬────────────────────────────────┘
                             ▼
                      *.swiftmind.html
                      + optional read-only CSS/JS skin
```

### 3.3 Cross-platform seams (day one)

| Abstraction | Purpose |
|-------------|---------|
| `MapStore` / `CommandBus` | UI only dispatches commands and observes state |
| `InputIntent` | pan/zoom/select/drag/edit independent of mouse vs touch |
| `MapRenderer` protocol | Canvas / CoreGraphics / Metal / future iOS swap |
| `ScriptRuntime` protocol | No-op until M5; engine choice not frozen in Core |
| `CloudDocumentLocator` | Local paths vs iCloud; Core stays file-agnostic |

### 3.4 Edit data flow

```text
Gesture / shortcut
  → InputIntent
  → CommandBus.execute(Command)
  → Model mutation + Undo stack
  → LayoutEngine.invalidate(affected)
  → MapSnapshot
  → MapRenderer.draw
  → (debounced) HTMLCodec.encode → dirty document → save
```

**Invariant:** Views never mutate the tree directly. All mutations go through commands so undo, scripts, and future automation share one path.

### 3.5 Rendering strategy

| Phase | Strategy |
|-------|----------|
| Early milestones | `MapRenderer` + SwiftUI `Canvas` + simple hit-testing |
| Larger maps / heavier animation | Same snapshot protocol; swap in `NSView`+CG or Metal |
| Outline | Binds the same `MapStore` tree; no full geometric layout required |

### 3.6 Rejected approaches

| Approach | Why rejected |
|----------|----------------|
| Logic only in SwiftUI ViewModels | Fights power features and multi-platform extraction |
| WKWebView as main canvas | Conflicts with native UI goal; blurs script safety and sharing |

### 3.7 Suggested repo layout

```text
swiftmind/
  Package.swift
  Sources/
    SwiftMindCore/
    SwiftMindHTML/          # optional separate target; may live inside Core
  Tests/
    SwiftMindCoreTests/
  Apps/
    SwiftMindMac/
  docs/
    superpowers/specs/
    superpowers/plans/
```

---

## 4. Domain model and HTML schema

### 4.1 Authority

| Layer | Role |
|-------|------|
| Runtime model | Single source of truth while editing |
| HTML file | Persistent projection; full round-trip of model data |
| Browser | Consumes optional skin only; not the editor |

### 4.2 Conceptual model

```text
Map
  id, title, schemaVersion
  root: Node
  styles: StyleSheet
  attributesRegistry
  viewState?          # zoom, scroll, selection — optional persistence
  meta

Node
  id                  # stable across saves
  text                # plain title (may include newlines)
  noteMarkdown?       # single note field to start
  isFolded
  children: [Node]
  side?               # left | right | auto
  styleRef? / localStyle
  icons: [IconRef]
  links: [Link]       # url | nodeId | file
  attributes: [Attr]
  positionPin?        # {x,y} when pinned; nil = pure auto layout
  cloud?              # later
```

**IDs:** Assigned at creation; preserved on load; never use array indices as identity.

**Title vs style:** `text` is never HTML. Appearance lives in style data.

**Notes:** Start with one Markdown `note`. Freeplane-style separate details can be a later schema bump if needed.

### 4.3 HTML serialization principles

1. Valid **HTML5**, UTF-8.
2. **Semantic tree first** (nested lists/sections), not absolute-positioned divs as authority.
3. Map semantics in **`data-*` / class / controlled attributes**; presentation CSS is optional skin.
4. **Forward compatible:** unknown fields preserved when possible.
5. **`schemaVersion`** on the root; migrators for breaking changes.
6. Optional **read-only skin** (`<style>` + minimal JS). Editor treats model data as authoritative and may regenerate skin on save.

### 4.4 File identity

- Working extension: **`.swiftmind.html`**
- UTType: app-declared (e.g. `com.yourorg.swiftmind.html` — final reverse-DNS TBD)
- Finder opens with SwiftMind; also readable as text in any editor

### 4.5 Illustrative structure (tag names may be refined in implementation)

```html
<!DOCTYPE html>
<html lang="en" data-swiftmind-version="1">
<head>
  <meta charset="utf-8"/>
  <title>Map title</title>
  <style>/* optional read-only skin */</style>
</head>
<body>
  <article class="swiftmind-map" data-schema="1" data-map-id="m_…">
    <ul class="mind-root" data-node-id="n_root">
      <li data-node-id="n_1"
          data-side="right"
          data-folded="false"
          data-style="topic">
        <div class="node-title">Q3 Launch</div>
        <div class="node-note" hidden>Markdown…</div>
        <ul class="children">…</ul>
      </li>
    </ul>
    <section class="stylesheet" hidden>…</section>
  </article>
</body>
</html>
```

**Formulas (later):** e.g. `data-formula="…"` plus optional cached display value — do not require the browser to execute untrusted code.

**Scripts:** not embedded as freely executing page JS for map automation; L3 runs inside the app sandbox later.

### 4.6 Round-trip matrix

| Path | Behavior |
|------|----------|
| App save | Model → encode (data + optional skin) |
| App open | Decode → model; skin may be discarded/regenerated |
| Browser open | Skin provides read-only hierarchy/map-ish view |
| Hand-edited HTML | Best-effort parse; corrupt structure → clear error |

---

## 5. Canvas, layout, outline

### 5.1 Three presentations, one model

| View | Role |
|------|------|
| Mind-map canvas | Spatial navigation, reparent/reorder, zoom/pan |
| Outline | Fast keyboard editing, fold, reorder |
| Read-only HTML | Share outside the app |

Selection and focus are shared across canvas and outline.

### 5.2 Layout modes

- **`positionPin == nil`:** node participates in automatic mind-map layout.
- **`positionPin != nil`:** node uses pinned coordinates; edges still connect; children may still auto-layout under policy defined in implementation.

**Auto layout v1:** root center (logical origin), left/right/`auto` balancing, bezier (or similar) edges, folded subtrees omit layout space.

**Pin v1:** per-node pin/unpin; subtree group offset can wait.

**Incremental layout:** commands mark dirty subtrees; avoid full-map relayout as the only path when maps grow.

### 5.3 MapSnapshot

Layout produces a framework-agnostic snapshot:

- Node frames, resolved styles, depth, selection/fold flags
- Edge paths
- Canvas bounds

Renderer draws and hit-tests only; mutations go back through intents/commands.

### 5.4 Input intents (examples)

Select, BeginEdit, Reparent, Reorder, Pin, Zoom, Pan, DeleteSelection, Indent, Outdent, etc.

### 5.5 Performance

| Scale | Strategy |
|-------|----------|
| Hundreds of nodes | Full layout + Canvas acceptable |
| Thousands+ | Viewport culling, spatial hit index |
| Extreme | Swap renderer implementation; keep snapshot protocol |

Virtualization is a **render-layer** concern; Core may still hold the full model.

### 5.6 Motion

Light layout animations; interruptible; respect Reduce Motion. System chrome follows Apple HIG; node chrome stays readable.

---

## 6. macOS application shell and UI

### 6.1 Design language

- **System-first** SwiftUI controls and materials.
- **Liquid Glass / advanced materials** on chrome (toolbar, sidebars, floating inspector) via progressive API use — not on every map node fill.
- **Content-first:** canvas is primary; chrome is collapsible.
- **Power in panels:** Inspector, sheets, Command Palette (⌘K) — not a Freeplane-style icon strip recreation.

**Minimum OS:** target modern macOS (implementation choice: 14+ baseline with newer material APIs as enhancements). Core has no OS version dependency.

### 6.2 Main window IA

```text
Sidebar | Main (Outline | Map segment) | Inspector
Toolbar: add child, delete, fold, filter (later), search, share
Status: zoom, node count, path crumb (optional)
```

- `NavigationSplitView` + document windows via `DocumentGroup`
- Focus mode: hide side columns

### 6.3 System integration

| Capability | Approach |
|------------|----------|
| File type | UTType + `.swiftmind.html` |
| Open/save | `FileDocument` / `ReferenceFileDocument` + HTMLCodec |
| iCloud | Optional container (decision B); default remains local-friendly |
| Share | System share of file; optional “export clean read-only HTML” |
| Undo | In-memory command undo; file versions optional later |

### 6.4 Accessibility and i18n (reserve)

- Outline must be VoiceOver-complete early.
- Canvas accessibility can trail outline.
- Strings localizable; en/zh reasonable first locales.

---

## 7. Formula and scripting strategy

Freeplane uses **Groovy formulas** (`=` on nodes) and **Groovy scripts** for automation. SwiftMind does **not** copy that stack.

| Layer | Role | Tech direction |
|-------|------|----------------|
| **L0** | Built-in aggregates (sum, count, completion %) | Pure Swift |
| **L1** | Safe node formulas | Restricted expression DSL; stored in HTML data attrs |
| **L2** | Rules / bulk actions without general code | Declarative actions |
| **L3** | User scripts / plugins | **Sandboxed JavaScript** (or equivalent) + map API; tight default permissions |

**Why better than Groovy for this product:** App sandbox / future App Store, multi-platform core, safer sharing HTML, more approachable than embedding a JVM language.

---

## 8. Phased milestones

Every milestone is shippable.

### M0 — Skeleton

- Xcode app + `SwiftMindCore` package
- Minimal `Map`/`Node`, CommandBus + undo (insert/delete/setText)
- HTMLCodec v1 nested-list round-trip
- DocumentGroup open/save
- Placeholder UI

**Exit:** New → edit tree → save → relaunch → same tree.

### M1 — First real map (≈ 0.1)

- LayoutEngine v1 (root, sides, fold)
- Snapshot + canvas renderer, select, zoom/pan
- Add child/sibling, delete, drag reparent/reorder
- Outline v1 shared selection
- In-place title edit
- Basic whole-node styles
- Optional read-only HTML skin

**Exit:** GUI-only session map + shareable HTML hierarchy in browser.

**Out of scope:** attributes, filters, formulas, scripts, pin, iCloud.

### M2 — Daily driver (≈ 0.2)

- Markdown notes in inspector
- URL + node links
- Icons/tags (small built-in set)
- Search
- Pin/unpin
- Command Palette ⌘K
- Multi-window stability
- Optional iCloud wiring

**Exit:** Real personal use without data loss.

### M3 — Power layer (1.0 candidate)

- StyleSheet, named + level styles, local overrides
- Basic conditional styles
- Attribute registry + per-node values
- Filters (compose conditions; hide/highlight)
- Richer edges/clouds as needed
- Bookmarks / in-map navigation
- Optional branch encryption (end of M3 or 1.1)
- Performance for ~1k+ nodes

**Exit:** Real project workflow with styles + attributes + filters.

### M4 — Computation (1.x)

- L0 aggregates, L1 safe formulas, dependency invalidation, inspector UX

### M5 — Scripts and multi-device (2.0 direction)

- L3 sandboxed JS + permissions
- Stronger L2 actions
- iPad/iPhone shells on shared Core
- Optional `.mm` import (best-effort)

### Dependency sketch

```text
M0 → M1 → M2 → M3 → M4 → M5
           └─ optional iCloud
```

Schema: start at version 1; prefer additive fields; breaking changes require version bump + migrator.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Scope explodes into “full Freeplane” | Hard milestone gates; hooks without UI for future work |
| Canvas performance | Snapshot, dirty layout, culling, swappable renderer |
| HTML schema mistakes | Versioning, migrators, unknown-field preservation, round-trip tests |
| Browser look ≠ app | Success = clear structure, not pixel match |
| Script security | No L3 until sandbox design; default deny |
| Bypassing CommandBus | Review invariant; single mutation path |
| Early sync complexity | Local-first; simple iCloud document model only |
| Freeplane user expectation mismatch | Messaging: new app + HTML; `.mm` later optional |

---

## 10. Success criteria

| Milestone | Success looks like |
|-----------|-------------------|
| M1 | Non-dev completes create/edit/save/reopen; browser shows hierarchy |
| M2 | Comfortable daily personal use; no silent corruption |
| M3 | Styles + attributes + filters form a coherent power workflow; ~1k nodes usable |
| Long-term | M4/M5 and mobile shells without rewriting Core |

---

## 11. Reference: Freeplane (context only)

Freeplane is a large Java/Swing mind mapper (~1500+ core Java files plus plugins: formula, script, markdown, LaTeX, SVG, AI, etc.), with `.mm` XML maps. Useful as a **feature encyclopedia and UX checklist**, not as code to transliterate.

Key Freeplane capability areas to remember when prioritizing power features: map model, styles, filters, attributes, links, notes, icons, encryption, export, presentations, bookmarks, formulas, scripting.

---

## 12. Open items (resolve during implementation planning)

1. Final bundle ID / UTType reverse-DNS and product display name.
2. Exact HTML tag/class vocabulary (freeze in M0/M1 with tests).
3. macOS deployment target number (14 vs 15 vs latest).
4. Whether `note` alone is enough long-term vs Freeplane details+note.
5. JS engine choice for M5 (JavaScriptCore vs other) — decide near M5, not M0.
6. License (if open source) — product decision, not architecture.

---

## 13. Approval record

| Section | User |
|---------|------|
| Approach 1 (Core + native shell) | Agreed |
| §1 Architecture | OK |
| §2 Model + HTML | OK |
| §3 Canvas / layout / outline | OK |
| §4 macOS shell / modern UI | OK |
| §5 Milestones | OK |
| §6 Risks / success | Presented in this doc |

**Next step after user accepts this file:** write implementation plan under `docs/superpowers/plans/` starting with **M0 + M1** (not the entire M0–M5 mega-plan in one go unless requested).
