#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/test-display.sh
build_test_display
exec "$display_runner" --cleanup-profiles "$@"
