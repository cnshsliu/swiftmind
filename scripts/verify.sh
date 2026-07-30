#!/usr/bin/env bash
# Automated verification: unit tests + Mac build (no launch).
# Usage: ./scripts/verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> swift test"
(cd "$ROOT" && swift test)

echo "==> Mac app build"
"$ROOT/scripts/rerun-mac.sh" --no-test --no-launch

echo "==> All automated checks passed."
