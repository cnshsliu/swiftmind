#!/usr/bin/env bash
# Run macOS XCUITests (Xcode built-in UI automation).
# Usage: ./scripts/test-ui.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/Apps/SwiftMindMac"
SCHEME="SwiftMindMac"
RESULT_BUNDLE="/tmp/SwiftMindUITests.xcresult"

# Stop app so UI tests own the process
pkill -x SwiftMind 2>/dev/null || true
sleep 0.3

echo "==> Generate project…"
(cd "$APP_DIR" && xcodegen generate)

echo "==> Run UI tests (XCUITest)…"
rm -rf "$RESULT_BUNDLE"
# Note: macOS UI tests need a GUI session (not headless CI without screen).
set +e
(cd "$APP_DIR" && xcodebuild \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -only-testing:SwiftMindMacUITests \
  CODE_SIGN_IDENTITY=- \
  -resultBundlePath "$RESULT_BUNDLE" \
  test 2>&1 | tee /tmp/swiftmind-uitest.log)
STATUS=${PIPESTATUS[0]}
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "UI tests FAILED (exit $STATUS). Last 60 lines:"
  tail -60 /tmp/swiftmind-uitest.log
  echo "Result bundle: $RESULT_BUNDLE"
  exit "$STATUS"
fi

echo "==> UI tests PASSED"
echo "    Result bundle: $RESULT_BUNDLE"
