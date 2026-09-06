#!/bin/bash
# Regenerate the bundled Welcome/Help map from help-map.ops.json.
# Run this whenever features or shortcuts change, then commit the result:
#   scripts/make-help-map.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OPS="Apps/SwiftMindMac/SwiftMindMac/Resources/help-map.ops.json"
OUT="Apps/SwiftMindMac/SwiftMindMac/Resources/Welcome to SwiftMind.swiftmind.html"
BIN=".build/debug/swiftmind"

swift build
TMP="$(mktemp -t swiftmind-help).swiftmind.html"
trap 'rm -f "$TMP" "$TMP.ops.json"' EXIT

"$BIN" new "$TMP" --title "Welcome to SwiftMind" >/dev/null
ROOT="$("$BIN" read "$TMP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"]["id"])')"
sed "s/__ROOT__/$ROOT/g" "$OPS" > "$TMP.ops.json"
"$BIN" batch "$TMP" "$TMP.ops.json" >/dev/null
"$BIN" validate "$TMP" >/dev/null
# Pin map/root ids so regenerations stay diff-stable — HelpMapInstaller
# compares normalized content across app versions.
python3 - "$TMP" "$ROOT" <<'EOF'
import sys, re
path, root = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'data-map-id="[^"]*"', 'data-map-id="m_help_welcome"', s, count=1)
s = s.replace(f'data-node-id="{root}"', 'data-node-id="n_help_root"', 1)
open(path, "w").write(s)
EOF
mv "$TMP" "$OUT"
echo "Wrote $OUT"
