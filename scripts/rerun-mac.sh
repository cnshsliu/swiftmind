#!/usr/bin/env bash
# Stop any running SwiftMind (including Xcode debug sessions), rebuild, launch.
# Usage: ./scripts/rerun-mac.sh [--no-test] [--no-launch]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/Apps/SwiftMindMac"
SCHEME="SwiftMindMac"
PRODUCT_NAME="SwiftMind"
RUN_TESTS=1
DO_LAUNCH=1

for arg in "$@"; do
  case "$arg" in
    --no-test) RUN_TESTS=0 ;;
    --no-launch) DO_LAUNCH=0 ;;
    -h|--help)
      echo "Usage: $0 [--no-test] [--no-launch]"
      exit 0
      ;;
  esac
done

stop_app() {
  echo "==> Stopping running ${PRODUCT_NAME}…"
  OLD_PIDS="$(pgrep -x "$PRODUCT_NAME" 2>/dev/null || true)"

  if [ -z "$OLD_PIDS" ]; then
    echo "    not running"
    return 0
  fi

  echo "    found: $OLD_PIDS"

  # If launched from Xcode (debugserver attached), Product → Stop (⌘.) first.
  if pgrep -x debugserver >/dev/null 2>&1; then
    echo "    Xcode debug session detected — sending Stop (⌘.)…"
    osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application "Xcode" to activate
delay 0.2
tell application "System Events"
  if exists process "Xcode" then
    tell process "Xcode" to keystroke "." using command down
  end if
end tell
APPLESCRIPT
    sleep 1.0
  fi

  OLD_PIDS="$(pgrep -x "$PRODUCT_NAME" 2>/dev/null || true)"
  if [ -n "$OLD_PIDS" ]; then
    echo "    kill: $OLD_PIDS"
    # shellcheck disable=SC2086
    kill $OLD_PIDS 2>/dev/null || true
    sleep 0.35
    # shellcheck disable=SC2086
    kill -9 $OLD_PIDS 2>/dev/null || true
    sleep 0.25
  fi

  # Last resort: debugserver may still hold the process
  if pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1 && pgrep -x debugserver >/dev/null 2>&1; then
    echo "    stopping debugserver (Xcode was debugging this app)…"
    pkill -x debugserver 2>/dev/null || true
    sleep 0.4
    # shellcheck disable=SC2046
    kill -9 $(pgrep -x "$PRODUCT_NAME" 2>/dev/null) 2>/dev/null || true
    sleep 0.2
  fi

  if pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
    echo "    WARNING: still running: $(pgrep -x "$PRODUCT_NAME" | tr '\n' ' ')"
    return 1
  fi
  echo "    stopped"
}

stop_app || true

if [ "$RUN_TESTS" -eq 1 ]; then
  echo "==> Core tests (swift test)…"
  (cd "$ROOT" && swift test)
fi

echo "==> Generate Xcode project…"
(cd "$APP_DIR" && xcodegen generate)
"$ROOT/scripts/patch-xcode-scheme.sh"

echo "==> Build ${SCHEME}…"
LOG=/tmp/swiftmind-xcodebuild.log
if ! (cd "$APP_DIR" && xcodebuild \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -configuration Debug \
  CODE_SIGN_IDENTITY=- \
  build >"$LOG" 2>&1); then
  echo "xcodebuild FAILED — last 50 lines:"
  tail -50 "$LOG"
  exit 1
fi
echo "    BUILD SUCCEEDED"

APP_PATH="$(cd "$APP_DIR" && xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{ if (d!="" && n!="") print d "/" n }')"

if [ ! -d "${APP_PATH:-}" ]; then
  APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/SwiftMind.app' -type d 2>/dev/null \
    | while IFS= read -r p; do
        printf '%s\t%s\n' "$(stat -f '%m' "$p" 2>/dev/null || echo 0)" "$p"
      done | sort -rn | head -1 | cut -f2-)"
fi

if [ ! -d "${APP_PATH:-}" ]; then
  echo "Could not locate SwiftMind.app after build"
  exit 1
fi

echo "    App: $APP_PATH"

if [ "$DO_LAUNCH" -eq 1 ]; then
  echo "==> Launching…"
  open "$APP_PATH"
  sleep 1.2
  NEW_PIDS="$(pgrep -x "$PRODUCT_NAME" 2>/dev/null | tr '\n' ' ' || true)"
  if [ -n "$(echo "$NEW_PIDS" | tr -d '[:space:]')" ]; then
    echo "==> ${PRODUCT_NAME} running (pid ${NEW_PIDS})"
  else
    echo "==> NOTE: process not listed yet (File Open panel may be waiting — press ⌘N)"
  fi
fi

echo "==> Done."
