#!/bin/bash
# Build MissionControl as a proper .app bundle
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"   # debug | release
APP="MissionControl.app"
BUILD_DIR=".build/arm64-apple-macosx/$CONFIG"

if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/MissionControl" "$APP/Contents/MacOS/MissionControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so the OS treats it as a bundled app (needed for SMAppService / UN)
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ Built $APP"
echo "  Run: open $APP"
echo "  Quit: pkill -f MissionControl"
