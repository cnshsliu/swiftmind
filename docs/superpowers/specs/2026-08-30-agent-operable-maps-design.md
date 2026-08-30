# Agent-Operable Maps — Design Spec

Date: 2026-08-30
Status: Approved (design), pending implementation plan

## Vision

Make SwiftMind a mind-mapping tool fit for the AGI era: **a map that external
agents can genuinely operate, in an open format, running entirely on the user's
own machine.**

Three layers of ambition, decided during brainstorming:

- **A (co-thinker features)** — expand a node, summarize a branch, restructure
  a messy subtree. Delivered *through* external agents; the app itself never
  embeds a model call.
- **B (the map as the agent's workspace)** — the core bet. External agent
  frameworks (Claude Code and anything that can run shell commands) read and
  modify maps through a first-class machine interface.
- **C (knowledge substrate)** — the `.swiftmind.html` format stays the open,
  portable source of truth; agents get a documented, validated way to work with
  it.

## Key decisions (from brainstorming)

1. **The app keeps zero network entitlement.** All intelligence comes from
   external agent frameworks. This preserves the current security posture
   (App Sandbox, user-selected files only) and the product's differentiator.
2. **CLI-first transport, not an in-app server.** A localhost MCP/HTTP server
   was evaluated and deferred: it requires the network entitlement, per-launch
   auth tokens, DNS-rebinding/Origin defenses, and signed+notarized builds to
   avoid repeated firewall prompts (ad-hoc builds get re-prompted). XPC is not
   viable for arbitrary external processes from a sandboxed app. The same
   operation layer is needed either way, so it is built first, headless.
3. **A `SKILL.md` ships in the repo** (`skills/swiftmind/SKILL.md`) teaching
   agent frameworks how to drive the CLI — the "driver's manual" for agents.
4. **v2 (out of scope here):** an optional signed release build may embed a
   localhost MCP server that reuses the same operation layer against the live
   session, restoring real-time canvas updates and undo chains for agent edits.

## Architecture

```
┌─ SwiftMindCore (SPM lib, existing) ────────────────┐
│  HTMLCodec · Commands · BatchOps (new)             │  operation primitives:
└──────┬───────────────────────┬─────────────────────┘  validated, batched,
       │                       │                         all-or-nothing
┌──────┴──────────┐   ┌────────┴─────────────────┐
│ SwiftMindCLI     │   │ SwiftMindMac.app          │
│ (new SPM exe)    │   │  + MapFileWatcher (new)   │
│ read/add/move/…  │   │  hot-reloads external     │
└──────┬──────────┘   │  changes                  │
       │ atomic write  └────────▲─────────────────┘
       │ of .swiftmind.html     │ watches file
┌──────┴──────────┐             │
│ external agent   │────────────┘
│ framework        │
└─────────────────┘
```

### Components

- **`Sources/SwiftMindCore/Automation/BatchOps.swift` (new)** — `MapOp`
  (addChild, addSibling, setText, setNote, setAttribute, setFormula,
  setFolded, setPin, move, delete) plus a runner that applies an array of ops
  through the existing `MapCommand` types: validate all, then apply all; any
  failure leaves the map untouched. Lives in core so it is unit-testable
  headless and reusable by the v2 MCP server.
- **`Sources/SwiftMindCLI/` (new SPM executable target, product `swiftmind`)**
  — hand-rolled argument parsing (project has zero third-party dependencies;
  keep it that way), JSON I/O, exit codes.
- **`MapFileWatcher` (app side)** — watches the open document's parent
  directory and triggers hot reload.
- **`skills/swiftmind/SKILL.md`** — install instructions, per-subcommand
  contract, recipe workflows.
- **`scripts/install-cli.sh`** — `swift build -c release` and copy to
  `~/.local/bin/swiftmind` (no sudo).

## CLI surface (v1)

All commands: `swiftmind <cmd> <file> [options]`. Success prints JSON to
stdout and exits 0. Exit codes: 0 ok, 1 usage error, 2 file error,
3 operation error.

- **Read:** `read` (full JSON tree: id, text, note, attributes, formula,
  folded, side, children), `find --query <text>` (title/note substring match,
  returns node id list).
- **Write:** `add-child --parent <id> --text <t> [--side auto|left|right]`,
  `add-sibling --of <id> --text <t>`, `set-text --id --text`,
  `set-note --id --markdown`, `set-attr --id --name --value` (empty value
  removes), `set-formula --id --formula` (empty clears), `fold --id` /
  `unfold --id`, `pin --id --x --y` / `unpin --id`,
  `move --id --to <parentId> [--index n]`, `delete --id…`.
- **Batch:** `batch < ops.json` — a JSON array of op objects
  (`{"op": "add-child", "parent": "h_1", "text": "…"}`). The key agent
  primitive: one "thought" = one atomic set of changes. Every single-write
  command internally runs through the batch path so behavior is identical.
- **Guardrail:** `validate` — decodes and re-encodes, reporting any schema
  problems; agents use it to check their work.

Data flow for a mutation: decode file → apply via existing `MapCommand`s
(inherits all validation) → encode with `includeSkin: true` → write temp file
in the same directory → atomic rename → stdout JSON with affected node ids.

## Hot reload and conflicts (app side)

- Watch the **parent directory** with
  `DispatchSource.makeFileSystemObjectSource` (atomic rename replaces the
  inode, so watching the file itself silently dies), filter events for the
  open document path, debounce ~150ms.
- **Self-write suppression:** the app marks its own saves (flag + timestamp)
  and skips reloads triggered by them.
- **Reload semantics:** disk wins. External change → decode →
  `store.replaceMap`. Accepted cost for v1: **undo history is cleared** on
  external reload (existing `replaceMap` behavior), surfaced via a toast
  ("Updated by external agent"). v2's live-session path restores undo chains.
- **Selection preservation:** if the previously selected node id still exists
  after reload, keep it selected (follow mode then re-centers smoothly);
  otherwise clear the selection.
- **Conflict window:** autosave debounce is 400ms; an agent write landing in
  that window overwrites the unsaved in-memory edit. Accepted for v1 (window
  is tiny, toast keeps the user informed).
- **Brain mode:** no document open, nothing is watched.

## Error handling

Agents are machine users, so errors are machine-readable: failures print
`{"error": {"code": "node_not_found", "message": "…", "node": "h_7"}}` to
stderr and exit non-zero. In batch mode the error includes the failing op's
index and the file is left byte-identical (all-or-nothing).

## SKILL.md contents

`skills/swiftmind/SKILL.md`: install (`./scripts/install-cli.sh`), the
subcommand contract, and three recipe workflows — expand a node (read → think
→ batch-insert a subtree), summarize a branch (read subtree → write summary
into the parent's note), restructure (move/batch). Explicit discipline for
agents: **always write through the CLI, never hand-edit the HTML** (schema
authoring by hand is error-prone; the CLI validates).

## Testing

- Core: `BatchOpsTests` — every op type, batch atomicity (mid-batch failure
  rolls back everything), validation error paths.
- CLI: `scripts/test-cli.sh` smoke script — creates a temp map, then
  read → add-child → batch → find → delete, asserting JSON output and file
  contents.
- App: reload decision logic (self-write suppression, selection preservation)
  unit-tested if factored as pure functions; no XCUITest for file watching
  (too timing-fragile) — manual verification plus `verify.sh`.
- Gate: `swift test` and `scripts/rerun-mac.sh` green before claiming done.

## Out of scope (v1)

- In-app MCP/HTTP server, live-session agent edits, per-agent undo steps (v2).
- Built-in LLM calls of any kind.
- Real-time multi-agent collaboration, file-level locking beyond atomic rename.
