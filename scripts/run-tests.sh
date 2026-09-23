#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-ghost-mode.sh
./scripts/check-coaching-kernel.sh
./scripts/check-audio-capture-config.sh
./scripts/check-app-identities.sh
./scripts/check-release-config.sh

source scripts/lib/swift-test-flags.sh
mkdir -p .build
log=.build/run-tests.log
# The live target hits real providers, so only scripts/run-live-tests.sh runs it.
set +e
swift test ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"} --skip JarvisLiveTests "$@" 2>&1 | tee "$log"
test_status=${PIPESTATUS[0]}
set -e
if (( test_status != 0 )); then
  exit "$test_status"
fi
# A test that stops the main run loop ends swift-testing's runner with exit 0 before this summary.
if ! grep -q 'Test run with [0-9]* test' "$log"; then
  echo "❌ swift test exited 0 without swift-testing's 'Test run with N tests' summary; a test ended the run early." >&2
  exit 1
fi
