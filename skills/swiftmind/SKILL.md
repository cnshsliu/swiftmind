---
name: swiftmind
description: Operate SwiftMind mind maps (.swiftmind.html) via MCP (live app) or the swiftmind CLI (files). Use when the user asks to view, brainstorm into, reorganize, summarize, capture into, or otherwise modify a SwiftMind mind map.
---

# SwiftMind agent operations

A SwiftMind document is a **mind map** stored as plain HTML (`.swiftmind.html`). Nested `<ul>`/`<li>` is the model. **Never hand-edit the HTML.** Always go through MCP (live session) or the `swiftmind` CLI (files).

If `swiftmind` is not on PATH, check `~/.local/bin/swiftmind`; if missing, build it: `cd <repo> && ./scripts/install-cli.sh`.

**When the app is running, use MCP.** File-mode writes race the app autosave.

---

## MCP (live mind map) — preferred

`swiftmind mcp` is a stdio MCP server (JSON-RPC 2.0, protocol `2025-06-18`). It talks to the **running** app over a local Unix socket. No network.

Register:

```json
{"mcpServers": {"swiftmind": {"command": "swiftmind", "args": ["mcp"]}}}
```

Default socket is the **Release** container (`app.swiftmind.mac`). To drive **SwiftMind Dev**:

```bash
export SWIFTMIND_BRIDGE_DIR="$HOME/Library/Containers/app.swiftmind.mac.dev/Data/Library/SwiftMind"
```

Kill switch: Settings → Agent, or `defaults write app.swiftmind.mac swiftmind.agentBridge -bool false` (Dev domain: `app.swiftmind.mac.dev`).

