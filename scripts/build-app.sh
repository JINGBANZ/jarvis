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

echo "▶ signing"
# Prefer a stable self-signed identity so macOS TCC permission grants (Microphone, Screen
# Recording) persist across rebuilds. Ad-hoc signing changes identity every build, which makes
# macOS re-prompt for permissions each time. Create the identity once with scripts/make-signing-identity.sh.
IDENTITY="Jarvis Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "  using stable identity: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "  '$IDENTITY' not found — falling back to ad-hoc (TCC permissions will reset each build)."
  echo "  run scripts/make-signing-identity.sh once to fix this."
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose "$APP"

echo "✅ built $APP"
echo "   run: open ./$APP        (always via 'open' — launching the bare binary makes macOS"
echo "                            attribute Mic/Screen-Recording grants to the shell, not Jarvis)"
echo "   dev: ./scripts/run-dev.sh   (dev mode + live activity viewer; logs to ./.jarvis/)"
