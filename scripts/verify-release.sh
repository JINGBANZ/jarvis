#!/usr/bin/env bash
# Verify the exact Jarvis release archive users download after it has been signed and notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="${1:-}"
EXPECTED_RELEASE_TAG="${2:-}"
if [[ $# -gt 2 || -z "$ZIP" || ! -f "$ZIP" || -L "$ZIP" ]]; then
  echo "usage: $0 Jarvis-<version>.zip [v<version>]" >&2
  exit 2
fi
ZIP="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"

APP="Jarvis.app"
BIN_NAME="JarvisApp"
VERIFY_ROOT="$PWD/.build"
if [[ -L "$VERIFY_ROOT" ]]; then
  echo "error: release-verification root must not be a symbolic link" >&2
  exit 1
fi
mkdir -p "$VERIFY_ROOT"
VERIFY_PREFIX="$VERIFY_ROOT/jarvis-release-verify."
VERIFY_DIR="$(mktemp -d "${VERIFY_PREFIX}XXXXXX")"
if [[ -z "$VERIFY_DIR" || "$VERIFY_DIR" != "$VERIFY_PREFIX"* || ! -d "$VERIFY_DIR" || -L "$VERIFY_DIR" ]]; then
  echo "error: couldn't create a safe release-verification directory" >&2
  exit 1
fi
cleanup_verify_dir() {
  if [[ -n "${VERIFY_DIR:-}" && -n "${VERIFY_PREFIX:-}" \
        && "$VERIFY_DIR" == "$VERIFY_PREFIX"* && -d "$VERIFY_DIR" && ! -L "$VERIFY_DIR" ]]; then
    rm -rf -- "$VERIFY_DIR"
  fi
}
trap cleanup_verify_dir EXIT

echo "▶ verifying final archive: $(basename "$ZIP")"
ditto -x -k "$ZIP" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/$APP"
ENTRY_COUNT="$(find "$VERIFY_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
if [[ "$ENTRY_COUNT" != "1" || ! -d "$EXTRACTED_APP" || -L "$EXTRACTED_APP" ]]; then
  echo "error: final archive must contain exactly one regular $APP bundle" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$EXTRACTED_APP/Contents/Info.plist")"
if [[ "$(basename "$ZIP")" != "Jarvis-$VERSION.zip" ]]; then
  echo "error: archive filename does not match bundled version $VERSION" >&2
  exit 1
fi
if [[ -n "$EXPECTED_RELEASE_TAG" && "$EXPECTED_RELEASE_TAG" != "v$VERSION" ]]; then
  echo "error: expected release tag $EXPECTED_RELEASE_TAG does not match bundled version $VERSION" >&2
  exit 1
fi
ARCHITECTURES="$(lipo -archs "$EXTRACTED_APP/Contents/MacOS/$BIN_NAME")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  echo "error: archived app has unexpected architectures: $ARCHITECTURES" >&2
  exit 1
fi
if [[ ! -f "$EXTRACTED_APP/Contents/Resources/LICENSE" \
      || ! -f "$EXTRACTED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]; then
  echo "error: archived app is missing required license notices" >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$EXTRACTED_APP"
xcrun stapler validate "$EXTRACTED_APP"
# Final policy check, the way Gatekeeper will assess the downloaded app.
spctl --assess --type execute --verbose "$EXTRACTED_APP"
echo "✅ $(basename "$ZIP") passed final release verification"
