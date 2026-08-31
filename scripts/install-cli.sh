#!/usr/bin/env bash
# Build and install the swiftmind CLI to ~/.local/bin (no sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product swiftmind
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cp "$ROOT/.build/release/swiftmind" "$BIN_DIR/swiftmind"
echo "Installed swiftmind to $BIN_DIR/swiftmind"
echo "Ensure $BIN_DIR is on your PATH."
