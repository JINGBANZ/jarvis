#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-ghost-mode.sh
./scripts/check-coaching-kernel.sh
./scripts/check-audio-capture-config.sh
./scripts/check-app-identities.sh
./scripts/check-release-config.sh

source scripts/lib/swift-test-flags.sh
# The live target hits real providers, so only scripts/run-live-tests.sh runs it.
exec swift test ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"} --skip JarvisLiveTests "$@"
