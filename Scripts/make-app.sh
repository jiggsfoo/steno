#!/bin/bash
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(swift build --configuration "$CONFIG" --show-bin-path)"
APP="$ROOT/build/HiDock.app"

swift build --configuration "$CONFIG" --product HiDockApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HiDockApp" "$APP/Contents/MacOS/HiDockApp"
cp "$ROOT/Sources/HiDockApp/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
