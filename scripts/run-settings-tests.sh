#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/harness.sh
source scripts/lib/test-display.sh
isolate_test_display "$@"
./scripts/build-app.sh debug
run_dir="$(create_run_directory settings-harness)"
app_path="$PWD/Jarvis Dev.app"
cleanup() {
  python3 - "$app_path/Contents/MacOS/JarvisApp" "$run_dir" <<'PY'
import os, signal, subprocess, sys
command = sys.argv[1] + ' --settings-harness --settings-harness-output ' + sys.argv[2]
for row in subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True).splitlines():
    parts = row.strip().split(None, 1)
    if len(parts) == 2 and (parts[1] == command or parts[1] == command + ' --settings-harness-relaunch'):
        try: os.kill(int(parts[0]), signal.SIGTERM)
        except ProcessLookupError: pass
PY
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
for phase in initial relaunch; do
  args=()
  if [[ "$phase" == relaunch ]]; then args+=(--settings-harness-relaunch); fi
  open -n -g --stdout "$run_dir/$phase.stdout.log" --stderr "$run_dir/$phase.stderr.log" \
    "$app_path" --args --settings-harness --settings-harness-output "$run_dir" ${args[@]+"${args[@]}"}
  wait_for_file "$run_dir/$phase.json" 40 "Settings harness" 0.1
  python3 - "$run_dir/$phase.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream: result = json.load(stream)
print(sys.argv[1] + ': ' + result['status'])
assert result['status'] == 'passed', result
PY
done
echo "Signed Settings checks passed: $run_dir"
