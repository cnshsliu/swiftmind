# Agent workflow (SwiftMind)

## After any code change that affects the Mac app

**Do not ask the user to stop Xcode and re-run.** Always:

```bash
./scripts/rerun-mac.sh
```

After substantive features / before claiming "done":

```bash
./scripts/verify.sh          # unit + build + XCUITest
# or faster core-only:
swift test && ./scripts/rerun-mac.sh --no-test
```

## Automated testing stack

| Layer | Tool | Command | Coverage |
|-------|------|---------|----------|
| Domain / layout / HTML | **XCTest** via SPM | `swift test` | Model, commands, layout, codec, search (~40) |
| Compile | **xcodebuild** | `./scripts/rerun-mac.sh --no-launch` | Mac target builds |
| UI smoke | **XCUITest** (Xcode) | `./scripts/test-ui.sh` | Launch, new doc, ⌘T, ⇧⌘T, ⌘K, outline switch |
| Full gate | all of above | `./scripts/verify.sh` | CI-style |

### Why XCUITest (not Maestro / Appium first)

- Built into Xcode — zero extra install for macOS native apps  
- Talks Accessibility API (same as VoiceOver)  
- Official for App Store–style Mac apps  
- Maestro/Appium are weaker or heavier for pure SwiftUI Document apps  

We can add **SnapshotTesting** later for pure-SwiftUI chrome snapshots; canvas is custom `Canvas` so logic tests + XCUITest matter more.

## Accessibility IDs (for UI tests)

| ID | Control |
|----|---------|
| `mapCanvas` | Mind map canvas |
| `mapTitleField` | Sidebar map title |
| `viewModePicker` | Map / Outline |
| `statusStrip` / `nodeCountLabel` / `selectedNodeLabel` | Status |
| `toolbarAddChild` / `toolbarAddSibling` / … | Toolbar |
| `outlineList` | Outline |

## Expanding UI tests

Add cases under `Apps/SwiftMindMac/SwiftMindMacUITests/`. Prefer keyboard shortcuts and identifiers over brittle coordinates.
