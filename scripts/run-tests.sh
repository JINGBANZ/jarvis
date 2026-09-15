#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-ghost-mode.sh
./scripts/check-coaching-kernel.sh
./scripts/check-audio-capture-config.sh
./scripts/check-app-identities.sh
./scripts/check-release-config.sh

source scripts/lib/swift-test-flags.sh
# The live e2e target launches the signed app against real providers. The Gate compiles it but never
# runs it; scripts/run-live-tests.sh is its one entry point.
exec swift test ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"} --skip JarvisLiveTests "$@"
