#!/usr/bin/env bash
# Dev run: (re)build the signed .app, then launch it in dev mode via LaunchServices.
#
# Launching with `open` (not the bare binary) is REQUIRED so macOS attributes the Microphone /
# Screen Recording grants to Jarvis itself — running the executable from a terminal makes TCC
# attribute them to the shell, which always looks "denied". `--args --dev` turns on the live
# activity viewer, which auto-opens an HTML page in your browser for this session.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh release

# Replace any running instance so the new build (and a fresh session) takes over.
pkill -f "Jarvis.app/Contents/MacOS/JarvisApp" 2>/dev/null || true
sleep 1

echo "▶ launching Jarvis (dev mode) — activity viewer will open in your browser"
open ./Jarvis.app --args --dev
