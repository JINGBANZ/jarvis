#!/usr/bin/env bash
# Package Jarvis.app for distribution: Developer ID signing + notarization + stapling.
# Produces Jarvis.dmg, which presents the app beside an Applications shortcut on any Apple silicon
# Mac (macOS 14.2+) with no Gatekeeper friction. Driven locally or by CI
# (.github/workflows/release.yml).
#
# Deliberately self-contained rather than layered on build-app.sh: the dev script's self-signed
# "Jarvis Dev" identity exists only so local TCC grants persist, and creating it can prompt for
# keychain access — a hang on a headless runner. Here the bundle is signed exactly once, with a
# Developer ID certificate, hardened runtime, and a secure timestamp (all notarization
# requirements). Hardened runtime blocks mic capture unless the audio-input entitlement is
# granted, hence --entitlements.
#
# Credentials:
#   Signing — a "Developer ID Application" certificate in the keychain search list
#     (auto-detected), or pass IDENTITY="Developer ID Application: Name (TEAM)" explicitly.
#   Notarization — either an App Store Connect API key via env (what CI uses):
#       NOTARY_KEY_PATH=/path/to/AuthKey.p8  NOTARY_KEY_ID=<10 chars>  NOTARY_ISSUER_ID=<uuid>
#     or a stored notarytool keychain profile (local one-time setup; app-specific password
#     from appleid.apple.com):
#       xcrun notarytool store-credentials jarvis-notary --apple-id you@example.com --team-id TEAMID
#     Override the profile name with NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Jarvis.app"
BIN_NAME="JarvisApp"

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
    # The submission log names the exact offending file and reason — fetch it before failing.
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Jarvis.icns "$APP/Contents/Resources/Jarvis.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

echo "▶ signing (hardened runtime + timestamp)"
# No --deep: the bundle is a single statically-linked executable with no nested code.
codesign --force --options runtime --timestamp \
  --entitlements Resources/Jarvis.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

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
  local cleanup_safe=true
  trap - EXIT
  if [[ -n "${DMG_STAGE:-}" && -n "${DMG_STAGE_PREFIX:-}" \
        && "$DMG_STAGE" == "$DMG_STAGE_PREFIX"* && -d "$DMG_STAGE" \
        && ! -L "$DMG_STAGE" ]]; then
    if [[ -L "$DMG_STAGE/Applications" \
          && "$(readlink "$DMG_STAGE/Applications")" == "/Applications" ]]; then
      unlink "$DMG_STAGE/Applications"
    elif [[ -e "$DMG_STAGE/Applications" || -L "$DMG_STAGE/Applications" ]]; then
      echo "error: refusing to clean an unexpected Applications staging entry" >&2
      exit_code=1
      cleanup_safe=false
    fi
    if find "$DMG_STAGE" -type l -print -quit | grep -q .; then
      echo "error: refusing to clean disk-image staging with an unexpected symbolic link" >&2
      exit_code=1
      cleanup_safe=false
    elif [[ "$cleanup_safe" == "true" ]]; then
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

# The app must carry its own ticket before it is sealed inside the final disk image. Otherwise the
# mounted artifact fails the same offline distribution policy that users rely on after copying it.
echo "▶ stapling application"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "▶ creating drag-install disk image"
ditto "$APP" "$DMG_STAGE/$APP"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Jarvis -srcfolder "$DMG_STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --identifier "$DMG_IDENTIFIER" --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

notarize_artifact "$DMG" "disk image"

# The outer ticket covers the exact container users download as well as the app ticket already
# embedded inside it.
echo "▶ stapling disk image"
xcrun stapler staple "$DMG"

# Verify the exact disk image users receive, not only the pre-container bundle. A packaging mistake
# must leave the draft Release unpublished even if signing and notarization already succeeded.
verify_args=("$DMG")
if [[ -n "${EXPECTED_RELEASE_TAG:-}" ]]; then
  verify_args+=("$EXPECTED_RELEASE_TAG")
fi
./scripts/verify-release.sh "${verify_args[@]}"
echo "✅ $DMG is notarized and ready to distribute (Apple silicon, macOS 14.2+)"
