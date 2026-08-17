# SwiftMind

Native **macOS** mind mapping in pure Swift. Documents are plain HTML files with the extension **`.swiftmind.html`**: the app reads and writes the map model as nested lists, and the same file opens as a **read-only hierarchy** in any browser (Safari, Chrome, etc.) without SwiftMind installed.

Architecture: **SwiftMindCore** (model, commands, layout, HTML codec) + **SwiftMindMac** (WindowGroup shell, My Brain vaults, outline, canvas, inspector).

### Startup & My Brain

- **No Open panel** on launch: reopens the **last map**, or creates `~/Documents/SwiftMind/Untitled.swiftmind.html` and opens it.
- **My Brain** (toolbar / **⇧⌘B**): mind-map navigator whose root is **My Brain**; **vault folders** you add are first-level children; **subfolders** and **`.swiftmind.html` / `.html` maps** nest underneath.
- Double-click (or Return) a **map** node to open it; double-click a **folder/vault** to fold/unfold. **Add Vault…** registers more folders (security-scoped bookmarks).
- Autosave writes the current map file while editing.

## Develop

```bash
# Core package unit tests
swift test

# Kill running app → test → rebuild → relaunch (preferred after code changes)
./scripts/rerun-mac.sh

# Tests + build only (no launch)
./scripts/verify.sh

# Open in Xcode (optional)
cd Apps/SwiftMindMac && xcodegen generate && open SwiftMindMac.xcodeproj
```

| Script | What it does |
|--------|----------------|
| `scripts/rerun-mac.sh` | Stop SwiftMind, `swift test`, rebuild, `open` the new `.app` |
| `scripts/rerun-mac.sh --no-test` | Faster rebuild+relaunch |
| `scripts/verify.sh` | Automated CI-style gate: tests + build |

**Agents / automation:** after UI or app changes, always run `./scripts/rerun-mac.sh` so you never need to manually stop Xcode Run and click the triangle again.

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

## M3 features (power layer)

- **Attributes** on nodes (`name`/`value` strings) with map-level **attribute registry**
- **Named styles** (`topic`, `important`, `note`) via style sheet + local style overrides
- **Filters**: text / `name=value` attribute filter; **Hide** (path-to-root) or **Highlight**
- **Bookmarks** sidebar + palette actions; jump selects and unfolds ancestors
- HTML schema **1** additive: `node-attrs`, `attribute-registry`, `bookmarks`, `data-style-name`, filter attrs on `<article>`

### How to use attributes

1. Select a node → inspector **Attributes**.
2. Enter name/value → **Add** (names auto-register on the map).
3. Filter with `status=done` in the sidebar filter field.

### How to use filters

1. Sidebar **Filter** field: substring of title/note, or `attr=value`.
2. Toggle **Hide** vs **Highlight**; clear with ✕.
3. Status shows visible/highlighted counts; map status strip shows `visible/total`.

### How to use bookmarks

1. Select a node → bookmark button in sidebar, or palette **Bookmark Selection**.
2. Click a bookmark to jump; ✕ removes it.

### How to use named styles

1. Inspector **Named Style** picker, or palette **Apply Style: …**.
2. Local Style section still overrides non-default fields (font size, colors, fill).

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
