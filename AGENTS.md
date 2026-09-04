# AGENTS.md — SwiftMind

Guidance for AI coding agents working in this repository. Assumes no prior knowledge of the project.

## Project overview

**SwiftMind** is a native **macOS mind-mapping app** written in pure Swift. Its defining trait: documents are **plain HTML files** with the extension `.swiftmind.html` — the map model is serialized as nested `<ul>`/`<li>` lists, so the same file opens as a **read-only hierarchy in any browser** without the app installed. Editing always happens in the native app (no WebView editor).

The architecture (from `docs/superpowers/specs/2026-07-24-swiftmind-design.md`):

> UI-free mind-map core (Swift Package) + native macOS shell; HTML is a codec; the canvas consumes layout snapshots and never owns business truth.

Feature state: milestones M0–M4 are implemented, plus M5a/M5b — outline + canvas views, auto layout with pin/free positions, fold, drag reparent, Markdown notes, URL/node links, icons, search (⌘F), command palette (⌘K), node attributes with a map-level registry, named styles, conditional style rules, filters (hide/highlight), L2 bulk actions on filter matches, bookmarks, multi-window support, L1 formulas with L0 aggregates (sum/count/progress) whose computed values are derived data (memoized by `FormulaEngine`, never stored), L3 sandboxed JavaScript via the palette (intent-based, one undo step), and best-effort Freeplane `.mm` import. See `README.md` for the full feature list and keyboard shortcuts.

## Repository layout

```
Package.swift                  # SPM manifest: SwiftMindCore library + tests (swift-tools 5.10, macOS 14+)
Sources/SwiftMindCore/         # UI-free core library (the "brain")
  Model/                       #   MindMap, Node, NodeID, NodeStyle, NodeLink, NodeIcon, NodeAttribute, Bookmark, Point2D, NodeSide
  Commands/                    #   MapCommand protocol + CommandBus (undo/redo) + one file per command
  Store/                       #   MapStore (map + selection + revision counters + geometry cache), SelectionState, SpatialNavigator
  Layout/                      #   LayoutEngine, LayoutConfig, MapSnapshot (geometry-only snapshots)
  HTML/                        #   HTMLCodec (encode/decode), HTMLSkin (read-only browser CSS)
  Search/                      #   MapSearch (title/note substring matching)
  Filter/                      #   MapFilter (text / attr=value, hide vs highlight)
  Style/                       #   StyleSheet (named styles: topic, important, note) + ConditionalStyleRule
  Formula/                     #   L1 formula DSL: FormulaLexer, FormulaParser, FormulaAST,
                               #   FormulaEvaluator, FormulaValue, FormulaEngine (memoized)
  Automation/                  #   BulkAction (L2 declarative bulk edits)
  Scripting/                   #   L3: ScriptRuntime protocol, MapScriptAPI (intent recording),
                               #   JavaScriptCoreRuntime (sandboxed JS)
  Import/                      #   MMImport (best-effort Freeplane .mm → MindMap, one-way)
Sources/SwiftMindCLI/          # swiftmind CLI executable (agent interface to maps)
Tests/SwiftMindCoreTests/      # XCTest unit tests (~200) + Fixtures/ golden files
Apps/SwiftMindMac/             # The macOS app
  project.yml                  #   XcodeGen spec — regenerate project with `xcodegen generate`
  SwiftMindMac.xcodeproj/      #   Generated (gitignored pattern `*.xcodeproj/`); do not edit by hand
  SwiftMindMac/                #   SwiftUI app sources: SwiftMindMacApp, AppModel, DocumentSession,
                               #   SwiftMindFileDocument (FileDocument <-> HTMLCodec), MapCanvasView,
                               #   OutlineMapView, InspectorView, BrainMapBuilder, VaultLibrary,
                               #   AgentBridge (Unix-socket agent bridge for `swiftmind mcp`), etc.
  SwiftMindMacUITests/         #   XCUITest smoke tests
scripts/                       # Automation entry points (see below)
skills/swiftmind/SKILL.md      # agent driver's manual for the CLI
docs/superpowers/              # Design spec, milestone plans, agent workflow notes
```

