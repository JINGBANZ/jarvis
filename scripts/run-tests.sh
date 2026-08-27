#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-ghost-mode.sh
./scripts/check-coaching-kernel.sh
./scripts/check-audio-capture-config.sh
./scripts/check-app-identities.sh
./scripts/check-release-config.sh

# On a Command-Line-Tools-only machine, swift-testing ships with the CLT but isn't on the default
# search path, so we point swift at it explicitly. With full Xcode active (e.g. CI runners) it's
# already on the toolchain path, so plain `swift test` works — detect which toolchain is active.
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  IOP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$IOP" \
    "$@"
else
  exec swift test "$@"
fi
