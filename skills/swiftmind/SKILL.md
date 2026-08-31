---
name: swiftmind
description: Operate SwiftMind mind maps (.swiftmind.html) via the swiftmind CLI — read structure, add/move/delete nodes, set attributes and formulas, batch atomic edits. Use when the user asks to view, brainstorm into, reorganize, summarize, or otherwise modify a SwiftMind map file.
---

# SwiftMind map operations

SwiftMind maps are plain HTML files (`*.swiftmind.html`). **Always modify them
through the `swiftmind` CLI — never hand-edit the HTML.** The CLI validates
every operation and writes atomically; the user's running app hot-reloads the
change onto their canvas within a second.

If `swiftmind` is not on PATH, check `~/.local/bin/swiftmind`; if missing,
build it: `cd <repo> && ./scripts/install-cli.sh`.

## Commands

All commands: `swiftmind <cmd> <file>`. Success prints JSON on stdout, exit 0 —
write commands print `{"ok": true, "affected": ["<id>", ...]}` where `affected`
lists the ids touched, in op order. Errors print `{"error":{"code","message"}}`
on stderr, exit 1/2/3 (usage/file/operation).

`swiftmind --version` prints the CLI version.

- `read <file>` — full map as a JSON tree (`root` → nested `children`; each
  node: `id`, `text`, optional `note`, `attributes`, `formula`, `folded`,
  `side`, `pinned`).
- `find <file> --query <text>` — case-insensitive title/note search; returns
  matching nodes (`id`, `title`, `matchInNote`).
- `add-child <file> --parent <id> --text <t> [--side auto|left|right] [--id <newid>]`
- `add-sibling <file> --of <id> --text <t> [--id <newid>]`
- `set-text <file> --id <id> --text <t>`
- `set-note <file> --id <id> --markdown <md>`
- `set-attr <file> --id <id> --name <n> --value <v>` — `--value ""` removes the attribute.
- `set-formula <file> --id <id> --formula <f>` — `--formula ""` clears. DSL: `count(children)`,
  `sum(children, attr: "x")`, `avg|min|max(...)`, `progress()`, `attr("x")`, arithmetic/comparison/`if(...)`.
- `fold <file> --id <id>` / `unfold`
- `pin <file> --id <id> --x <n> --y <n>` / `unpin`
- `move <file> --id <id> --to <parentId> [--index <n>]`
- `delete <file> --ids <id,id,...>` — cannot delete the root.
- `batch <file> [ops.json]` — ops array from file or stdin; **all-or-nothing**.
- `validate <file>` — decode + re-encode check.

Always pass a value with each flag: a bare `--text` (or any required flag) is
rejected as a usage error. Values that start with `--` cannot be passed as
flags — use `batch` JSON instead for such text.

## The batch primitive (preferred for anything non-trivial)

One JSON array = one atomic change set. Op objects (note the key names differ
from CLI flags: `sibling`, not `--of`; `ids` is an array, not comma-separated):

```json
[
  {"op":"add-child","parent":"n_x","id":"n_new1","text":"Idea","side":"auto"},
  {"op":"add-sibling","sibling":"n_x","id":"n_new2","text":"Next"},
  {"op":"set-attr","id":"n_new1","name":"status","value":"todo"},
  {"op":"set-formula","id":"n_x","formula":"count(children)"},
  {"op":"move","id":"n_a","to":"n_new1","index":0},
  {"op":"delete","ids":["n_b"]}
]
```

`id` is optional on `add-child`/`add-sibling` (generated if omitted) — but pass
your own ids (`n_agent1`, …) when later ops in the same batch reference them.
Unknown op names, missing fields, and invalid values (e.g. a bad `side`) are
rejected up front as usage errors; an op that fails at apply time exits 3 with
the failing op's `opIndex` and leaves the file untouched. (`delete` also
accepts `"id": "<id>"` for a single node; omitting `value` on `set-attr`
removes the attribute.)

## Recipes

**Expand a node into sub-ideas:**
1. `swiftmind read <file>` — locate the target node id.
2. Think; draft 3–7 children.
3. Pipe a batch of `add-child` ops to `swiftmind batch <file>`.

**Summarize a branch:**
1. `read`, extract the subtree under the target node.
2. Write the summary into the parent: `set-note --id <id> --markdown "…"`.

**Restructure:**
1. `read`; plan the new shape.
2. One `batch` with `move` ops (and `add-child` for new grouping nodes).

## Discipline

- Prefer one `batch` over many single commands — atomicity + one reload.
- Write commands refuse to save if the file changed on disk between the CLI's
  read and write (exit 2, "file changed on disk while applying ops"). This
  means the app or another process saved concurrently — just re-run the
  command on the fresh file.
- Never delete a node and its ancestor in the same batch — the ancestor's
  delete already removes the descendant, and if the descendant delete happens
  to run second it fails and rolls back the whole batch.
- After writing, you may `validate` the file; the CLI already validates on
  every write, so this is optional.
- Do not write the file with anything but this CLI.
