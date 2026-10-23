#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug --jobs 2 --product JarvisReferenceHelper
binary="$(swift build -c debug --show-bin-path)/JarvisReferenceHelper"
# Python drives the host-side wire contracts only; it is never bundled or launched by the app.
/usr/bin/python3 -I -B scripts/reference-helper/run-tests.py "$binary"
