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

dev_script="scripts/build-app.sh"
for required in \
  'APP_NAME="Jarvis Dev"' \
  'APP="$APP_NAME.app"' \
  'BUNDLE_ID="com.jarvis.coach.dev"' \
  '/usr/bin/plutil -replace CFBundleName -string "$APP_NAME" "$APP/Contents/Info.plist"' \
  '/usr/bin/plutil -replace CFBundleDisplayName -string "$APP_NAME" "$APP/Contents/Info.plist"' \
  '/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"'
do
  /usr/bin/grep -Fqx "$required" "$dev_script" \
    || fail "$dev_script must assemble Jarvis Dev.app with its independent bundle identity."
done
/usr/bin/grep -Fqx '    open ./"$APP" --args --log-dir "$LOGDIR"' "$dev_script" \
  || fail "$dev_script must launch the assembled development bundle."

/usr/bin/grep -Fqx 'APP="Jarvis.app"' scripts/package-app.sh \
  || fail "release packaging must continue to assemble Jarvis.app."
/usr/bin/grep -Fqx 'APP="Jarvis.app"' scripts/verify-release.sh \
  || fail "release verification must continue to require Jarvis.app."
/usr/bin/grep -Fqx 'APP="Jarvis Dev.app"' scripts/transcription-benchmark.sh \
  || fail "the developer transcription benchmark must launch Jarvis Dev.app."
/usr/bin/grep -Fqx 'open -W -n "./$APP" --args "${COMMON_ARGS[@]}" &' \
  scripts/transcription-benchmark.sh \
  || fail "the developer transcription benchmark must open its declared development bundle."

echo "App identity guard passed."
