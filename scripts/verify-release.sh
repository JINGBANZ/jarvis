#!/usr/bin/env bash
# Verify the exact Jarvis disk image users download after it has been signed and notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
EXPECTED_RELEASE_TAG="${2:-}"
DMGBUILD_PYTHON="${DMGBUILD_PYTHON:-python3}"
if [[ $# -gt 2 || -z "$DMG" || ! -f "$DMG" || -L "$DMG" ]]; then
  echo "usage: $0 Jarvis.dmg [v<version>]" >&2
  exit 2
fi

if ! "$DMGBUILD_PYTHON" -c 'from ds_store import DSStore' 2>/dev/null; then
  echo "error: the pinned release-layout dependencies are required to verify the DMG." >&2
  echo "       Install scripts/requirements-release.txt in a virtual environment, then pass" >&2
  echo "       DMGBUILD_PYTHON=/path/to/venv/bin/python." >&2
  exit 1
fi
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
if [[ "$(basename "$DMG")" != "Jarvis.dmg" ]]; then
  echo "error: release disk image must be named Jarvis.dmg" >&2
  exit 1
fi

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
MOUNT_POINT="$VERIFY_DIR/mount"
mkdir "$MOUNT_POINT"
MOUNTED=false
cleanup_verify_dir() {
  local status=$?
  trap - EXIT
  if [[ "${MOUNTED:-false}" == "true" ]]; then
    if hdiutil detach "$MOUNT_POINT"; then
      MOUNTED=false
    else
      echo "error: couldn't detach release-verification disk image; leaving it mounted" >&2
      status=1
    fi
  fi
  if [[ "${MOUNTED:-false}" == "false" && -n "${VERIFY_DIR:-}" \
        && -n "${VERIFY_PREFIX:-}" && "$VERIFY_DIR" == "$VERIFY_PREFIX"* \
        && -d "$VERIFY_DIR" && ! -L "$VERIFY_DIR" ]]; then
    rm -rf -- "$VERIFY_DIR"
  fi
  exit "$status"
}
trap cleanup_verify_dir EXIT

echo "▶ verifying final disk image: $(basename "$DMG")"
hdiutil verify "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT"
MOUNTED=true

EXTRACTED_APP="$MOUNT_POINT/$APP"
APPLICATIONS_LINK="$MOUNT_POINT/Applications"
ENTRY_COUNT="$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
if [[ "$ENTRY_COUNT" != "4" || ! -d "$EXTRACTED_APP" || -L "$EXTRACTED_APP" \
      || ! -f "$MOUNT_POINT/.DS_Store" || -L "$MOUNT_POINT/.DS_Store" \
      || ! -f "$MOUNT_POINT/.background.tiff" || -L "$MOUNT_POINT/.background.tiff" ]]; then
  echo "error: final disk image must contain the two visible install targets and exact layout metadata" >&2
  exit 1
fi
if [[ ! -L "$APPLICATIONS_LINK" || "$(readlink "$APPLICATIONS_LINK")" != "/Applications" ]]; then
  echo "error: final disk image must contain an Applications shortcut targeting /Applications" >&2
  exit 1
fi
"$DMGBUILD_PYTHON" scripts/verify-dmg-layout.py "$MOUNT_POINT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$EXTRACTED_APP/Contents/Info.plist")"
if [[ -n "$EXPECTED_RELEASE_TAG" && "$EXPECTED_RELEASE_TAG" != "v$VERSION" ]]; then
  echo "error: expected release tag $EXPECTED_RELEASE_TAG does not match bundled version $VERSION" >&2
  exit 1
fi
EXTRACTED_BIN="$EXTRACTED_APP/Contents/MacOS/$BIN_NAME"
ARCHITECTURES="$(lipo -archs "$EXTRACTED_BIN")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  echo "error: disk-image app has unexpected architectures: $ARCHITECTURES" >&2
  exit 1
fi
./scripts/check-release-sdk.sh "$EXTRACTED_BIN"
if [[ ! -f "$EXTRACTED_APP/Contents/Resources/LICENSE" \
      || ! -f "$EXTRACTED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]; then
  echo "error: disk-image app is missing required license notices" >&2
  exit 1
fi

EXTRACTED_SPARKLE="$EXTRACTED_APP/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$EXTRACTED_SPARKLE" || -L "$EXTRACTED_SPARKLE" ]]; then
  echo "error: disk-image app is missing the embedded Sparkle updater framework" >&2
  exit 1
fi
# Sandbox-only helpers must never reach users: they cannot run in this non-sandboxed app, and
# shipping them would put unreachable code inside the notarized bundle.
if [[ -e "$EXTRACTED_SPARKLE/Versions/Current/XPCServices" ]]; then
  echo "error: disk-image app ships Sparkle's sandbox-only XPC services" >&2
  exit 1
fi

# --deep for verification only: the app now seals Sparkle's update helpers, and every nested
# signature must hold in the artifact users mount.
codesign --verify --strict --deep --verbose=2 "$EXTRACTED_APP"
# syspolicy_check runs the modern macOS distribution checks; keep spctl as the direct Gatekeeper
# policy assertion already used by the release contract.
syspolicy_check distribution "$EXTRACTED_APP" --verbose
spctl --assess --type execute --verbose "$EXTRACTED_APP"
echo "✅ $(basename "$DMG") passed final release verification"
