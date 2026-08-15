#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

workflow=".github/workflows/release.yml"
package_script="scripts/package-app.sh"
verify_script="scripts/verify-release.sh"
sdk_guard="scripts/check-release-sdk.sh"
package_guard_call="./scripts/check-release-sdk.sh \"\$BIN_PATH\""
verify_guard_call="./scripts/check-release-sdk.sh \"\$EXTRACTED_BIN\""

for path in "$workflow" "$package_script" "$verify_script" "$sdk_guard"; do
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

echo "Release configuration guard passed."
