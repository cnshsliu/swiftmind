#!/usr/bin/env bash
# XcodeGen may leave debugDocumentVersioning=YES which injects
# -NSDocumentRevisionsDebugMode YES and DocumentGroup opens "YES" as a file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="$ROOT/Apps/SwiftMindMac/SwiftMindMac.xcodeproj/xcshareddata/xcschemes/SwiftMindMac.xcscheme"
if [ -f "$SCHEME" ]; then
  sed -i '' 's/debugDocumentVersioning = "YES"/debugDocumentVersioning = "NO"/g' "$SCHEME"
  echo "patched $SCHEME (debugDocumentVersioning=NO)"
else
  echo "scheme not found: $SCHEME" >&2
  exit 1
fi
