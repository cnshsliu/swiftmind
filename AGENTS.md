# AGENTS.md — SwiftMind

Guidance for AI coding agents working in this repository. Assumes no prior knowledge of the project.

## Project overview

**SwiftMind** is a native **macOS mind-mapping app** written in pure Swift. Its defining trait: documents are **plain HTML files** with the extension `.swiftmind.html` — the map model is serialized as nested `<ul>`/`<li>` lists, so the same file opens as a **read-only hierarchy in any browser** without the app installed. Editing always happens in the native app (no WebView editor).

The architecture (from `docs/superpowers/specs/2026-07-24-swiftmind-design.md`):

> UI-free mind-map core (Swift Package) + native macOS shell; HTML is a codec; the canvas consumes layout snapshots and never owns business truth.

Feature state: milestones M0–M3 are implemented — outline + canvas views, auto layout with pin/free positions, fold, drag reparent, Markdown notes, URL/node links, icons, search (⌘F), command palette (⌘K), node attributes with a map-level registry, named styles, filters (hide/highlight), bookmarks, and multi-window support. See `README.md` for the full feature list and keyboard shortcuts.

## Repository layout

```
Package.swift                  # SPM manifest: SwiftMindCore library + tests (swift-tools 5.10, macOS 14+)
Sources/SwiftMindCore/         # UI-free core library (the "brain")
  Model/                       #   MindMap, Node, NodeID, NodeStyle, NodeLink, NodeIcon, NodeAttribute, Bookmark, Point2D, NodeSide
  Commands/                    #   MapCommand protocol + CommandBus (undo/redo) + one file per command
  Store/                       #   MapStore (map + selection + revision counters + geometry cache), SelectionState
  Layout/                      #   LayoutEngine, LayoutConfig, MapSnapshot (geometry-only snapshots)
  HTML/                        #   HTMLCodec (encode/decode), HTMLSkin (read-only browser CSS)
  Search/                      #   MapSearch (title/note substring matching)
  Filter/                      #   MapFilter (text / attr=value, hide vs highlight)
  Style/                       #   StyleSheet (named styles: topic, important, note)
Tests/SwiftMindCoreTests/      # XCTest unit tests (~54) + Fixtures/minimal.swiftmind.html golden file
Apps/SwiftMindMac/             # The macOS app
  project.yml                  #   XcodeGen spec — regenerate project with `xcodegen generate`
  SwiftMindMac.xcodeproj/      #   Generated (gitignored pattern `*.xcodeproj/`); do not edit by hand
  SwiftMindMac/                #   SwiftUI app sources: SwiftMindMacApp, AppModel, DocumentSession,
                               #   SwiftMindFileDocument (FileDocument <-> HTMLCodec), MapCanvasView,
                               #   OutlineMapView, InspectorView, BrainMapBuilder, VaultLibrary, etc.
  SwiftMindMacUITests/         #   XCUITest smoke tests
scripts/                       # Automation entry points (see below)
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

# CI-style gate: unit tests + app build + XCUITest smoke
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
- **Multi-window:** each document window owns its own `DocumentSession` and undo stack — do not introduce shared mutable state between sessions.
- **Xcode gotcha:** `debugDocumentVersioning` must be `false` in the scheme. When true, Xcode injects `-NSDocumentRevisionsDebugMode YES` and `DocumentGroup` opens "YES" as a file path. `scripts/patch-xcode-scheme.sh` fixes this after every `xcodegen generate` (already wired into `rerun-mac.sh`); the app also defensively sets the default to false in `SwiftMindMacApp.init`.

## Code style guidelines

- Swift, `swift-tools-version: 5.10`, deployment target **macOS 14**. No external package dependencies — Foundation/SwiftUI only.
- Core model types are value types: `struct`, `Equatable`, `Sendable`, `Codable` (see `MindMap`, `Node`).
- Match existing file organization: one type/command per file, grouped in the folders above.
- No linter/formatter is configured; match the surrounding code (4-space indent, explicit `public` on core API).
- Comments are sparse and English; keep doc comments accurate when behavior changes.

## Testing instructions

- **Unit tests:** XCTest via SPM in `Tests/SwiftMindCoreTests/` — model, commands, layout engine, HTML codec, search, pins, plus `DailyDriverE2ETests` (in-process end-to-end through the store). Run with `swift test`. Add tests next to the existing ones; reuse the `Fixtures/` golden file for codec tests.
- **UI tests:** XCUITest in `Apps/SwiftMindMac/SwiftMindMacUITests/`; run with `./scripts/test-ui.sh`. Prefer accessibility identifiers and keyboard shortcuts over coordinates. Existing IDs include `mapCanvas`, `mapTitleField`, `viewModePicker`, `statusStrip`, `nodeCountLabel`, `selectedNodeLabel`, `toolbarAddChild`, `toolbarAddSibling`, `outlineList`. The app detects `-uitesting` launch arg and disables state restoration.
- Verification before completion is not optional: run `swift test` for core changes and `./scripts/verify.sh` for anything touching the app.

## Security considerations

- App Sandbox is enabled (`SwiftMindMac.entitlements`) with **user-selected file read/write only** — no network entitlement, no iCloud container entitlements. Keep it that way: unsigned local builds must keep working without a development team or provisioning profile.
- Vault folders in "My Brain" are accessed via **security-scoped bookmarks** (`VaultLibrary`).
- Do not add iCloud ubiquity-container entitlements to the committed config — that path is documented in `README.md` as an optional, signed-only future step.
- The HTML codec escapes text/attributes on encode; preserve escaping when touching `HTMLCodec`.
