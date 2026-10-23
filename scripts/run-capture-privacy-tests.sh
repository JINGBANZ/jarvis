#!/usr/bin/env bash
# Synthetic signed-app SCStream check; never writes captured frames.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/harness.sh
source scripts/lib/test-display.sh
isolate_test_display "$@"

if (( $# > 1 )); then
  echo "usage: $0 [hold-seconds: 1...30]" >&2
  exit 2
fi
HOLD_SECONDS="${1:-1}"
if ! [[ "$HOLD_SECONDS" =~ ^([1-9]|[12][0-9]|30)$ ]]; then
  echo "hold-seconds must be an integer from 1 through 30" >&2
  exit 2
fi
./scripts/build-app.sh debug

RUN_DIR="$(create_run_directory capture-privacy)"
git rev-parse HEAD > "$RUN_DIR/source-commit.txt"
git status --porcelain > "$RUN_DIR/source-status.txt"
codesign --verify --deep --strict 'Jarvis Dev.app'
codesign -dv 'Jarvis Dev.app' 2> "$RUN_DIR/signature.txt"

trap stop_test_app EXIT
trap 'exit 130' HUP INT TERM
launch_test_app "$PWD/Jarvis Dev.app" --args --capture-privacy \
  --capture-privacy-output-dir "$RUN_DIR" --capture-privacy-hold-seconds "$HOLD_SECONDS" &
app_waiter=$!
wait_for_file "$RUN_DIR/finished" "$((60 + 12 * HOLD_SECONDS))" "Capture privacy check"
python3 - "$RUN_DIR/results.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    report = json.load(source)
print(json.dumps(report, indent=2))
if report["status"] != "passed" or len(report["phases"]) != 11:
    sys.exit(1)
PY
wait "$app_waiter"
echo "Capture privacy check passed: $RUN_DIR/results.json"
