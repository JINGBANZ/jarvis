#!/usr/bin/env bash
# Synthetic signed-app SCStream check; never writes captured frames.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

if (( $# > 1 )); then
  echo "usage: $0 [hold-seconds: 1...30]" >&2
  exit 2
fi
HOLD_SECONDS="${1:-1}"
if ! [[ "$HOLD_SECONDS" =~ ^([1-9]|[12][0-9]|30)$ ]]; then
  echo "hold-seconds must be an integer from 1 through 30" >&2
  exit 2
fi
if /usr/bin/pgrep -f '/Jarvis Dev[.]app/Contents/MacOS/JarvisApp' >/dev/null; then
  echo "Quit Jarvis Dev.app before running the capture privacy check." >&2
  exit 1
fi
./scripts/build-app.sh debug

BASE="$PWD/.jarvis/capture-privacy"
if [[ -L "$PWD/.jarvis" || -L "$BASE" ]]; then
  echo "Refusing a symlinked capture-privacy directory." >&2
  exit 1
fi
mkdir -p "$BASE"
chmod 700 "$PWD/.jarvis" "$BASE"
RUN_DIR="$BASE/$(date '+%Y-%m-%d_%H-%M-%S')-$$"
mkdir -m 700 "$RUN_DIR"
git rev-parse HEAD > "$RUN_DIR/source-commit.txt"
git status --porcelain > "$RUN_DIR/source-status.txt"
codesign --verify --deep --strict 'Jarvis Dev.app'
codesign -dv 'Jarvis Dev.app' 2> "$RUN_DIR/signature.txt"

APP_PATH="$PWD/Jarvis Dev.app/Contents/MacOS/JarvisApp"
stop_test_app() {
  # Only this workspace's explicit test instance; never another checkout's app.
  /usr/bin/pgrep -f '/Jarvis Dev[.]app/Contents/MacOS/JarvisApp' | while read -r pid; do
    if [[ "$(ps -p "$pid" -o command=)" == "$APP_PATH --capture-privacy "* ]]; then
      kill "$pid"
    fi
  done || true
}
trap stop_test_app EXIT
trap 'exit 130' INT TERM
open -n "$PWD/Jarvis Dev.app" --args --capture-privacy \
  --capture-privacy-output-dir "$RUN_DIR" --capture-privacy-hold-seconds "$HOLD_SECONDS"
deadline=$((SECONDS + 60 + 12 * HOLD_SECONDS))
while [[ ! -f "$RUN_DIR/finished" ]]; do
  if (( SECONDS >= deadline )); then
    echo "Capture privacy check timed out: $RUN_DIR" >&2
    exit 1
  fi
  sleep 0.2
done
python3 - "$RUN_DIR/results.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    report = json.load(source)
print(json.dumps(report, indent=2))
if report["status"] != "passed" or len(report["phases"]) != 11:
    sys.exit(1)
PY
echo "Capture privacy check passed: $RUN_DIR/results.json"
