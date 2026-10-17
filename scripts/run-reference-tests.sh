#!/usr/bin/env bash
# Signed Swift Process/pipe contracts; synthetic data, no provider calls or capture permission.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/test-display.sh
EXPECTED_CASES=33
EXTRA_ARGS=()
if [[ "${1:-}" == --quit-only ]]; then
  EXPECTED_CASES=1
  EXTRA_ARGS+=(--reference-harness-quit-only)
elif (( $# > 0 )); then
  echo "usage: $0 [--quit-only]" >&2
  exit 2
fi
./scripts/build-app.sh debug
BASE="$PWD/.jarvis/reference-harness"
[[ ! -L "$PWD/.jarvis" && ! -L "$BASE" ]] || exit 1
mkdir -p "$BASE"
chmod 700 "$PWD/.jarvis" "$BASE"
RUN_DIR="$BASE/$(date '+%Y-%m-%d_%H-%M-%S')-$$"
mkdir -m 700 "$RUN_DIR"
POLLUTION="$RUN_DIR/pollution"
mkdir -p "$POLLUTION/cwd"
printf '#!/bin/sh\n: > "%s"\nexit 99\n' "$RUN_DIR/hostile-helper-executed" > "$POLLUTION/cwd/JarvisReferenceHelper"
chmod 700 "$POLLUTION/cwd/JarvisReferenceHelper"
python3 scripts/reference-helper/generate-fixtures.py "$RUN_DIR/formats"
codesign --verify --deep --strict 'Jarvis Dev.app'
cleanup() {
  python3 - "$RUN_DIR" "$PWD/Jarvis Dev.app" "$EXPECTED_CASES" <<'PY_CLEANUP'
import os, signal, subprocess, sys, time
from pathlib import Path
root, app = map(Path, sys.argv[1:3])
app_command = str(app / 'Contents/MacOS/JarvisApp') + ' --reference-harness --reference-harness-output ' + str(root)
if sys.argv[3] == '1': app_command += ' --reference-harness-quit-only'
helper = app / 'Contents/Resources/ReferenceHelper'
prefixes = [str(helper / 'JarvisReferenceHelper') + ' ' + str(root) + '/']
def owned():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
    result = []
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == app_command or any(parts[1].startswith(p) for p in prefixes)):
            result.append(int(parts[0]))
    return result
for pid in owned():
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
deadline = time.monotonic() + 2
while owned() and time.monotonic() < deadline: time.sleep(.05)
for pid in owned():
    try: os.kill(pid, signal.SIGKILL)
    except ProcessLookupError: pass
PY_CLEANUP
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
open -n -g --env "HOME=$POLLUTION" --env "PATH=$POLLUTION/cwd" --env "PYTHONPATH=$POLLUTION/cwd" \
  --env "HTTPS_PROXY=http://127.0.0.1:1" \
  --env "OPENAI_API_KEY=synthetic-secret-canary" --env "GEMINI_API_KEY=synthetic-secret-canary" \
  --stdout "$RUN_DIR/stdout.log" --stderr "$RUN_DIR/stderr.log" \
  "$PWD/Jarvis Dev.app" --args --reference-harness --reference-harness-output "$RUN_DIR" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
deadline=$((SECONDS + 360))
while [[ ! -f "$RUN_DIR/results.json" ]]; do
  if (( SECONDS >= deadline )); then
    echo "Reference harness timed out: $RUN_DIR" >&2
    exit 1
  fi
  sleep 0.2
done
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
echo "Reference harness passed: $RUN_DIR/results.json"
