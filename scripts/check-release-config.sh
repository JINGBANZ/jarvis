#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

workflow=".github/workflows/release.yml"
release_header=".github/release-header.md"
package_script="scripts/package-app.sh"
verify_script="scripts/verify-release.sh"
sdk_guard="scripts/check-release-sdk.sh"
package_guard_call="./scripts/check-release-sdk.sh \"\$BIN_PATH\""
verify_guard_call="./scripts/check-release-sdk.sh \"\$EXTRACTED_BIN\""

for path in "$workflow" "$release_header" "$package_script" "$verify_script" "$sdk_guard"; do
  if [[ ! -f "$path" || -L "$path" ]]; then
    echo "Release configuration guard: $path must be a regular file." >&2
    exit 1
  fi
done

if ! /usr/bin/grep -Eq '^[[:space:]]*runs-on:[[:space:]]*macos-26[[:space:]]*$' "$workflow"; then
  echo "Release publish job must use the Apple-silicon macos-26 runner." >&2
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
    || ! /usr/bin/grep -Fq 'ln -s /Applications "$DMG_STAGE/Applications"' "$package_script"; then
  echo "Release packaging must create an identified Jarvis.dmg with an Applications shortcut." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'xcrun notarytool submit "$DMG"' "$package_script" \
    || ! /usr/bin/grep -Fq 'xcrun stapler staple "$DMG"' "$package_script"; then
  echo "Release packaging must notarize and staple the final disk image." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT"' \
      "$verify_script" \
    || ! /usr/bin/grep -Fq '"$(readlink "$APPLICATIONS_LINK")" != "/Applications"' \
      "$verify_script" \
    || ! /usr/bin/grep -Fq 'syspolicy_check distribution "$EXTRACTED_APP" --verbose' \
      "$verify_script"; then
  echo "Final release verification must inspect the mounted layout and modern system policy." >&2
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
