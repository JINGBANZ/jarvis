#!/usr/bin/env bash
set -euo pipefail

APP="${1:-}"
if [[ $# -ne 1 || ! -d "$APP" ]]; then
  echo "usage: $0 /path/to/Jarvis.app" >&2
  exit 2
fi

for binary in \
  Contents/MacOS/JarvisApp \
  Contents/MacOS/cliproxyapi \
  Contents/Resources/ReferenceHelper/JarvisReferenceHelper \
  Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle \
  Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate \
  Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app/Contents/MacOS/Updater; do
  for architecture in arm64 x86_64; do
    if [[ ! -f "$APP/$binary" ]] || ! lipo "$APP/$binary" -verify_arch "$architecture"; then
      echo "error: $binary must contain both arm64 and x86_64" >&2
      exit 1
    fi
  done
done
echo "Universal app guard passed: app, helpers, and updater contain arm64 and x86_64."
