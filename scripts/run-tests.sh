#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-ghost-mode.sh
./scripts/check-coaching-kernel.sh
./scripts/check-audio-capture-config.sh
./scripts/check-app-identities.sh
./scripts/check-release-config.sh

bash scripts/tests/test-test-completion.sh

source scripts/lib/swift-test-flags.sh
source scripts/lib/test-completion.sh
# The live target hits real providers, so only scripts/run-live-tests.sh runs it.
test_log="$(mktemp)"
trap 'rm -f "$test_log"' EXIT
set +e
swift test ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"} --skip JarvisLiveTests "$@" 2>&1 | tee "$test_log"
statuses=("${PIPESTATUS[@]}")
set -e
check_swift_test_completion "$test_log" "${statuses[0]}"
exit "${statuses[1]}"
