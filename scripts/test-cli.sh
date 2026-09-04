#!/usr/bin/env bash
# Smoke test for the swiftmind CLI against a scratch copy of the golden fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product swiftmind >/dev/null
CLI="$ROOT/.build/debug/swiftmind"
FIXTURE="$(ls "$ROOT"/Tests/SwiftMindCoreTests/Fixtures/*.swiftmind.html | head -1)"
WORK="$(mktemp -d)/smoke.swiftmind.html"
cp "$FIXTURE" "$WORK"

fail() { echo "FAIL: $1" >&2; exit 1; }

# read + validate
"$CLI" read "$WORK" >/dev/null || fail "read"
"$CLI" validate "$WORK" >/dev/null || fail "validate"

ROOT_ID=$("$CLI" read "$WORK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"]["id"])')
[ -n "$ROOT_ID" ] || fail "root id"

# add-child + find
"$CLI" add-child "$WORK" --parent "$ROOT_ID" --text "CLI Smoke Node" --id n_smoke >/dev/null || fail "add-child"
"$CLI" find "$WORK" --query "Smoke" | grep -q n_smoke || fail "find"

# set-attr + set-formula
"$CLI" set-attr "$WORK" --id n_smoke --name status --value done >/dev/null || fail "set-attr"
"$CLI" set-formula "$WORK" --id n_smoke --formula "count(children)" >/dev/null || fail "set-formula"

# batch: rename + fold
echo '[{"op":"set-text","id":"n_smoke","text":"Renamed Smoke"},{"op":"fold","id":"n_smoke"}]' \
  | "$CLI" batch "$WORK" >/dev/null || fail "batch"
"$CLI" read "$WORK" | grep -q "Renamed Smoke" || fail "batch applied"

# expand-note / collapse-note via batch; read exposes noteExpanded
echo '[{"op":"expand-note","id":"n_smoke"}]' | "$CLI" batch "$WORK" >/dev/null || fail "expand-note"
"$CLI" read "$WORK" | grep -q "noteExpanded" || fail "read exposes noteExpanded"
echo '[{"op":"collapse-note","id":"n_smoke"}]' | "$CLI" batch "$WORK" >/dev/null || fail "collapse-note"
"$CLI" read "$WORK" | grep -q "noteExpanded" && fail "collapse-note should remove noteExpanded"

# atomicity: failing batch leaves file unchanged
BEFORE=$(shasum "$WORK" | cut -d' ' -f1)
if echo '[{"op":"set-text","id":"n_smoke","text":"X"},{"op":"delete","ids":["n_nope"]}]' | "$CLI" batch "$WORK" 2>/dev/null; then
  fail "failing batch should exit non-zero"
fi
AFTER=$(shasum "$WORK" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] || fail "batch not atomic"

# move + pin/unpin + delete
"$CLI" add-child "$WORK" --parent "$ROOT_ID" --text "To Move" --id n_move >/dev/null
"$CLI" move "$WORK" --id n_move --to n_smoke --index 0 >/dev/null || fail "move"
"$CLI" pin "$WORK" --id n_move --x 10 --y -20 >/dev/null || fail "pin"
"$CLI" unpin "$WORK" --id n_move >/dev/null || fail "unpin"
"$CLI" delete "$WORK" --ids n_move >/dev/null || fail "delete"
COUNT=$("$CLI" find "$WORK" --query "To Move" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$COUNT" = "0" ] || fail "delete verified"

# validate the final file still parses
"$CLI" validate "$WORK" >/dev/null || fail "final validate"

# --version prints something sane
"$CLI" --version | grep -qE '^swiftmind [0-9]+\.[0-9]+\.[0-9]+$' || fail "--version"

# batch rejects extra positional arguments
if "$CLI" batch "$WORK" ops1.json ops2.json 2>/dev/null; then
  fail "batch with extra positional args should exit non-zero"
fi

# human-readable error for a missing node (no Swift internal repr)
ERR=$("$CLI" set-text "$WORK" --id n_nope --text x 2>&1 >/dev/null) && fail "set-text on missing node should fail"
echo "$ERR" | grep -q "node not found: n_nope" || fail "human-readable error, got: $ERR"
echo "$ERR" | grep -q "NodeID(rawValue" && fail "error still leaks internal repr: $ERR"

# clobber guard: keep touching the file while a large batch is mid-apply,
# so at least one modification lands inside the CLI's read→write window
python3 - "$WORK" "$CLI" <<'PYEOF' || fail "clobber guard"
import json, subprocess, sys, threading, time
work, cli = sys.argv[1], sys.argv[2]
stop = False
def toucher():
    while not stop:
        with open(work, "a") as f:
            f.write("<!-- concurrent -->\n")
        time.sleep(0.02)
t = threading.Thread(target=toucher)
t.start()
ops = [{"op": "set-text", "id": "n_smoke", "text": f"bulk {i}"} for i in range(20000)]
p = subprocess.run([cli, "batch", work], input=json.dumps(ops).encode(),
                   capture_output=True)
stop = True
t.join()
if p.returncode != 2 or b"changed on disk" not in p.stderr:
    print(f"expected clobber refusal (exit 2), got rc={p.returncode} err={p.stderr!r}", file=sys.stderr)
    sys.exit(1)
PYEOF

# new: creates a map, refuses to overwrite
NEWF="$(mktemp -d)/fresh.swiftmind.html"
"$CLI" new "$NEWF" --title "Fresh" >/dev/null || fail "new"
"$CLI" validate "$NEWF" >/dev/null || fail "new output validates"
"$CLI" read "$NEWF" | grep -q '"Fresh"' || fail "new title"
if "$CLI" new "$NEWF" 2>/dev/null; then
  fail "new on existing file should exit non-zero"
fi

# mcp without the app: initialize works, tool call reports app not running
MCP_OUT=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_map","arguments":{}}}' \
  | "$CLI" mcp)
echo "$MCP_OUT" | grep -q '"serverInfo"' || fail "mcp initialize"
# When no app is running the tools/call result reports "not running":
#   echo "$MCP_OUT" | grep -q 'not running' || fail "mcp app-absent tool error"
# A dev instance may be live here, so accept either outcome but require a
# well-formed JSON-RPC response with "id":2 and a result containing content.
echo "$MCP_OUT" | grep -q '"id":2' || fail "mcp tools/call response"
echo "$MCP_OUT" | grep -q '"content"' || fail "mcp tools/call content"

# bridge loopback: fake UDS bridge + real MCP round-trip through swiftmind mcp
LB_DIR="$(mktemp -d)/bridge"
python3 "$ROOT/scripts/test-bridge-loopback.py" "$LB_DIR" &
LB_PID=$!
trap 'kill $LB_PID 2>/dev/null || true' EXIT
for i in $(seq 1 50); do [ -S "$LB_DIR/agent.sock" ] && break; sleep 0.1; done
[ -S "$LB_DIR/agent.sock" ] || fail "loopback bridge did not start"
MCP_LB=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_session","arguments":{}}}' \
  | SWIFTMIND_BRIDGE_DIR="$LB_DIR" "$CLI" mcp)
# the bridge response is pretty-printed JSON escaped into the MCP content text
echo "$MCP_LB" | grep -q 'loopback\\" : true' || fail "mcp loopback round-trip: $MCP_LB"
echo "$MCP_LB" | grep -q 'method\\" : \\"session\\"' || fail "loopback method echo"
kill $LB_PID 2>/dev/null || true
trap - EXIT

echo "CLI smoke test OK"
