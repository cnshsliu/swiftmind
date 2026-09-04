#!/usr/bin/env bash
# Stop any running SwiftMind (including Xcode debug sessions), rebuild, launch.
# Usage: ./scripts/rerun-mac.sh [--no-test] [--no-launch] [--release]
#
# Default (Debug): dev loop — tests + Debug build, launched from DerivedData.
# The permanent copy in /Volumes/WD/Applications is NOT touched in this mode.
# --release: build -configuration Release, sync it to /Volumes/WD/Applications
# (when the volume is present) and launch that copy. Use this to refresh the
# permanent install; dev runs never downgrade it to Debug.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/Apps/SwiftMindMac"
SCHEME="SwiftMindMac"
PRODUCT_NAME="SwiftMind"
RUN_TESTS=1
DO_LAUNCH=1
CONFIG="Debug"

for arg in "$@"; do
  case "$arg" in
    --no-test) RUN_TESTS=0 ;;
    --no-launch) DO_LAUNCH=0 ;;
    --release) CONFIG="Release" ;;
    -h|--help)
      echo "Usage: $0 [--no-test] [--no-launch] [--release]"
      exit 0
      ;;
  esac
done

# Match only the instance this run manages, by executable path — the Debug
# dev instance (DerivedData) and the permanent Release install can run side
# by side, so a bare `pkill -x SwiftMind` would kill the wrong one.
INSTALL_DIR="/Volumes/WD/Applications"
if [ "$CONFIG" = "Release" ]; then
  PROC_PATTERN="${INSTALL_DIR}/SwiftMind\.app/Contents/MacOS/SwiftMind"
else
  PROC_PATTERN="DerivedData.*SwiftMind\.app/Contents/MacOS/SwiftMind"
fi

proc_pids() { pgrep -f "$PROC_PATTERN" 2>/dev/null || true; }

stop_app() {
  echo "==> Stopping running ${PRODUCT_NAME} (${CONFIG})…"
  OLD_PIDS="$(proc_pids)"

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

  OLD_PIDS="$(proc_pids)"
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
  if [ -n "$(proc_pids)" ] && pgrep -x debugserver >/dev/null 2>&1; then
    echo "    stopping debugserver (Xcode was debugging this app)…"
    pkill -x debugserver 2>/dev/null || true
    sleep 0.4
    # shellcheck disable=SC2086
    kill -9 $(proc_pids) 2>/dev/null || true
    sleep 0.2
  fi

  if [ -n "$(proc_pids)" ]; then
    echo "    WARNING: still running: $(proc_pids | tr '\n' ' ')"
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

echo "==> Build ${SCHEME} (${CONFIG})…"
LOG=/tmp/swiftmind-xcodebuild.log
if ! (cd "$APP_DIR" && xcodebuild \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -configuration "$CONFIG" \
  CODE_SIGN_IDENTITY=- \
  build >"$LOG" 2>&1); then
  echo "xcodebuild FAILED — last 50 lines:"
  tail -50 "$LOG"
  exit 1
fi
echo "    BUILD SUCCEEDED"

APP_PATH="$(cd "$APP_DIR" && xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{ if (d!="" && n!="") print d "/" n }')"

if [ ! -d "${APP_PATH:-}" ]; then
  APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/${CONFIG}/SwiftMind.app" -type d 2>/dev/null \
    | while IFS= read -r p; do
        printf '%s\t%s\n' "$(stat -f '%m' "$p" 2>/dev/null || echo 0)" "$p"
      done | sort -rn | head -1 | cut -f2-)"
fi

if [ ! -d "${APP_PATH:-}" ]; then
  echo "Could not locate SwiftMind.app after build"
  exit 1
fi

echo "    App: $APP_PATH"

# Sync the permanent copy only for Release builds — the install in
# /Volumes/WD/Applications must stay Release; Debug dev loops never touch it.
if [ "$CONFIG" = "Release" ] && [ -d "$INSTALL_DIR" ]; then
  echo "==> Syncing to ${INSTALL_DIR}…"
  rsync -a --delete "$APP_PATH" "$INSTALL_DIR/"
  APP_PATH="$INSTALL_DIR/$PRODUCT_NAME.app"
fi

if [ "$DO_LAUNCH" -eq 1 ]; then
  echo "==> Launching…"
  open "$APP_PATH"
  sleep 1.2
  NEW_PIDS="$(proc_pids | tr '\n' ' ')"
  if [ -n "$(echo "$NEW_PIDS" | tr -d '[:space:]')" ]; then
    echo "==> ${PRODUCT_NAME} running (pid ${NEW_PIDS})"
  else
    echo "==> NOTE: process not listed yet (File Open panel may be waiting — press ⌘N)"
  fi
fi

echo "==> Done."
