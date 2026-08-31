#!/usr/bin/env bash
# Full automated gate: core unit tests + CLI smoke + Mac build + XCUITest smoke.
# Usage: ./scripts/verify.sh [--skip-ui]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_UI=0
for arg in "$@"; do
  case "$arg" in
    --skip-ui) SKIP_UI=1 ;;
  esac
done

echo "======== 1/4 Core unit tests ========"
(cd "$ROOT" && swift test)

echo "======== 2/4 CLI smoke test ========"
"$ROOT/scripts/test-cli.sh"

echo "======== 3/4 Mac app build ========"
"$ROOT/scripts/rerun-mac.sh" --no-test --no-launch

if [ "$SKIP_UI" -eq 0 ]; then
  echo "======== 4/4 XCUITest smoke ========"
  "$ROOT/scripts/test-ui.sh"
else
  echo "======== 4/4 XCUITest skipped (--skip-ui) ========"
fi

echo "======== All automated checks passed ========"
