#!/usr/bin/env bash
# Full automated gate: core unit tests + Mac build + XCUITest smoke.
# Usage: ./scripts/verify.sh [--skip-ui]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_UI=0
for arg in "$@"; do
  case "$arg" in
    --skip-ui) SKIP_UI=1 ;;
  esac
done

echo "======== 1/3 Core unit tests ========"
(cd "$ROOT" && swift test)

echo "======== 2/3 Mac app build ========"
"$ROOT/scripts/rerun-mac.sh" --no-test --no-launch

if [ "$SKIP_UI" -eq 0 ]; then
  echo "======== 3/3 XCUITest smoke ========"
  "$ROOT/scripts/test-ui.sh"
else
  echo "======== 3/3 XCUITest skipped (--skip-ui) ========"
fi

echo "======== All automated checks passed ========"
