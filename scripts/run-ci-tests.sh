#!/usr/bin/env bash
# Explicit workflow policy: shared admission, hosted desktop, no virtual-display persistence proof.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/test-configuration.sh
require_debug_test_configuration "$@"
exec python3 scripts/test-display/supervisor.py hosted-ci run-tests.sh "$@"
