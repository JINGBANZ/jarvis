#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/reference-helper.sh
prepare_reference_helper
.build/reference-helper/python/bin/python3 -I -B scripts/reference-helper/test_helper.py
