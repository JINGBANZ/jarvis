#!/usr/bin/env bash
# Build Jarvis Dev.app, then run the JarvisLiveTests target against real providers.
# Prerequisites and cases: wiki/live-e2e-tests.md
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/harness.sh

usage() {
  echo "usage: $0 [A|B|C|D|H|L|P|R|F01|F02|CACHE|REF01|REF02|REF03|REF04|REF05|REF06|REF07|all] [--provider codex-subscription|claude-subscription|openai|gemini|scenario] [--evaluate] [--keep-going]" >&2
}

SCENARIO="all"
EVALUATE=0
KEEP_GOING=0
PROVIDER="codex-subscription"
EVALUATION_AGENT="${EVAL_AGENT:-codex}"
RUN_ARGUMENTS=("$@")
while (( $# > 0 )); do
  case "$1" in
    A|B|C|D|H|L|P|R|F01|F02|CACHE|REF01|REF02|REF03|REF04|REF05|REF06|REF07|all) SCENARIO="$1" ;;
    --provider)
      if (( $# < 2 )); then usage; exit 2; fi
      PROVIDER="$2"
      shift
      ;;
    --provider=*) PROVIDER="${1#--provider=}" ;;
    --evaluate) EVALUATE=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [[ "$SCENARIO" =~ ^REF0[1-7]$ ]]; then
  echo "$SCENARIO uses the deterministic signed References harness (synthetic tool traffic; no provider or capture)."
  exec ./scripts/run-reference-tests.sh "$SCENARIO"
fi
case "$PROVIDER" in
  codex-subscription|claude-subscription|openai|gemini|scenario) ;;
  *) echo "Unknown live e2e provider: $PROVIDER" >&2; usage; exit 2 ;;
esac
if [[ "$EVALUATE" == 1 ]]; then
  case "$EVALUATION_AGENT" in
    codex|claude) ;;
    *) echo "Unknown EVAL_AGENT: $EVALUATION_AGENT (expected codex or claude)" >&2; exit 2 ;;
  esac
fi
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

source scripts/lib/test-display.sh ${RUN_ARGUMENTS[@]+"${RUN_ARGUMENTS[@]}"}

# A full run takes about half an hour; keep the Mac from sleeping through it.
if [[ -z "${JARVIS_LIVE_E2E_CAFFEINATED:-}" ]]; then
  export JARVIS_LIVE_E2E_CAFFEINATED=1
  # Not "$0": the cd above moved to the repository root, where a relative $0 no longer resolves.
  exec /usr/bin/caffeinate -d -i ./scripts/run-live-tests.sh ${RUN_ARGUMENTS[@]+"${RUN_ARGUMENTS[@]}"}
fi

echo "▶ building the signed development app"
./scripts/build-app.sh debug

BASE="$PWD/.jarvis/live-e2e"
RUN_DIR="$(create_run_directory live-e2e)"
# Keep the newest ten runs, the transcription benchmark's cap.
find "$BASE" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -r | tail -n +11 \
  | while IFS= read -r old_run; do
      rm -rf "$old_run"
    done

SKIP_CACHE=()
case "$SCENARIO" in
  all)
    FILTER='JarvisLiveTests\.LiveE2ETests/'
    SKIP_CACHE=(--skip 'JarvisLiveTests\.LiveE2ETests/scenarioCACHE')
    ;;
  *) FILTER="JarvisLiveTests\\.LiveE2ETests/scenario$SCENARIO" ;;
esac

# The script-to-test handshake. The test refuses to run without these two variables.
export JARVIS_LIVE_E2E_RUN_DIR="$RUN_DIR"
export JARVIS_LIVE_E2E_APP="$PWD/Jarvis Dev.app"
export JARVIS_LIVE_E2E_PROVIDER="$PROVIDER"
if [[ "$KEEP_GOING" == 1 ]]; then
  export JARVIS_LIVE_E2E_KEEP_GOING=1
fi

source scripts/lib/live-test-cancellation.sh

source scripts/lib/swift-test-flags.sh
echo "▶ running live e2e scenarios ($SCENARIO, provider $PROVIDER) into $RUN_DIR"
test_status=0
run_swift_tests "$RUN_DIR/swift-test.log" ${SKIP_CACHE[@]+"${SKIP_CACHE[@]}"} --filter "$FILTER" || test_status=$?

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
  elif EVAL_AGENT="$EVALUATION_AGENT" ./scripts/eval-session.sh "$evaluated_session" > "$RUN_DIR/evaluate.log" 2>&1 \
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
