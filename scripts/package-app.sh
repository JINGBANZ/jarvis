#!/usr/bin/env bash
# Package Jarvis.app for distribution: Developer ID signing + notarization + stapling.
# Produces Jarvis-<version>.zip, which opens on any Apple silicon Mac (macOS 14.2+) with no
# Gatekeeper friction. Driven locally or by CI (.github/workflows/release.yml).
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

echo "▶ swift build -c release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"

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

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="Jarvis-$VERSION.zip"

# ditto (not zip/Finder) preserves the extended attributes the signature lives alongside.
echo "▶ submitting to Apple's notary service (usually 1-5 min)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
submit_json="$(xcrun notarytool submit "$ZIP" "${notary[@]}" --wait --timeout 30m --output-format json)" || true
echo "$submit_json"
status="$(plutil -extract status raw -o - - <<<"$submit_json" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
  # The submission log names the exact offending file and reason — fetch it before failing.
  id="$(plutil -extract id raw -o - - <<<"$submit_json" 2>/dev/null || true)"
  [[ -n "$id" ]] && xcrun notarytool log "$id" "${notary[@]}" || true
  echo "error: notarization did not complete (status: ${status:-unknown})" >&2
  exit 1
fi

# Staple the ticket to the .app so Gatekeeper trusts it offline, then RE-zip: a zip itself cannot
# be stapled, so the shipped archive must be rebuilt from the stapled bundle.
echo "▶ stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Verify the exact archive users receive, not only the pre-compression bundle. A packaging mistake
# must leave the draft Release unpublished even if signing and notarization already succeeded.
./scripts/verify-release.sh "$ZIP"
echo "✅ $ZIP is notarized and ready to distribute (Apple silicon, macOS 14.2+)"