Two build systems coexist on purpose:

- **SPM** builds and tests `SwiftMindCore` only (`swift build`, `swift test`).
- **XcodeGen + xcodebuild** builds the Mac app target, which depends on the SPM package via a local path reference (`packages: SwiftMind: path: ../../` in `project.yml`).

## Build and test commands

```bash
# Core unit tests (fast, always run these after core changes)
swift test

# Full loop after ANY app-affecting change: stop app → test → rebuild → relaunch
./scripts/rerun-mac.sh            # add --no-test to skip tests, --no-launch to skip launch

# CI-style gate: unit tests + CLI smoke + app build + XCUITest smoke
./scripts/verify.sh               # add --skip-ui to skip XCUITest

# UI tests only (requires a GUI session, not headless)
./scripts/test-ui.sh

# Open in Xcode (regenerates the project first)
cd Apps/SwiftMindMac && xcodegen generate && open SwiftMindMac.xcodeproj
```

Requirements: macOS, Xcode with `xcodebuild`, and **XcodeGen** (`brew install xcodegen`). Builds use `CODE_SIGN_IDENTITY=-` (ad-hoc) so no Apple Developer account is needed. UI tests need a logged-in GUI session.

**Agent rule (from `docs/superpowers/AGENT-WORKFLOW.md`):** after any code change that affects the Mac app, always run `./scripts/rerun-mac.sh` yourself — never ask the user to stop Xcode and re-run. Before claiming a feature "done", run `./scripts/verify.sh` (or at minimum `swift test && ./scripts/rerun-mac.sh --no-test`).

## Architecture rules — read before changing code

- **`SwiftMindCore` has zero UI dependencies.** Keep it free of SwiftUI/AppKit imports so it stays portable (iPad/iPhone are planned later).
- **All model mutations go through commands.** Every edit is a `MapCommand` (`execute`/`undo`) dispatched via `MapStore.dispatch(_:)`, which drives the `CommandBus` undo/redo stacks. Never mutate `MindMap` directly from views. Add a new file per command under `Sources/SwiftMindCore/Commands/`.
- **`MapStore` revision contract:** `contentRevision` bumps on any content change (invalidates the cached geometry snapshot); `selectionRevision` bumps on selection-only changes (geometry cache stays valid). Views consume `snapshot()` — a `MapSnapshot` with selection applied — and never own business truth.
- **HTML is the persistence format.** `HTMLCodec.encode(_:includeSkin:)` / `decode(_:)` are the only read/write paths; the app saves with `includeSkin: true` so the file renders read-only in browsers. The schema is versioned (`schemaVersion`, currently 1, additive). Round-trip fidelity is enforced by `HTMLCodecTests` against the golden fixture `Tests/SwiftMindCoreTests/Fixtures/minimal.swiftmind.html`.
- **Formulas are derived data.** `Node.formula` (source string) is the only persisted piece — `data-formula` on `<li>`, schema 1 additive. Computed values come from `FormulaEngine` inside `MapStore`, memoized against the node's subtree value; every DSL feature reads only that subtree, so cache validation is plain equality (sibling edits never invalidate). Never store computed values in the model, never evaluate formula text as real code, and keep `snapshot()` geometry-only — views merge formula results at render time.
- **Scripts never mutate the map directly.** L3 scripts (JavaScriptCore, behind the `ScriptRuntime` protocol) read value snapshots and record `ScriptIntent`s; `ApplyScriptIntentsCommand` applies a successful run as one undoable batch (errors/timeouts apply nothing). Do not add bridges beyond the `mindmap` API object — the sandbox guarantee is "no network/file/process access", asserted by tests. Scripts live app-side (user-picked `.js` files), never embedded in the HTML.
- **Single live session:** the app currently shares one `AppModel`/`DocumentSession` across all windows (`SwiftMindMacApp.swift`) — the agent bridge and all session-scoped features address that one session.
- **External map edits go through the CLI.** `swiftmind` (Sources/SwiftMindCLI) decodes, applies `MapOp`s via `BatchOps` (all-or-nothing, through the existing commands), and atomically rewrites the file — refusing to save (exit 2) if the file changed on disk between its read and write. The app watches the open document's parent directory and hot-reloads external changes; this clears the undo stack (spec §hot reload). Never hand-edit `.swiftmind.html` in automation.
- **Agent bridge (live edits).** `AgentBridge` in the app serves a Unix socket at `~/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind/agent.sock` (token file next to it, 0600, regenerated per launch). `swiftmind mcp` bridges stdio MCP to it; `applyOps` dispatches one `CompositeAgentCommand` = one undo step. Socket IO is hardened (MSG_NOSIGNAL, send/recv timeouts, 4 MB frame cap). No network entitlement. Kill switch: `defaults write app.swiftmind.mac swiftmind.agentBridge -bool false`.
- **Xcode gotcha:** `debugDocumentVersioning` must be `false` in the scheme. When true, Xcode injects `-NSDocumentRevisionsDebugMode YES` and `DocumentGroup` opens "YES" as a file path. `scripts/patch-xcode-scheme.sh` fixes this after every `xcodegen generate` (already wired into `rerun-mac.sh`); the app also defensively sets the default to false in `SwiftMindMacApp.init`.

