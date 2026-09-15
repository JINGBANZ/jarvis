#!/usr/bin/env bash
# Live e2e tests: build Jarvis Dev.app, then run the JarvisLiveTests target, which launches the app
# once per scenario in its live e2e mode against real providers and asserts every case on the session
# folder the app leaves. See wiki/live-e2e-tests.md for prerequisites and what the run covers.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

usage() {
  echo "usage: $0 [A|B|R|F01|F02|all] [--evaluate] [--keep-going]" >&2
}

SCENARIO="all"
EVALUATE=0
KEEP_GOING=0
for arg in "$@"; do
  case "$arg" in
    A|B|R|F01|F02|all) SCENARIO="$arg" ;;
    --evaluate) EVALUATE=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    *) usage; exit 2 ;;
  esac
done
# Evaluation reads Scenario A's session, so a run without A could only report G09 as failed.
if [[ "$EVALUATE" == 1 && "$SCENARIO" != A && "$SCENARIO" != all ]]; then
  echo "--evaluate needs Scenario A: run A or all." >&2
  exit 2
fi

# Two live instances would contend for the capture device and the session folder.
APP_PROCESS_PATTERN="/Jarvis Dev[.]app/Contents/MacOS/JarvisApp"
if /usr/bin/pgrep -f "$APP_PROCESS_PATTERN" >/dev/null; then
  echo "Quit the running Jarvis Dev.app before a live e2e run." >&2
  exit 1
fi

# A full run takes about half an hour; keep the Mac from sleeping through it.
if [[ -z "${JARVIS_LIVE_E2E_CAFFEINATED:-}" ]]; then
  export JARVIS_LIVE_E2E_CAFFEINATED=1
  # Not "$0": the cd above moved to the repository root, where a relative $0 no longer resolves.
  exec /usr/bin/caffeinate -d -i ./scripts/run-live-tests.sh "$@"
fi

echo "▶ building the signed development app"
./scripts/build-app.sh debug

BASE="$PWD/.jarvis/live-e2e"
if [[ -L "$PWD/.jarvis" || -L "$BASE" ]]; then
  echo "Refusing a symlinked live e2e directory; use the workspace-local .jarvis tree." >&2
  exit 1
fi
mkdir -p "$BASE"
chmod 700 "$PWD/.jarvis" "$BASE"
RUN_DIR="$BASE/$(date '+%Y-%m-%d_%H-%M-%S')-$$"
mkdir "$RUN_DIR"
chmod 700 "$RUN_DIR"
# Keep the newest ten runs, the transcription benchmark's cap.
find "$BASE" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -r | tail -n +11 \
  | while IFS= read -r old_run; do
      rm -rf "$old_run"
    done

case "$SCENARIO" in
  all) FILTER='JarvisLiveTests\.LiveE2ETests/' ;;
  *) FILTER="JarvisLiveTests\\.LiveE2ETests/scenario$SCENARIO" ;;
esac

# The script-to-test handshake. The test refuses to run without these two variables.
export JARVIS_LIVE_E2E_RUN_DIR="$RUN_DIR"
export JARVIS_LIVE_E2E_APP="$PWD/Jarvis Dev.app"
if [[ "$KEEP_GOING" == 1 ]]; then
  export JARVIS_LIVE_E2E_KEEP_GOING=1
fi

abort_run() {
  trap - INT TERM
  # The running scenario's app polls for this marker and stops its session so the evidence seals.
  for scenario_dir in "$RUN_DIR"/*/; do
    if [[ -f "$scenario_dir/scenario.json" && ! -f "$scenario_dir/live-e2e-finished" ]]; then
      touch "$scenario_dir/abort"
    fi
  done
  # LaunchServices started the app outside this process group, so the signal never reached it. Give
  # it the launcher's ten seconds to seal its session, then kill it so capture cannot outlive the run.
  for _ in {1..50}; do
    /usr/bin/pgrep -f "$APP_PROCESS_PATTERN" >/dev/null || break
    sleep 0.2
  done
  /usr/bin/pkill -f "$APP_PROCESS_PATTERN" || true
  echo "Live e2e run aborted; partial results are in $RUN_DIR." >&2
  exit 130
}
trap abort_run INT TERM

source scripts/lib/swift-test-flags.sh
echo "▶ running live e2e scenarios ($SCENARIO) into $RUN_DIR"
set +e
swift test ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"} --filter "$FILTER" 2>&1 \
  | tee "$RUN_DIR/swift-test.log"
test_status=${PIPESTATUS[0]}
set -e

{
  for scenario_results in "$RUN_DIR"/*/results.txt; do
    if [[ -f "$scenario_results" ]]; then
      cat "$scenario_results"
    fi
  done
  echo "G07 skipped offline"
  echo "G10 skipped dropped"
  echo "C21 skipped optional"
  for manual_case in F03 R01 R02 S01; do
    echo "$manual_case skipped manual"
  done
} | LC_ALL=C sort -s -k1,1 > "$RUN_DIR/results.txt"

if [[ "$EVALUATE" == 1 ]]; then
  session_count=0
  evaluated_session=""
  for session in "$RUN_DIR"/A/session/*/; do
    if [[ -d "$session" ]]; then
      session_count=$((session_count + 1))
      evaluated_session="$session"
    fi
  done
  if [[ "$session_count" -ne 1 ]]; then
    echo "G09 fail Scenario A did not leave exactly one session" >> "$RUN_DIR/results.txt"
  # Claude Code, not the default Codex-first choice: the evaluation is the run's largest agent spend,
  # and the ChatGPT plan's usage limit is the one a day of runs exhausts.
  elif EVAL_AGENT=claude ./scripts/eval-session.sh "$evaluated_session" > "$RUN_DIR/evaluate.log" 2>&1 \
      && grep -q '^## Summary' "${evaluated_session}eval-report.md" \
      && grep -q '^## Findings' "${evaluated_session}eval-report.md" \
      && grep -q '^## Evidence gaps' "${evaluated_session}eval-report.md" \
      && grep -q '^## Recommendations' "${evaluated_session}eval-report.md"; then
    echo "G09 pass" >> "$RUN_DIR/results.txt"
  else
    echo "G09 fail see evaluate.log" >> "$RUN_DIR/results.txt"
  fi
fi

echo
cat "$RUN_DIR/results.txt"
fail_lines="$(awk '$2 == "fail"' "$RUN_DIR/results.txt" | wc -l | tr -d ' ')"
missing_markers=0
for scenario_dir in "$RUN_DIR"/*/; do
  if [[ -f "$scenario_dir/scenario.json" && ! -f "$scenario_dir/live-e2e-finished" ]]; then
    echo "missing live-e2e-finished: $scenario_dir" >&2
    missing_markers=$((missing_markers + 1))
  fi
done
if (( fail_lines > 0 || missing_markers > 0 || test_status != 0 )); then
  echo "❌ live e2e run failed: $fail_lines fail lines, $missing_markers missing markers, swift test exit $test_status ($RUN_DIR)" >&2
  exit 1
fi
echo "✅ live e2e run passed: $RUN_DIR/results.txt"
