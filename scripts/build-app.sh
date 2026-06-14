#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="Jarvis.app"
BIN_NAME="JarvisApp"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▶ ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "✅ built $APP"
echo "   run: open ./$APP   (or ./$APP/Contents/MacOS/$BIN_NAME for console logs)"
