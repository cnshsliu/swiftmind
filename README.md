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
- **Spatial navigation** (arrows or hjkl): `j`/`k` next/previous sibling; `h`/`l` follow the branch — on a **left**-side branch `h` goes outward to children and `l` to the parent, on a **right**-side branch reversed. From the root, `h`/`l` pick the left/right branch. Outward moves remember the last focused child; a folded node unfolds first.
- **Follow mode** (`f` on the canvas): the active node is always panned to the viewport center as you navigate; press `f` again to restore free panning
- **Focus clearing**: Esc or clicking blank canvas removes the current focus; with no focus, Delete removes the node under the pointer. Deleting a focused node moves focus to its next sibling (then previous, then parent)
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
- **Conditional styles**: map-level rules `hasIcon(x)` / `attr=value` → apply named style, layered after the named style (local fields still win)
- HTML schema **1** additive: `node-attrs`, `attribute-registry`, `bookmarks`, `style-rules`, `data-style-name`, filter attrs on `<article>`

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

### How to use conditional styles

1. Inspector **Style Rules** (map-level, always visible at the bottom).
2. Pick **Has Icon** or **Attribute** (`name` + `value`), choose a named style, **Add Rule**.
3. Matching nodes layer that style over their named style automatically; local style fields still win.

### Multi-window check

Open two maps (or the same file in two windows if the system allows). Edits and **Undo** in one window should not rewrite the other session’s history.

## M4 features (computation)

- **L1 formulas** on nodes: a safe, restricted expression DSL — no arbitrary code, ever
- **L0 aggregates** as one-click formulas: **Sum of attribute**, **Count children**, **Progress %**
- Results are **derived data**: they never modify the map, recompute live as children/attributes change, and undo cleanly
- Errors are values: a broken formula shows `#ERR: reason` inline — nothing crashes, nothing goes stale
- HTML schema stays **1** (additive): `data-formula="…"` on `<li>` stores the source string only; the browser skin never executes it

### Formula DSL reference

```text
attr("cost")                          node attribute ("42" → number, "true" → bool, else string)
sum|avg|min|max(children, attr: "cost")   roll up over direct children (missing attr skipped)
count(children)                       number of direct children
progress()                            checked descendants / total descendants (check icon = done)
1 + 2 * 3   ( )   -x   %              arithmetic with usual precedence
== != < <= > >=                       comparison (numeric or string)
and  or  not                          boolean
if(cond, then, else)                  lazy — only the taken branch evaluates
```

### How to use formulas

1. Select a node → inspector **Formula**.
2. Type a formula (e.g. `sum(children, attr: "cost")`) or use **Insert Aggregate** for one-click Sum/Count/Progress.
3. The live result shows below the field; badges (`= 30`, `75%`) appear on the canvas node and in the outline.
4. **Clear Formula** removes it; everything is undoable.

## M5 features (automation)

- **L2 bulk actions**: apply a declarative action (icon, style, attribute) to every node matching the active filter — one undo step
- **L3 scripts**: sandboxed **JavaScript** (JavaScriptCore) run against the current map from the command palette
- Scripts **never mutate the map directly**: the `mindmap` API records *intents*, applied as one undoable batch only if the script finishes cleanly. Errors and 2s timeouts change nothing.
- No network/file/process access exists inside the sandbox (no `require`, `fetch`, or `process` — tested)

### How to use bulk actions (L2)

1. Set a filter in the sidebar (text or `attr=value`).
2. **Apply to Matches…** → add/remove icon, apply/clear style, set/remove attribute.
3. Toast reports the affected count; ⌘Z undoes the whole batch.

### How to run a script (L3)

1. Write a `.js` file using the `mindmap` API below (see `docs/examples/check-off-todos.js`).
2. Palette (⌘K) → **Run Script…** → pick the file.
3. Toast reports applied changes (or the error). ⌘Z undoes everything the script did.

### JS API reference (the `mindmap` global)

```js
mindmap.title()                  // map title
mindmap.rootId()                 // root node id
mindmap.node(id)                 // { id, text, note, attrs: {...}, icons: [...] } or null
mindmap.children(id)             // [childId, ...]
mindmap.find(text)               // [nodeId, ...] — title/note substring, case-insensitive
mindmap.setText(id, text)        // ── intents: recorded, applied after success,
mindmap.setNote(id, markdown)    //    as one undo step ──
mindmap.setAttr(id, name, value) // value "" removes the attribute
mindmap.addIcon(id, iconId)      // icon ids: check, flag, star, warning, idea, question, important, todo
mindmap.removeIcon(id, iconId)
mindmap.setStyle(id, styleName)  // "" clears; named styles: topic, important, note
mindmap.log(message)             // surfaced in the result toast
```

### Freeplane `.mm` import (best-effort)

1. **Open Map…** panel accepts `.mm` files.
2. The map is imported (text, hierarchy, fold state, plain-text notes) and saved as a sibling `Name.swiftmind.html` — the original `.mm` is never modified.
3. Icons, styles, links, and rich formatting are dropped by design; import is a migration path, one-way.

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

Not in M0–M5 — planned for later (clients / deeper automation):

- iPad/iPhone clients (shared Core is ready; needs product decisions first)
- Script capabilities beyond map read + intents (none exist to gate today)
- In-browser editing (native app remains the editor)
- Forced iCloud ubiquity container (optional; see above)
