# SwiftMind

Native **macOS** mind mapping in pure Swift. Documents are plain HTML files with the extension **`.swiftmind.html`**: the app reads and writes the map model as nested lists, and the same file opens as a **read-only hierarchy** in any browser (Safari, Chrome, etc.) without SwiftMind installed.

Architecture: **SwiftMindCore** (model, commands, layout, HTML codec) + **SwiftMindMac** (DocumentGroup shell, outline, canvas, inspector).

## Develop

```bash
# Core package unit tests
swift test

# macOS app (requires Xcode + xcodegen)
cd Apps/SwiftMindMac && xcodegen generate
open SwiftMindMac.xcodeproj
```

Build the app from the command line:

```bash
cd Apps/SwiftMindMac
xcodegen generate
xcodebuild -scheme SwiftMindMac -destination 'platform=macOS' build
```

## M1 features

- **Outline** and **map canvas** views sharing selection and the same `MapStore`
- **Auto layout** (root, left/right sides) with pan/zoom and select on canvas
- **Fold** / unfold branches (hidden children on canvas when folded)
- **Reparent** and reorder via drag
- **Basic whole-node styles** (font size, bold, text/fill color) via inspector
- **HTML save/load** (`.swiftmind.html`) with **read-only browser skin** CSS on save

## Browser open (verify skin)

1. Create or open a map in SwiftMindMac and save (document encode uses `includeSkin: true`).
2. Double-click the `.swiftmind.html` file, or open it in Safari/Chrome.
3. Expect a nested indented list of node titles; no app install required.

A committed golden file is available for a quick check without launching the app:

```bash
open Tests/SwiftMindCoreTests/Fixtures/minimal.swiftmind.html
# or: open -a Safari Tests/SwiftMindCoreTests/Fixtures/minimal.swiftmind.html
```

Unit coverage: `HTMLCodecTests` decodes that fixture and asserts encode-with-skin embeds the CSS.

## Out of scope (later milestones)

Not in M0/M1 — planned for M2+ (daily driver / power layer):

- Markdown notes, URL/node links, icons/tags
- Search, Command Palette, pin/free positions
- Style sheets, attributes, filters, formulas, scripts
- Freeplane `.mm` import, iCloud, iPad/iPhone clients
- In-browser editing (native app remains the editor)
