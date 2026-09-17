#!/usr/bin/env bash
# Package Jarvis.app as a signed, notarized, stapled Jarvis.dmg.
#
# Not layered on build-app.sh: creating its self-signed identity can prompt for keychain access,
# which hangs a headless runner.
# Notarization credentials: NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID (CI), or a profile from
# `xcrun notarytool store-credentials` named by NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Jarvis.app"
BIN_NAME="JarvisApp"
DMGBUILD_PYTHON="${DMGBUILD_PYTHON:-python3}"
EXPECTED_DMGBUILD_VERSION="1.6.7"

if ! "$DMGBUILD_PYTHON" -c \
    'import dmgbuild, sys; sys.exit(dmgbuild.__version__ != sys.argv[1])' \
    "$EXPECTED_DMGBUILD_VERSION"; then
  echo "error: dmgbuild $EXPECTED_DMGBUILD_VERSION is required for the installer layout." >&2
  echo "       Install scripts/requirements-release.txt in a virtual environment, then pass" >&2
  echo "       DMGBUILD_PYTHON=/path/to/venv/bin/python." >&2
  exit 1
fi

if [[ -z "${IDENTITY:-}" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  if [[ -z "$IDENTITY" ]]; then
    echo "error: no 'Developer ID Application' certificate in the keychain search list." >&2
    echo "       Create one at developer.apple.com → Certificates and install it, or pass" >&2
    echo "       IDENTITY=\"Developer ID Application: ...\" explicitly." >&2
    exit 1
  fi
fi
echo "▶ signing identity: $IDENTITY"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  notary=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID required with NOTARY_KEY_PATH}" \
          --issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID required with NOTARY_KEY_PATH}")
else
  notary=(--keychain-profile "${NOTARY_PROFILE:-jarvis-notary}")
fi

