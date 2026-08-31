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

echo "CLI smoke test OK"
