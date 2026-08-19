#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-ghost-mode.sh
./scripts/check-audio-capture-config.sh
./scripts/check-app-identities.sh
./scripts/check-release-config.sh

# `ActivityLog.shared` is a process-wide singleton that the coach records through, so a test that
# enables it captures rows from every other test running at that moment: suites execute in parallel
# by default, and swift-testing's `.serialized` only orders tests within one suite. Running the
# whole suite serially is what makes each test see only its own activity. Roughly doubles the
# wall-clock time, which the gate can afford; the alternative is injecting the log through every
# call site that records to it.
PARALLELISM=(--no-parallel)

# On a Command-Line-Tools-only machine, swift-testing ships with the CLT but isn't on the default
# search path, so we point swift at it explicitly. With full Xcode active (e.g. CI runners) it's
# already on the toolchain path, so plain `swift test` works — detect which toolchain is active.
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  IOP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  exec swift test \
    "${PARALLELISM[@]}" \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$IOP" \
    "$@"
else
  exec swift test "${PARALLELISM[@]}" "$@"
fi
