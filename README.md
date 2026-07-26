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

Build the app from the command line (unsigned local build):

```bash
cd Apps/SwiftMindMac
xcodegen generate
xcodebuild -scheme SwiftMindMac -destination 'platform=macOS' CODE_SIGN_IDENTITY=- build
```

## M1 features

- **Outline** and **map canvas** views sharing selection and the same `MapStore`
- **Auto layout** (root, left/right sides) with pan/zoom and select on canvas
- **Fold** / unfold branches (hidden children on canvas when folded)
- **Reparent** and reorder via drag
- **Basic whole-node styles** (font size, bold, text/fill color) via inspector
- **HTML save/load** (`.swiftmind.html`) with **read-only browser skin** CSS on save

## Visual polish

- Theme-aware canvas (dark/light), cubic edges, system **Accent** root node
- Drop target = accent, pin = orange (semantic split)
- Slim toolbar; status toast for delete/errors; single status selection strip
- Map title / inspector title commit on blur (not per-keystroke undo spam)
- Empty-map coach: `⌘T` / double-click / `⌘K`
- HTML share skin: `prefers-color-scheme: light dark`
- E2E: `DailyDriverE2ETests`

## M2 features (daily driver)

- **Markdown notes** on nodes (inspector note editor + apply; canvas note badge)
- **URL and node links** (add/remove in inspector; open URL from the link list)
- **Icons/tags** from a small built-in catalog; shown on the canvas
- **Search** (⌘F): sidebar field matches node **titles** and **notes**; select a hit to jump
- **Pin / unpin** (⇧⌘P or toolbar): pin freezes layout position; Option+drag moves a pin; unpin restores auto layout
- **Command Palette** (⌘K): filterable actions (Add Child/Sibling, Delete, Fold, Pin/Unpin, Undo, Redo) and **jump to node**
- **Map title** editable in the sidebar (undoable via `SetMapTitleCommand`)
- **Multi-window**: each document window owns its own `DocumentSession` / undo stack

### How to use notes

1. Select a node.
2. Open the inspector (toolbar sidebar button).
3. Edit **Note** (Markdown), then **Apply Note**.
4. Save the document; reopen or open the HTML in a browser — structure and note data round-trip in the file.

### How to use search

1. Press **⌘F** or click the search toolbar button to focus the sidebar search field.
2. Type a substring of a title or note.
3. Click a hit (or press Return for the first) to select that node.

### How to use the command palette

1. Press **⌘K**, use **View → Command Palette…**, or the toolbar command button.
2. Type to filter actions (e.g. `child`, `undo`, `pin`) or node titles.
3. **↑/↓** move the selection; **Return** runs it; **Escape** dismisses.
4. With an empty query, actions plus a flatten of the first nodes are listed for quick jump.

### How to use pin

1. Select a node and choose **Pin** (⇧⌘P, toolbar, or palette).
2. On the map canvas, **Option+drag** a node to place/move a pin.
3. **Unpin** clears the free position so auto layout owns it again.

### Canvas gestures (polish)

| Gesture | Action |
|---------|--------|
| Drag **empty** / **root** | Pan |
| **Space+drag** or **⌘+drag** | Pan (even over a node) |
| Drag **non-root node** onto another | Reparent (ghost + orange target) |
| **Option+drag** node | Pin at release point |
| Pinch | Zoom |
| Double-click node | Rename |
| Click node | Select |

### Multi-window check

Open two maps (or the same file in two windows if the system allows). Edits and **Undo** in one window should not rewrite the other session’s history.

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

## iCloud (optional)

SwiftMind uses the standard macOS **Document** model with App Sandbox and **user-selected file** read/write only. There are **no** committed iCloud container entitlements, so local builds with `CODE_SIGN_IDENTITY=-` keep working without a development team or provisioning profile.

**Use iCloud Drive today:** choose **File → Save** / **Save As…** and pick a folder under **iCloud Drive** in the save panel. The file is a normal `.swiftmind.html` document; iCloud sync is handled by the system folder, not a private ubiquity container.

**Optional future app container** (not enabled by default — requires Apple Developer team + capabilities):

```xml
<!-- Do not add these for unsigned local builds; they need a provisioning profile. -->
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.app.swiftmind.mac</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.app.swiftmind.mac</string>
</array>
```

In `Apps/SwiftMindMac/project.yml`, set `DEVELOPMENT_TEAM` when enabling signed iCloud capabilities.

## Out of scope (later milestones)

Not in M0–M2 — planned for later (power layer / clients):

- Style sheets, attributes registry, filters, formulas, scripts
- Freeplane `.mm` import
- iPad/iPhone clients
- In-browser editing (native app remains the editor)
- Forced iCloud ubiquity container (optional; see above)
