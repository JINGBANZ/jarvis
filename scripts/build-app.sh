#!/usr/bin/env bash
# Build, bundle, and sign Jarvis Dev.app.
# Usage: ./scripts/build-app.sh [release|debug] [--run]
#
# TCC keys permission grants to the code signature, so the bundle is signed with a stable
# self-signed identity; ad-hoc signing would re-prompt on every build.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="release"
LAUNCH=""
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --run)         LAUNCH="run" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

source scripts/lib/test-display.sh
isolate_test_display "$@"

APP_NAME="Jarvis Dev"
APP="$APP_NAME.app"
BUNDLE_ID="com.jarvis.coach.dev"
BIN_NAME="JarvisApp"
IDENTITY="Jarvis Dev"

# Self-signed and untrusted (CSSMERR_TP_NOT_TRUSTED is expected); it only needs to be stable.
ensure_identity() {
  if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    return
  fi
  echo "▶ creating stable signing identity '$IDENTITY' (one-time)"
  local TMP; TMP="$(mktemp -d)"
  cat > "$TMP/csr.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/csr.conf" >/dev/null 2>&1
  # Legacy PBE/MAC so macOS `security` can import the PKCS#12 (OpenSSL 3's default is incompatible).
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -name "$IDENTITY" -passout pass:jarvis \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1
  # Least privilege: only /usr/bin/codesign may use the key (-A would allow any app).
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P jarvis -T /usr/bin/codesign
  rm -rf "$TMP"
  echo "  created. macOS will ask once to let codesign use the key — click 'Always Allow'."
}

ensure_identity

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "▶ assembling $APP"
source scripts/lib/app-bundle.sh
assemble_app "$APP" "$(dirname "$BIN_PATH")" "$CONFIG"
# A distinct name and bundle id keep the dev build from sharing TCC grants or Launch Services
# registration with an installed release.
/usr/bin/plutil -replace CFBundleName -string "$APP_NAME" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$APP_NAME" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
# Sparkle can't install a Developer ID release over a self-signed build, so the dev build has no feed.
/usr/bin/plutil -remove SUFeedURL "$APP/Contents/Info.plist"
# The copied plist's release version would misname a local build; this makes the menu caption read "Dev".
/usr/bin/plutil -replace JarvisDevelopmentBuild -bool YES "$APP/Contents/Info.plist"

echo "▶ signing with '$IDENTITY'"
sign_reference_helper "$APP" "$IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"
echo "✅ built $APP"

case "$LAUNCH" in
  run)
    echo "▶ launching $APP_NAME — open Settings → Activity to watch the log; sessions stay beside the bundle"
    open ./"$APP"
    ;;
  "")
    echo "   run: open ./$APP        (or: ./scripts/build-app.sh --run)"
    ;;
esac
