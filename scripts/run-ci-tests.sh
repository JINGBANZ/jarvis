#!/usr/bin/env bash
# Explicit workflow policy: shared admission, hosted desktop, no virtual-display persistence proof.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/test-display/supervisor.py hosted-ci run-tests.sh "$@"