If a tool says the app is not running, start SwiftMind or fall back to [file mode](#file-mode-cli). Never mix `apply_ops` / `capture` with file-mode writes on the same document.

### Tools

| Tool | Arguments | Returns |
|------|-----------|---------|
| `get_session` | none | `mapPath`, `title`, `selectedIds`, `canUndo`, `canRedo`, `isBrainMode` |
| `read_map` | none | JSON tree of the **open** mind map; formula nodes include computed `formulaResult` |
| `find_nodes` | `query` (string) | `{ "hits": [ { "id", "title", "matchInNote" } ] }` — substring, case-insensitive. Does **not** refuse ambiguous queries; if you need exactly one node, filter hits yourself or use file-mode `find --unique`. |
| `apply_ops` | `ops` (array of op objects, see [Op catalog](#op-catalog)) | `{ "affected": ["id", ...] }` — **all-or-nothing, one ⌘Z** |
| `new_map` | `title`? | `{ "path": "…" }` — creates in the default library and opens it |
| `doctor` | none | `{ "issues": [ { "kind", "id"?, "message" } ] }` — dangling node-links, orphans, empty titles, formula errors, stale bookmarks, duplicate ids |
| `capture` | `text` (required), `inbox`? (bool) | `{ "affected": ["id"], "inbox": false }` on the open mind map (child of root, one undo); `{ "inbox": true }` if My Brain is showing **or** `inbox: true` (appends to `Inbox.swiftmind.html`, does not switch documents) |

`apply_ops` is refused while My Brain is showing (`isBrainMode: true`). `read_map` / `find_nodes` / `doctor` still work on the navigator tree; do not treat that tree as a user mind map.

### Live recipes

**See what is open**

1. `get_session`
2. `read_map` if `isBrainMode` is false

**Add ideas under the current selection**

1. `get_session` → `selectedIds[0]` (else `read_map` and use `root.id`)
2. `apply_ops` with `add-child` ops, **your own** `id`s (`n_agent1`, …) if later ops refer to them

**Inbox thought (do not change the open mind map)**

- `capture` with `{ "text": "…", "inbox": true }`

**Health check**

- `doctor`; jump by `id` via `apply_ops` only if you intend to edit. Filtering in the UI is `orphan` / `dangling` — agents just read the JSON.

---

## File mode (CLI)

All commands: `swiftmind <cmd> <file>`. Success = JSON on stdout, exit 0. Write commands print `{"ok": true, "affected": ["<id>", ...]}`. Errors = `{"error":{"code","message"}}` on stderr, exit 1/2/3 (usage / file / operation).

`swiftmind --version` prints the CLI version.

- `read <file>` — JSON tree (`root` → nested `children`; each node: `id`, `text`, optional `note`, `attributes`, `formula`, `folded`, `noteExpanded`, `side`, `pinned`).
- `find <file> --query <text> [--unique]` — title/note search. `--unique` exits 3 unless exactly one node matches (exact title wins among substring hits; two exact titles still refuse).
- `doctor <file>` — same issue list as MCP `doctor`.
- `capture <file> --text <t>` — add a child under that file's root.
- `add-child <file> --parent <id> --text <t> [--side auto|left|right] [--id <newid>]`
- `add-sibling <file> --of <id> --text <t> [--id <newid>]`
- `set-text` / `set-note` / `set-attr` / `set-formula` / `fold` / `unfold` / `pin` / `unpin` / `move` / `delete` — see [Op catalog](#op-catalog) for JSON equivalents.
- `batch <file> [ops.json]` — ops array from file or stdin; **all-or-nothing**.
- `new <file> [--title <t>]` — create (fails if it exists).
- `validate <file>` — decode + re-encode check.

Always pass a value with each flag. Values that start with `--` cannot be flags — use `batch` JSON.

Write commands refuse to save if the file changed on disk between read and write (exit 2). Re-run on the fresh file.

---

## Op catalog

Used by MCP `apply_ops` and CLI `batch`. Key names differ from CLI flags (`sibling` not `--of`; `ids` is an array).

`id` is optional on `add-child` / `add-sibling` (generated if omitted). Pass your own ids when later ops in the same batch reference them.

Unknown `op`, missing fields, and invalid values (bad `side`, …) are usage errors. An apply-time failure reports `opIndex` and applies **nothing**.

| `op` | Fields | Notes |
|------|--------|--------|
| `add-child` | `parent`, `text`, `id`?, `side`? (`auto`\|`left`\|`right`, default `auto`) | |
| `add-sibling` | `sibling`, `text`, `id`? | |
| `set-text` | `id`, `text` | |
| `set-note` | `id`, `markdown` | |
| `set-attr` | `id`, `name`, `value`? | omit `value` or `""` removes the attribute |
| `set-formula` | `id`, `formula`? | empty/omit clears. DSL: `count(children)`, `sum(children, attr: "x")`, `avg\|min\|max(...)`, `progress()`, `attr("x")`, arithmetic, `if(...)` |
| `fold` / `unfold` | `id` | |
| `expand-note` / `collapse-note` | `id` | |
| `set-links` | `id`, `links` | array; see below. `[]` clears |
| `pin` | `id`, `x`, `y` | canvas coordinates |
| `unpin` | `id` | |
| `move` | `id`, `to`, `index`? | `index` default 0 |
| `delete` | `ids` (array) or `id` (string) | cannot delete the root |

```json
[
  {"op":"add-child","parent":"n_x","id":"n_new1","text":"Idea","side":"auto"},
  {"op":"add-sibling","sibling":"n_x","id":"n_new2","text":"Next"},
  {"op":"set-text","id":"n_new1","text":"Renamed"},
  {"op":"set-note","id":"n_new1","markdown":"A **note**"},
  {"op":"set-attr","id":"n_new1","name":"status","value":"todo"},
  {"op":"set-formula","id":"n_x","formula":"count(children)"},
  {"op":"fold","id":"n_x"},
  {"op":"unfold","id":"n_x"},
  {"op":"expand-note","id":"n_new1"},
  {"op":"pin","id":"n_new1","x":120,"y":-40},
  {"op":"unpin","id":"n_new1"},
  {"op":"move","id":"n_new2","to":"n_new1","index":0},
  {"op":"set-links","id":"n_new1","links":[
    {"url":{"_0":"https://example.com"}},
    {"node":{"_0":{"rawValue":"n_x"}}}
  ]},
  {"op":"delete","ids":["n_b"]}
]
```

`set-links` uses Swift's Codable shape for `NodeLink`: URL as `{"url":{"_0":"<absolute URL>"}}`, node as `{"node":{"_0":{"rawValue":"<id>"}}}`.

### Discipline

- Prefer one `apply_ops` / `batch` over many single commands.
- Never delete a node and its ancestor in the same batch — the ancestor delete already removes the descendant; a later descendant delete fails and rolls back everything.
- Do not write `.swiftmind.html` with anything but this CLI or MCP.

### File-mode recipes

**Expand a node:** `read` → draft 3–7 children → one `batch` of `add-child`.

**Summarize a branch:** `read` subtree → `set-note` on the parent.

**Restructure:** `read` → one `batch` of `move` (and `add-child` for new groups).
