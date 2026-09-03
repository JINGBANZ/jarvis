#!/usr/bin/env bash
# Build, bundle, and sign Jarvis Dev.app.
#
# Signing uses a stable, self-signed identity ("Jarvis Dev") so that macOS TCC permission grants
# (Microphone, Screen Recording) persist across rebuilds — macOS keys a grant to the code signature,
# and an identity that changed every build (ad-hoc) would make it re-prompt each time. The identity
# is created automatically on the first build; there is no separate setup step and no ad-hoc signing.
# The development bundle also has its own name and bundle id, so it cannot collide with an installed,
# Developer ID-signed Jarvis release in TCC or Launch Services.
#
# Usage:
#   ./scripts/build-app.sh                build + sign (release)
#   ./scripts/build-app.sh debug          build + sign (debug)
#   ./scripts/build-app.sh --run          ...then launch it (per-session logs in the workspace .jarvis/)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
LAUNCH=""            # "" | run
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --run)         LAUNCH="run" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Jarvis Dev"
APP="$APP_NAME.app"
BUNDLE_ID="com.jarvis.coach.dev"
BIN_NAME="JarvisApp"
IDENTITY="Jarvis Dev"

# Create the stable signing identity once, on demand. Self-signed and untrusted (CSSMERR_TP_NOT_TRUSTED
# is expected) — that's fine for local signing; it only needs to be *stable* so TCC grants persist.
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
  # Least privilege: scope the key to /usr/bin/codesign only (NOT -A, which any app could use).
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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
# Sparkle is linked dynamically, so the framework must be embedded even though the development
# bundle has no update feed — without it dyld cannot start the app at all.
ditto "$(dirname "$BIN_PATH")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# SwiftPM emits each resource-bearing target's resources as its own side-by-side bundle — JarvisApp's
# (the Silero VAD model) and JarvisCore's (the interview-format skill Markdown files). Copy both into
# Contents/Resources so `Bundle.module` resolves inside the assembled app, not just from .build.
ditto "$(dirname "$BIN_PATH")/Jarvis_JarvisApp.bundle" \
      "$APP/Contents/Resources/Jarvis_JarvisApp.bundle"
ditto "$(dirname "$BIN_PATH")/Jarvis_JarvisCore.bundle" \
      "$APP/Contents/Resources/Jarvis_JarvisCore.bundle"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Jarvis.icns "$APP/Contents/Resources/Jarvis.icns"
# Resources/Info.plist remains the production source of truth. Override only the identity fields in
# the assembled development bundle so release packaging stays independent and the two variants never
# share TCC grants or Launch Services registration.
/usr/bin/plutil -replace CFBundleName -string "$APP_NAME" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$APP_NAME" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
# A development build is signed with the local "Jarvis Dev" identity, so Sparkle could never install
# the Developer ID release over it anyway. Removing the feed leaves the app with no updater at all,
# and the menu omits "Check for Updates" rather than offering an action that must fail.
/usr/bin/plutil -remove SUFeedURL "$APP/Contents/Info.plist"
# The copied plist carries the version of whichever release this checkout descends from, which would
# misname a local build in the menu's footer caption. Marking the bundle makes that caption read a red
# "Dev" instead, so it is obvious at a glance which variant is running.
/usr/bin/plutil -replace JarvisDevelopmentBuild -bool YES "$APP/Contents/Info.plist"

echo "▶ signing with '$IDENTITY'"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"
echo "✅ built $APP"

# Always launch via `open`, never the bare binary — launching the executable from a terminal makes
# macOS attribute the Mic/Screen-Recording grants to the shell, so they look "denied".
launch() {
  # Replace only a development build. The installed production app has a different bundle path and
  # identity and must be allowed to keep running alongside it.
  /usr/bin/pkill -f "/${APP_NAME}[.]app/Contents/MacOS/$BIN_NAME" 2>/dev/null || true
  sleep 1
}

case "$LAUNCH" in
  run)
    launch
    # Per-session logs go to a gitignored, workspace-local .jarvis/ (passed via --log-dir so the app,
    # launched from anywhere by `open`, writes back into the repo). chmod 700 the base so session-dir
    # names (timestamps) aren't readable by other local users — the app then makes each <session>/
    # 0700 with 0600 files inside (CWE-732).
    LOGDIR="$PWD/.jarvis"
    mkdir -p "$LOGDIR"
    chmod 700 "$LOGDIR"
    echo "▶ launching $APP_NAME — open Settings → Activity to watch the log; per-session logs in $LOGDIR/<session>"
    open ./"$APP" --args --log-dir "$LOGDIR"
    ;;
  "")
    echo "   run: open ./$APP        (or: ./scripts/build-app.sh --run)"
    ;;
esac
