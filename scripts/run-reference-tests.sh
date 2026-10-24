#!/usr/bin/env bash
# Signed Swift Process/pipe contracts; synthetic data, no provider calls or capture permission.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/harness.sh
source scripts/lib/test-display.sh
EXPECTED_CASES=41
EXTRA_ARGS=()
if [[ "${1:-}" == --quit-only ]]; then
  EXPECTED_CASES=1
  EXTRA_ARGS+=(--reference-harness-quit-only)
elif [[ "${1:-}" =~ ^REF0[1-7]$ ]]; then
  EXPECTED_CASES=2
  EXTRA_ARGS+=(--reference-harness-case "$1")
elif (( $# > 0 )); then
  echo "usage: $0 [REF01|REF02|REF03|REF04|REF05|REF06|REF07|--quit-only]" >&2
  exit 2
fi
isolate_test_display "$@"
./scripts/build-app.sh debug
RUN_DIR="$(create_run_directory reference-harness)"
POLLUTION="$RUN_DIR/pollution"
mkdir -p "$POLLUTION/cwd"
printf '#!/bin/sh\n: > "%s"\nexit 99\n' "$RUN_DIR/hostile-helper-executed" > "$POLLUTION/cwd/JarvisReferenceHelper"
chmod 700 "$POLLUTION/cwd/JarvisReferenceHelper"
python3 scripts/reference-helper/generate-fixtures.py "$RUN_DIR/formats"
codesign --verify --deep --strict 'Jarvis Dev.app'
trap stop_test_app EXIT
trap 'exit 130' HUP INT TERM
launch_test_app --env "HOME=$POLLUTION" --env "PATH=$POLLUTION/cwd" --env "PYTHONPATH=$POLLUTION/cwd" \
  --env "HTTPS_PROXY=http://127.0.0.1:1" \
  --env "OPENAI_API_KEY=synthetic-secret-canary" --env "GEMINI_API_KEY=synthetic-secret-canary" \
  --stdout "$RUN_DIR/stdout.log" --stderr "$RUN_DIR/stderr.log" \
  "$PWD/Jarvis Dev.app" --args --reference-harness --reference-harness-output "$RUN_DIR" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} &
app_waiter=$!
wait_for_file "$RUN_DIR/results.json" 600 "Reference harness"
python3 - "$RUN_DIR/results.json" "$EXPECTED_CASES" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
print(json.dumps(report, indent=2))
assert report['status'] == 'passed', report
assert len(report['cases']) == int(sys.argv[2]), report
import os, time
from pathlib import Path
root = Path(sys.argv[1]).parent
pids = [int((root / 'app.pid').read_text()), report['cases'][-1]['helper_pid']]
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    alive = []
    for pid in pids:
        try: os.kill(pid, 0); alive.append(pid)
        except ProcessLookupError: pass
    if not alive and (root / 'quit-finished').exists(): break
    time.sleep(.05)
else: raise AssertionError(('Quit failed to reap app/helper', alive))
PY
wait "$app_waiter"
echo "Reference harness passed: $RUN_DIR/results.json"
