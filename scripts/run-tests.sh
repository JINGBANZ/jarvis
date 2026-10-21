#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/test-display.sh

./scripts/check-ghost-mode.sh
./scripts/check-coaching-kernel.sh
./scripts/check-audio-capture-config.sh
./scripts/check-app-identities.sh
./scripts/check-release-config.sh
python3 scripts/test-live-cancellation.py
python3 scripts/test-script-workflows.py
./scripts/test-reference-helper.sh

source scripts/lib/swift-test-flags.sh
mkdir -p .build
# Shared AppKit/WebKit and subprocess tests need isolation from suite-wide contention.
# The live target hits real providers, so only scripts/run-live-tests.sh runs it.
run_swift_tests .build/run-tests.log --no-parallel --skip JarvisLiveTests "$@"
