# Agent Live Bridge (v2) — Design

Date: 2026-09-03
Status: approved approach (UDS + stdio bridge), pre-implementation
Supersedes: the "signed release + localhost TCP MCP" note in
`2026-08-30-agent-operable-maps-design.md` §decisions — superseded because a
Unix-domain-socket bridge needs **no network entitlement and no signing**,
works in ad-hoc debug builds, and is immune to DNS rebinding by construction.

## Goal

Let an external agent operate the **live** app session — not just the file —
with synchronous acknowledgments, undoable edits, formula results, and session
introspection. Addresses the v2 requirements collected in
`2026-08-30-agent-operable-maps-design.md` §v2-requirements.

Non-goals: built-in LLM calls; multi-agent concurrency control; remote access
(anything beyond the local machine); a full MCP spec implementation.

## Architecture

```
agent framework (Claude Code / Kimi / Codex)
      │  stdio, MCP protocol (newline-delimited JSON-RPC 2.0)
      ▼
swiftmind mcp                    ← CLI target gains an `mcp` subcommand
      │  Unix domain socket, length-prefixed JSON frames
      ▼
SwiftMind.app → AgentBridge      ← new app-side component
      │  @MainActor, through DocumentSession / MapStore
      ▼
CompositeAgentCommand            ← one undo step per apply_ops call
```

Two processes, one socket. The CLI stays the only piece an agent framework
launches (stdio MCP is the native integration of every major framework); the
app never opens a network port.

## Components

### 1. Core: shared command construction + composite undo

- Refactor `BatchOps.applyOne` so the `MapOp → MapCommand` mapping is exposed
  as `MapOp.command(in: MindMap) throws -> any MapCommand`. The map parameter
  is needed for lookups (e.g. `setAttribute` with empty value reads current
  attributes to build `SetAttributesCommand`). The file-path CLI keeps using
  `BatchOps.apply` (all-or-nothing on a copy); the app path uses the commands
  individually. No behavior change for v1.
- New `CompositeAgentCommand(ops: [MapOp])` in `Sources/SwiftMindCore/Commands/`:
  - `execute`: builds each op's command via `command(in:)` and executes in
    order, keeping the executed list; on first failure it undoes the
    already-executed commands in reverse and rethrows — the map ends up
    untouched, giving the same all-or-nothing guarantee as `BatchOps.apply`.
  - `undo`: undoes executed commands in reverse order.
  - `name`: `"AgentEdit"`; the app toast shows "Agent edit (N ops) · ⌘Z".
- Precedent: `ApplyScriptIntentsCommand` already batches script intents as
  one undo step — same pattern, different source.

### 2. App: `AgentBridge` (new file `Apps/SwiftMindMac/SwiftMindMac/AgentBridge.swift`)

- Raw POSIX Unix-domain socket (Darwin `socket`/`bind`/`listen`, a reader
  `DispatchQueue`, frames = UInt32-BE length + UTF-8 JSON). Network.framework
  has no public UDS listener API that fits; POSIX keeps us dependency-free.
- Socket location (inside the sandbox container, writable under the existing
  entitlements): `~/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind/agent.sock`
  — deliberately NOT `Library/Application Support/...`: with a long username
  that path exceeds the 104-byte `sockaddr_un.sun_path` limit. If `bind`
  fails with `ENAMETOOLONG`, the bridge logs and disables itself.
  Directory created `0700`; token file `agent.token` next to it, `0600`,
  contents = a UUID generated fresh at every app launch.
- Stale socket is unlinked before `bind`. `stop()` on app terminate.
- Always on in local builds; kill switch via
  `defaults write app.swiftmind.mac swiftmind.agentBridge -bool false`
  (checked at launch; not a UI setting in v2).
- Request: `{"token": "...", "id": 1, "method": "...", "params": {...}}`.
  Response: `{"id": 1, "ok": true, "result": ...}` or
  `{"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}`.
  Wrong/missing token → `{"code": "unauthorized"}` and the connection is
  dropped. Error codes reuse the CLI taxonomy: `usage` / `file_error` /
  `op_error` / `unauthorized` / `no_session`.
- Socket I/O happens off-main; every method executes on the main actor
  against `AppModel`/`DocumentSession`.

### 3. Bridge methods (the live equivalent of the file CLI)

| method | params | result | notes |
|---|---|---|---|
| `read` | — | map JSON tree (same shape as CLI `read`) plus `formulaResult` per formula node | live mode merges computed values — dogfooding finding #2 |
| `find` | `query` | same as CLI `find` | |
| `applyOps` | `ops: [MapOp JSON]` | `{affected: [...]}` | one `CompositeAgentCommand` → one undo step; the command's own rollback keeps the map untouched on failure; autosave fires via the existing `onContentChanged`; watcher self-write suppression already handles the save |
| `session` | — | `{mapPath, title, selectedIds, canUndo, canRedo, isBrainMode}` | dogfooding finding #4; `isBrainMode: true` → mutations rejected with `no_session` |
| `new` | `title?` | `{path}` | creates a map in the default library and opens it — dogfooding finding #1 |

