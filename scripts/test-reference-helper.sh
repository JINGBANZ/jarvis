#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --jobs 2 --product JarvisReferenceHelper
binary="$(swift build --show-bin-path)/JarvisReferenceHelper"
# Python drives the host-side wire contracts only; it is never bundled or launched by the app.
/usr/bin/python3 -I -B scripts/reference-helper/test_helper.py "$binary"