notarize_artifact() {
  local artifact="$1"
  local description="$2"
  local submit_json
  local notary_status
  local submission_id

  echo "▶ submitting $description to Apple's notary service (usually 1-5 min)"
  submit_json="$(xcrun notarytool submit "$artifact" "${notary[@]}" \
    --wait --timeout 30m --output-format json)" || true
  echo "$submit_json"
  notary_status="$(plutil -extract status raw -o - - <<<"$submit_json" 2>/dev/null || true)"
  if [[ "$notary_status" != "Accepted" ]]; then
    # The submission log names the offending file and reason.
    submission_id="$(plutil -extract id raw -o - - <<<"$submit_json" 2>/dev/null || true)"
    [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" "${notary[@]}" || true
    echo "error: $description notarization did not complete (status: ${notary_status:-unknown})" >&2
    return 1
  fi
}

echo "▶ swift build -c release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"
./scripts/check-release-sdk.sh "$BIN_PATH"

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Jarvis.icns "$APP/Contents/Resources/Jarvis.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# The target's rpath expects Sparkle at Contents/Frameworks.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$(dirname "$BIN_PATH")/Sparkle.framework" "$SPARKLE"
# SwiftPM emits resources as side-by-side bundles; `Bundle.module` finds them in Contents/Resources.
ditto "$(dirname "$BIN_PATH")/Jarvis_JarvisApp.bundle" \
      "$APP/Contents/Resources/Jarvis_JarvisApp.bundle"
ditto "$(dirname "$BIN_PATH")/Jarvis_JarvisCore.bundle" \
      "$APP/Contents/Resources/Jarvis_JarvisCore.bundle"
# Sparkle's XPC services only serve sandboxed apps. Remove the top-level alias too, or it dangles.
rm -rf "$SPARKLE/Versions/Current/XPCServices" "$SPARKLE/XPCServices"
source scripts/lib/cliproxyapi.sh
bundle_cliproxyapi "$APP"

echo "▶ signing (hardened runtime + timestamp)"
# Sign inner code before outer. Not --deep: Apple calls it unsuitable for distribution because it
# can't apply per-binary entitlements. Hardened runtime blocks the mic without the app's entitlement.
for nested in Versions/Current/Autoupdate Versions/Current/Updater.app; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/$nested"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/cliproxyapi"
codesign --force --options runtime --timestamp \
  --entitlements Resources/Jarvis.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

DMG="Jarvis.dmg"
DMG_IDENTIFIER="com.jarvis.coach.dmg"
DMG_ROOT="$PWD/.build"
if [[ -L "$DMG_ROOT" ]]; then
  echo "error: disk-image staging root must not be a symbolic link" >&2
  exit 1
fi
mkdir -p "$DMG_ROOT"
DMG_STAGE_PREFIX="$DMG_ROOT/jarvis-dmg-stage."
DMG_STAGE="$(mktemp -d "${DMG_STAGE_PREFIX}XXXXXX")"
if [[ -z "$DMG_STAGE" || "$DMG_STAGE" != "$DMG_STAGE_PREFIX"* \
      || ! -d "$DMG_STAGE" || -L "$DMG_STAGE" ]]; then
  echo "error: couldn't create a safe disk-image staging directory" >&2
  exit 1
fi
cleanup_dmg_stage() {
  local exit_code=$?
  trap - EXIT
  if [[ -n "${DMG_STAGE:-}" && -n "${DMG_STAGE_PREFIX:-}" \
        && "$DMG_STAGE" == "$DMG_STAGE_PREFIX"* && -d "$DMG_STAGE" \
        && ! -L "$DMG_STAGE" ]]; then
    # Framework symlinks are expected; refuse cleanup only if a link resolves outside the stage.
    # A dangling link counts as escaping, so the check fails closed.
    stage_real="$(cd "$DMG_STAGE" && pwd -P)"
    escaping_links=""
    while IFS= read -r link; do
      target="$(cd "$(dirname "$link")" 2>/dev/null && realpath "$(readlink "$link")" 2>/dev/null)" || true
      case "$target" in
        "$stage_real"/*) ;;
        *) escaping_links="$escaping_links$link"$'\n' ;;
      esac
    done < <(find "$DMG_STAGE" -type l)
    if [ -n "$escaping_links" ]; then
      echo "error: refusing to clean disk-image staging with a symbolic link outside it:" >&2
      printf '%s' "$escaping_links" >&2
      exit_code=1
    else
      rm -rf -- "$DMG_STAGE"
    fi
  fi
  exit "$exit_code"
}
trap cleanup_dmg_stage EXIT

APP_NOTARY_ARCHIVE="$DMG_STAGE/Jarvis-app.zip"
echo "▶ preparing application for notarization"
ditto -c -k --keepParent "$APP" "$APP_NOTARY_ARCHIVE"
notarize_artifact "$APP_NOTARY_ARCHIVE" "application"
rm -f "$APP_NOTARY_ARCHIVE"

# Staple the app before sealing it in the disk image, or the copied app fails offline Gatekeeper checks.
echo "▶ stapling application"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "▶ creating drag-install disk image"
ditto "$APP" "$DMG_STAGE/$APP"
rm -f "$DMG"
"$DMGBUILD_PYTHON" -m dmgbuild \
  --settings scripts/dmg-settings.py \
  -D "app=$DMG_STAGE/$APP" \
  Jarvis "$DMG"
codesign --force --timestamp --identifier "$DMG_IDENTIFIER" --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

notarize_artifact "$DMG" "disk image"

echo "▶ stapling disk image"
xcrun stapler staple "$DMG"

# A failure here keeps the draft Release unpublished even after notarization succeeded.
verify_args=("$DMG")
if [[ -n "${EXPECTED_RELEASE_TAG:-}" ]]; then
  verify_args+=("$EXPECTED_RELEASE_TAG")
fi
./scripts/verify-release.sh "${verify_args[@]}"
echo "✅ $DMG is notarized and ready to distribute (Apple silicon, macOS 14.2+)"