All-or-nothing on `applyOps` comes from `CompositeAgentCommand.execute`
itself (rollback-in-reverse on failure, then rethrow), so `store.dispatch`
only ever sees commands that fully succeed.

### 4. CLI: `swiftmind mcp`

Minimal MCP server on stdio (newline-delimited JSON-RPC 2.0):

- Handles `initialize` (reports `protocolVersion: "2025-06-18"`,
  `capabilities.tools`, `serverInfo: {name: "swiftmind", version: <cli>}`),
  `notifications/initialized` (ignored), `ping`, `tools/list`, `tools/call`.
  Everything else → JSON-RPC `-32601` method not found.
- Tools (1:1 to bridge methods, MCP `inputSchema` included):
  `read_map`, `find_nodes`, `apply_ops`, `get_session`, `new_map`.
- Tool results are MCP content blocks: `[{type: "text", text: <JSON>)}]`.
  Bridge errors → MCP `isError: true` results (not protocol errors), so the
  agent sees the structured message.
- Each `tools/call` opens a short-lived UDS connection, sends one frame,
  reads one frame, closes. No connection pooling in v2 — agent call rates
  don't need it, and it removes all reconnect state.
- App not running / socket missing → `isError` result
  "SwiftMind.app is not running (start it, or use the file-mode CLI)".
  File-mode CLI remains the fallback and is untouched.

### 5. CLI: `swiftmind new <file> [--title <t>]` (file mode)

Creates an empty map file (`HTMLCodec.encode(..., includeSkin: true)`),
failing if the file exists. Independent of the bridge — useful for headless
agent flows too. Bumps the CLI to 1.2.0.

## Data flow: one `apply_ops` call

1. Agent framework writes a `tools/call` line to `swiftmind mcp` stdin.
2. CLI reads `agent.token`, connects to `agent.sock`, sends the request.
3. App validates token, dispatches `CompositeAgentCommand` (its execute-time
   rollback keeps the batch all-or-nothing) → store revision bumps →
   `onContentChanged` schedules autosave (400 ms) → canvas re-renders.
4. App writes the response frame; CLI wraps it as an MCP tool result.
5. The user's ⌘Z undoes the entire agent batch as one step.

The v1 file path (CLI → file → watcher → reload) stays exactly as is for
agents that only have the file.

## Error handling

- Token mismatch: `unauthorized`, connection dropped, no retry guidance.
- Socket missing / connect refused: CLI-side `isError` "app not running".
- Op failure: `op_error` with `opIndex`/`op` (same payload as the file CLI);
  map untouched.
- Brain mode / no open map: `no_session` for mutating calls.
- Malformed frame or oversized message (> 4 MB): drop connection. Agent ops
  batches are kilobytes; 4 MB is generous headroom, not a target.
- Bridge crash must never take down the app: socket reader is detached,
  handler errors are caught per-request and returned as `op_error`.

## Security

- **No network.** No new entitlements; sandbox profile unchanged; works
  unsigned/ad-hoc.
- Socket dir `0700`, token file `0600`, token regenerated per launch. An
  attacker is by definition a same-UID local process; the token stops casual
  snooping and cross-session accidents, not an attacker who can already read
  the user's container — that threat model is out of scope (and unchanged
  from v1, where the maps themselves are user-readable files).
- The bridge executes only the five methods above. There is no eval, no
  arbitrary path access: `new` writes only into the default library
  directory; `read`/`applyOps` act on the live session only.

## Testing

- Core: `CompositeAgentCommand` undo/redo, execute-time rollback on mid-batch
  failure, ordering of reverse undo. `swiftmind new` output round-trips
  through `HTMLCodec.decode`.
- CLI smoke (`scripts/test-cli.sh`): `new` + `--version` bump; MCP stdio
  handshake unit-tested by piping canned JSON-RPC lines with the app absent
  (expect the "app not running" tool error, not a crash).
- App: manual E2E — run the app, configure Kimi/Claude Code with
  `{"command": "swiftmind", "args": ["mcp"]}`, drive expand/restructure/
  formula-read scenarios, verify ⌘Z undoes each agent batch as one step and
  the undo stack survives (the v1 pain point).
- Gate: `swift test` + `./scripts/verify.sh` green; AGENTS.md/README updated.

## Doc fixes folded into this work

- AGENTS.md "each document window owns its own DocumentSession" is stale —
  the app currently has one `AppModel`/session shared by all windows
  (`SwiftMindMacApp.swift`). Correct it while documenting the bridge.
