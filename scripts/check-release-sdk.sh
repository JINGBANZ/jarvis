#!/usr/bin/env bash
set -euo pipefail

BINARY="${1:-}"
if [[ $# -ne 1 || -z "$BINARY" || ! -f "$BINARY" || -L "$BINARY" ]]; then
  echo "usage: $0 /path/to/JarvisApp" >&2
  exit 2
fi

readonly MINIMUM_SDK_MAJOR=26
SDK_VERSION="$(
  /usr/bin/otool -l "$BINARY" \
    | /usr/bin/awk '
        $1 == "cmd" { in_build_version = ($2 == "LC_BUILD_VERSION"); next }
        in_build_version && $1 == "platform" { platform = $2; next }
        in_build_version && platform == "1" && $1 == "sdk" && sdk == "" { sdk = $2 }
        END { if (sdk != "") print sdk }
      '
)"

if [[ ! "$SDK_VERSION" =~ ^([0-9]+)(\.[0-9]+){1,2}$ ]]; then
  echo "error: couldn't read a macOS SDK version from $BINARY" >&2
  exit 1
fi
SDK_MAJOR="${BASH_REMATCH[1]}"
if (( SDK_MAJOR < MINIMUM_SDK_MAJOR )); then
  echo "error: $BINARY was built with macOS SDK $SDK_VERSION; SDK $MINIMUM_SDK_MAJOR or newer is required" >&2
  exit 1
fi

echo "Release SDK guard passed: macOS SDK $SDK_VERSION"
