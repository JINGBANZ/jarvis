#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "App identity guard: $1" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" Resources/Info.plist 2>/dev/null
}

[[ "$(plist_value CFBundleName)" == "Jarvis" ]] \
  || fail "Resources/Info.plist must keep the production name Jarvis."
[[ "$(plist_value CFBundleDisplayName)" == "Jarvis" ]] \
  || fail "Resources/Info.plist must keep the production display name Jarvis."
[[ "$(plist_value CFBundleIdentifier)" == "com.jarvis.coach" ]] \
  || fail "Resources/Info.plist must keep the production bundle id com.jarvis.coach."

# Exact, not a glob: `*` matches `/` in a bash pattern, so a wildcard would accept any account's feed.
[[ "$(plist_value SUFeedURL)" \
   == "https://github.com/JINGBANZ/jarvis/releases/latest/download/appcast.xml" ]] \
  || fail "Resources/Info.plist must point Sparkle at the published appcast asset."
[[ "$(plist_value SUEnableAutomaticChecks)" == "false" ]] \
  || fail "Sparkle must never schedule its own checks or prompt to enable them."
[[ "$(plist_value SUPublicEDKey)" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "Resources/Info.plist must carry a real base64 Ed25519 SUPublicEDKey."

/usr/bin/grep -Fqx '    open ./"$APP"' scripts/build-app.sh \
  || fail "the development command must launch the assembled bundle through Launch Services."
/usr/bin/grep -Fqx 'APP="Jarvis.app"' scripts/package-app.sh \
  || fail "release packaging must continue to assemble Jarvis.app."
/usr/bin/grep -Fqx 'APP="Jarvis.app"' scripts/verify-release.sh \
  || fail "release verification must continue to require Jarvis.app."
echo "App identity guard passed."
