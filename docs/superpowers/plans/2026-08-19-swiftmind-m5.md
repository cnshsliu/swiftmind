# SwiftMind M5 Implementation Plan (Automation + Import / 2.0 direction)

> **For agentic workers:** Use subagent-driven-development or execute task-by-task. Checkboxes track progress.

**Goal:** Ship map automation: **L2 declarative bulk actions** (no code) and **L3 sandboxed JavaScript** with tight default permissions, plus best-effort **Freeplane `.mm` import**. Mobile shells (iPad/iPhone) are split out — they need product decisions, not just engineering (see M5c).

**Architecture (spec §7):** L2 builds on the existing `MapFilter` + commands — an action is "for every node matching rule R, apply mutation M", executed as one undoable command. L3 runs user scripts in **JavaScriptCore** (system framework: zero deps, App-Sandbox/App-Store safe, already on iOS for the future shells) behind a `ScriptRuntime` protocol — the seam spec §3.3 promised. Scripts **never mutate the map directly**: the JS API records *intents* (`mindmap.setText(id, …)` etc.), which are validated and applied as a single undoable command batch only after the script finishes cleanly.

**Tech Stack:** Existing Swift 5.10 / SPM / SwiftUI / XCTest + JavaScriptCore (system).

**Out of scope:** embedding scripts in HTML (spec §4.5: no page JS for automation), network/file/process access from scripts (JSC exposes none by default — keep it that way), script sharing/marketplace, mobile UI work.

---

## M5a — Automation (Mac)

### Design decisions

- **Intents, not mutation.** The JS `mindmap` API is read + record. A script that throws mid-run applies nothing. Everything a script does is one undo step.
- **Permission model v1:** scripts are local, user-triggered (like Shortcuts). Capabilities: read map, propose mutations. No I/O exists to gate — JSC has no network/file/process. If capabilities ever grow, gate them per-script then.
- **Runaway scripts:** run the `JSContext` on a background queue; the caller waits with a timeout (2s). On timeout the context is abandoned and the run reports an error — the map is untouched (intents never applied). Documented limitation: an abandoned context leaks its thread until exit; acceptable for user-triggered local scripts.
- **Scripts live app-side, not in documents.** v1 entry point: command palette → "Run Script…" → pick a `.js` file → runs against the current map. No new persistence format.

### L2 file map

```text
Sources/SwiftMindCore/
  Automation/
    BulkAction.swift             # NEW — enum: setAttribute/removeAttribute/addIcon/removeIcon/setStyleName
  Commands/
    ApplyBulkActionCommand.swift # NEW — match via FilterRule, snapshot prior state, one undo step
Apps/SwiftMindMac/
  FilterBarView.swift            # "Apply to N matches…" menu when a filter is active
```

### L3 file map

```text
Sources/SwiftMindCore/
  Scripting/
    ScriptRuntime.swift          # NEW — protocol + ScriptResult + ScriptIntent
    MapScriptAPI.swift           # NEW — read model + intent recording (core-side)
    JavaScriptCoreRuntime.swift  # NEW — ScriptRuntime on JSContext (import JavaScriptCore)
  Commands/
    ApplyScriptIntentsCommand.swift # NEW — validated intent batch, one undo step
Apps/SwiftMindMac/
  ScriptRunner.swift             # NEW — pick .js, run with timeout, toast result
  CommandPaletteView.swift       # "Run Script…" entry
Tests/SwiftMindCoreTests/
  BulkActionTests.swift
  ScriptingTests.swift           # API reads, intent capture, throw-applies-nothing, timeout
```

### JS API v1 (the `mindmap` global)

```js
mindmap.title()                       // map title
mindmap.rootId()                      // root node id
mindmap.node(id)                      // { id, text, note, attrs: {...}, icons: [...] } or null
mindmap.children(id)                  // [childId, ...]
mindmap.find(text)                    // [nodeId, ...] — title/note substring
// intents (recorded, applied after success as one undo step):
mindmap.setText(id, text)
mindmap.setNote(id, markdown)
mindmap.setAttr(id, name, value)      // value "" removes
mindmap.addIcon(id, iconId)
mindmap.removeIcon(id, iconId)
mindmap.setStyle(id, styleName)       // "" clears
mindmap.log(message)                  // shown in result toast/console
```

### Tasks (M5a)

- [x] **T1 L2 core:** `BulkAction` + `ApplyBulkActionCommand` (filter match → snapshot → apply → single undo); unit tests
- [x] **T2 L2 UI:** "Apply to N matches…" menu on the active filter bar; palette entry
- [x] **T3 ScriptRuntime protocol + intent model:** `ScriptIntent` enum, `ScriptResult` (intents, logs, error), `ApplyScriptIntentsCommand` with validation (unknown id → skip + report); unit tests with a fake runtime
- [x] **T4 JavaScriptCore runtime:** `JSContext` bridge, API object, intent recording, error capture, 2s timeout; unit tests (reads, intents, throw-applies-nothing, timeout, no-`require`/`load` proof)
- [x] **T5 Mac runner + palette:** open panel → run → apply intents → toast "Script applied 12 changes" / error; XCUITest smoke
- [x] **T6 Verify + docs:** README scripting section + JS API reference, AGENTS.md, sample script under `docs/examples/`

**M5a exit:** User writes `mindmap.find("todo").forEach(id => mindmap.addIcon(id, "check"))` in a `.js` file, runs it from the palette, sees icons appear as **one** undoable step; a script that throws changes nothing; a runaway script times out with an error toast.

---

## M5b — Freeplane `.mm` import (best-effort)

- [x] `MMImport` in core: parse Freeplane XML (`<node TEXT=...>` nesting, NOTE, rich content stripped to text)
- [x] File → Open picks `.mm` → new document via import (not a codec — one-way)
- [x] Tests with a small `.mm` fixture; documented best-effort caveats

## M5c — Mobile shells (iPad/iPhone) — needs product decisions first

Open questions before planning: single app target vs separate, document browser vs custom library, touch gesture vocabulary (no hover/Return), iCloud posture. **Not started by this plan.**

---

## Implementation order

```text
T1 L2 core → T2 L2 UI
T3 protocol/intents → T4 JSC runtime → T5 runner/palette
T6 verify + docs
M5b after M5a
```
