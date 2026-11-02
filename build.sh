#!/bin/bash
# Builds VideoFilmer.app into ./build. Pass "debug" for a debug build.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/VideoFilmer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VideoFilmer" "$APP/Contents/MacOS/VideoFilmer"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature whose identity is just the bundle id, so macOS keeps the
# camera/mic permissions across rebuilds instead of asking again.
codesign --force --sign - --identifier com.videofilmer.app \
  -r='designated => identifier "com.videofilmer.app"' "$APP"

echo "Built $APP"
