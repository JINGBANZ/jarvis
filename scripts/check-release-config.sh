#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

workflow=".github/workflows/release.yml"
ci_workflow=".github/workflows/ci.yml"
release_header=".github/release-header.md"
package_script="scripts/package-app.sh"
verify_script="scripts/verify-release.sh"
sdk_guard="scripts/check-release-sdk.sh"
dmg_settings="scripts/dmg-settings.py"
dmg_layout_guard="scripts/verify-dmg-layout.py"
release_requirements="scripts/requirements-release.txt"
package_guard_call="./scripts/check-release-sdk.sh \"\$BIN_PATH\""
verify_guard_call="./scripts/check-release-sdk.sh \"\$EXTRACTED_BIN\""

for path in "$workflow" "$ci_workflow" "$release_header" "$package_script" "$verify_script" \
    "$sdk_guard" "$dmg_settings" "$dmg_layout_guard" "$release_requirements"; do
  if [[ ! -f "$path" || -L "$path" ]]; then
    echo "Release configuration guard: $path must be a regular file." >&2
    exit 1
  fi
done

if ! /usr/bin/grep -Eq '^[[:space:]]*runs-on:[[:space:]]*macos-26[[:space:]]*$' "$workflow"; then
  echo "Release publish job must use the Apple-silicon macos-26 runner." >&2
  exit 1
fi
if ! /usr/bin/grep -Eq '^[[:space:]]*environment:[[:space:]]*release[[:space:]]*$' "$workflow"; then
  echo "Release publish job must bind the environment-scoped signing secrets." >&2
  exit 1
fi
for checkout_workflow in "$workflow" "$ci_workflow"; do
  if ! /usr/bin/grep -Eq \
      '^[[:space:]]*-[[:space:]]*uses:[[:space:]]*actions/checkout@[0-9a-f]{40}[[:space:]]*#[[:space:]]*v([5-9]|[1-9][0-9]+)\.' \
      "$checkout_workflow"; then
    echo "$checkout_workflow must pin a Node 24-based actions/checkout release (v5+)." >&2
    exit 1
  fi
done
if ! /usr/bin/grep -Eq '^[[:space:]]*timeout-minutes:[[:space:]]*75[[:space:]]*$' "$workflow"; then
  echo "Release publish timeout must cover both bounded notarization waits." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq "$package_guard_call" "$package_script"; then
  echo "Release packaging must reject a pre-macOS-26 SDK before signing and notarization." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq "$verify_guard_call" "$verify_script"; then
  echo "Final release verification must inspect the SDK linked into the extracted app." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'readonly MINIMUM_SDK_MAJOR=26' "$sdk_guard"; then
  echo "Release SDK guard must require macOS SDK 26 or newer." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'DMG="Jarvis.dmg"' "$package_script" \
    || ! /usr/bin/grep -Fq 'DMG_IDENTIFIER="com.jarvis.coach.dmg"' "$package_script" \
    || ! /usr/bin/grep -Fq 'codesign --force --timestamp --identifier "$DMG_IDENTIFIER" --sign "$IDENTITY" "$DMG"' \
      "$package_script" \
    || ! /usr/bin/grep -Fq 'EXPECTED_DMGBUILD_VERSION="1.6.7"' "$package_script" \
    || ! /usr/bin/grep -Fq '"$DMGBUILD_PYTHON" -m dmgbuild' "$package_script" \
    || ! /usr/bin/grep -Fq -- '--settings scripts/dmg-settings.py' "$package_script"; then
  echo "Release packaging must create an identified Jarvis.dmg with the pinned layout tool." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'symlinks = {"Applications": "/Applications"}' "$dmg_settings" \
    || ! /usr/bin/grep -Fq 'background = "builtin-arrow"' "$dmg_settings" \
    || ! /usr/bin/grep -Fq 'window_rect = ((100, 100), (640, 280))' "$dmg_settings" \
    || ! /usr/bin/grep -Fq 'APP_NAME: (140, 120)' "$dmg_settings" \
    || ! /usr/bin/grep -Fq '"Applications": (500, 120)' "$dmg_settings"; then
  echo "Release DMG settings must preserve the reviewed arrow-and-drop-target layout." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq -- '--only-binary=:all:' "$release_requirements" \
    || ! /usr/bin/grep -Fq 'dmgbuild==1.6.7' "$release_requirements" \
    || ! /usr/bin/grep -Fq -- '--require-hashes' "$workflow" \
    || ! /usr/bin/grep -Fq -- '--requirement scripts/requirements-release.txt' "$workflow" \
    || ! /usr/bin/grep -Fq 'DMGBUILD_PYTHON=$RELEASE_TOOLS/bin/python' "$workflow"; then
  echo "Release workflow must install the hash-pinned DMG layout tool in its own environment." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'xcrun notarytool submit "$artifact"' "$package_script"; then
  echo "Release packaging must submit each distribution layer through the shared notarization path." >&2
  exit 1
fi
package_flow=(
  'ditto -c -k --keepParent "$APP" "$APP_NOTARY_ARCHIVE"'
  'notarize_artifact "$APP_NOTARY_ARCHIVE" "application"'
  'xcrun stapler staple "$APP"'
  'ditto "$APP" "$DMG_STAGE/$APP"'
  '"$DMGBUILD_PYTHON" -m dmgbuild'
  'notarize_artifact "$DMG" "disk image"'
  'xcrun stapler staple "$DMG"'
  './scripts/verify-release.sh "${verify_args[@]}"'
)
previous_flow_line=0
for flow_step in "${package_flow[@]}"; do
  if ! flow_match="$(/usr/bin/grep -nF -m 1 -- "$flow_step" "$package_script")"; then
    echo "Release packaging is missing required step: $flow_step" >&2
    exit 1
  fi
  flow_line="${flow_match%%:*}"
  if (( flow_line <= previous_flow_line )); then
    echo "Release packaging step is out of order: $flow_step" >&2
    exit 1
  fi
  previous_flow_line="$flow_line"
done
if ! /usr/bin/grep -Fq 'hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT"' \
      "$verify_script" \
    || ! /usr/bin/grep -Fq '"$(readlink "$APPLICATIONS_LINK")" != "/Applications"' \
      "$verify_script" \
    || ! /usr/bin/grep -Fq '"$DMGBUILD_PYTHON" scripts/verify-dmg-layout.py "$MOUNT_POINT"' \
      "$verify_script" \
    || ! /usr/bin/grep -Fq 'syspolicy_check distribution "$EXTRACTED_APP" --verbose' \
      "$verify_script"; then
  echo "Final release verification must inspect the mounted Finder layout and modern system policy." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'ASSET="Jarvis.dmg"' "$workflow" \
    || ! /usr/bin/grep -Fq 'UNEXPECTED_ASSETS="$(awk -v expected="$ASSET"' \
      "$workflow" \
    || ! /usr/bin/grep -Fq 'for asset in "$ASSET"; do' "$workflow"; then
  echo "Release publication must upload only the stable Jarvis.dmg app artifact." >&2
  exit 1
fi
if /usr/bin/grep -Fq 'SHA256SUMS' "$workflow" \
    || /usr/bin/grep -Fq 'Jarvis-*.zip' "$workflow"; then
  echo "Release publication must not add legacy zip or checksum assets." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq '@JARVIS_DOWNLOAD_URL@' "$release_header" \
    || ! /usr/bin/grep -Fq 'drag `Jarvis.app` onto the **Applications** shortcut' "$release_header"; then
  echo "Release install notes must link directly to the disk image and explain the drag install." >&2
  exit 1
fi

echo "Release configuration guard passed."