## Code style guidelines

- Swift, `swift-tools-version: 5.10`, deployment target **macOS 14**. No external package dependencies — Foundation/SwiftUI only.
- Core model types are value types: `struct`, `Equatable`, `Sendable`, `Codable` (see `MindMap`, `Node`).
- Match existing file organization: one type/command per file, grouped in the folders above.
- No linter/formatter is configured; match the surrounding code (4-space indent, explicit `public` on core API).
- Comments are sparse and English; keep doc comments accurate when behavior changes.

## Testing instructions

- **Unit tests:** XCTest via SPM in `Tests/SwiftMindCoreTests/` — model, commands, layout engine, HTML codec, search, pins, plus `DailyDriverE2ETests` (in-process end-to-end through the store). Run with `swift test`. Add tests next to the existing ones; reuse the `Fixtures/` golden file for codec tests.
- **UI tests:** XCUITest in `Apps/SwiftMindMac/SwiftMindMacUITests/`; run with `./scripts/test-ui.sh`. Prefer accessibility identifiers and keyboard shortcuts over coordinates. Existing IDs include `mapCanvas`, `mapTitleField`, `viewModePicker`, `statusStrip`, `nodeCountLabel`, `selectedNodeLabel`, `toolbarAddChild`, `toolbarAddSibling`, `outlineList`, `formulaField`, `formulaResult`, `clearFormulaButton`, `aggregatePicker`, `formulaBadge`. The app detects `-uitesting` launch arg and disables state restoration.
- Verification before completion is not optional: run `swift test` for core changes and `./scripts/verify.sh` for anything touching the app.

## Security considerations

- App Sandbox is enabled (`SwiftMindMac.entitlements`) with **user-selected file read/write only** — no network entitlement, no iCloud container entitlements. Keep it that way: unsigned local builds must keep working without a development team or provisioning profile.
- Vault folders in "My Brain" are accessed via **security-scoped bookmarks** (`VaultLibrary`).
- Do not add iCloud ubiquity-container entitlements to the committed config — that path is documented in `README.md` as an optional, signed-only future step.
- The HTML codec escapes text/attributes on encode; preserve escaping when touching `HTMLCodec`. Control chars survive as character references (`\t`→`&#9;`, `\n`→`&#10;` in attributes, lone `\r`→`&#13;` everywhere). Known limitation: a `\r\n` pair still decodes as `\n` — Foundation's `XMLParser` normalizes line ends after character-reference expansion, so no encoding can preserve it.
