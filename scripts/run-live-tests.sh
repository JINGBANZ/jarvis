#!/usr/bin/env bash
# Build Jarvis Dev.app, then run the JarvisLiveTests target against real providers.
# Prerequisites and cases: wiki/live-e2e-tests.md
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/lib/harness.sh
source scripts/lib/test-display.sh

usage() {
  echo "usage: $0 [A|B|C|D|H|L|P|R|F01|F02|CACHE|REF01|REF02|REF03|REF04|REF05|REF06|REF07|all] [--provider codex-subscription|claude-subscription|openai|gemini|scenario] [--evaluate] [--keep-going] [--list] [--suite coaching/intervention|app/coaching] [--repeat N]" >&2
}

create_live_run_directory() {
  local base="$PWD/.jarvis/live-e2e" directory
  directory="$(create_run_directory live-e2e)" || return "$?"
  # Keep the newest ten runs, the transcription benchmark's cap.
  find "$base" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -r | tail -n +11 \
    | while IFS= read -r old_run; do rm -rf "$old_run"; done
  printf '%s\n' "$directory"
}

SUITE=""
REPEAT=1
LIST=0
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
    --suite) if (( $# < 2 )); then usage; exit 2; fi; SUITE="$2"; shift ;;
    --suite=*) SUITE="${1#--suite=}" ;;
    --repeat) if (( $# < 2 )); then usage; exit 2; fi; REPEAT="$2"; shift ;;
    --repeat=*) REPEAT="${1#--repeat=}" ;;
    --list) LIST=1 ;;
    --evaluate) EVALUATE=1 ;;
    --keep-going) KEEP_GOING=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [[ ! "$REPEAT" =~ ^[1-9][0-9]*$ ]] || (( REPEAT > 100 )); then
  echo "--repeat must be an integer from 1 to 100" >&2; exit 2
fi
SUITE_EXECUTOR=""
if [[ -n "$SUITE" ]]; then
  SUITE_EXECUTOR="$(python3 - "$SUITE" <<'MANIFEST'
import json, sys
from pathlib import Path
matches = [value for value in json.loads(Path('Tests/JarvisLiveTests/Scenarios/evaluation-suites.json').read_text())['suites'] if value['id'] == sys.argv[1]]
if len(matches) != 1:
    print('Unknown suite: ' + sys.argv[1], file=sys.stderr)
    sys.exit(2)
print(matches[0]['executor'])
MANIFEST
)" || exit 2
fi
if [[ "$LIST" == 1 ]]; then
  python3 - <<'CATALOG'
import json
from pathlib import Path
base = Path('Tests/JarvisLiveTests/Scenarios')
for suite in json.loads((base / 'evaluation-suites.json').read_text())['suites']:
    print(suite['id'] + ' (' + suite['acceptance'] + ')')
    if 'catalog' in suite:
        for episode in json.loads((base / suite['catalog']).read_text())['episodes']:
            print('  ' + episode['id'] + ' (' + str(sum(1 + len(decision.get('automaticFollowups', [])) for decision in episode['decisions'])) + ' decisions)')
    else:
        print('  ' + suite['scenario'] + ' (signed app)')
CATALOG
  exit 0
fi
if [[ -n "$SUITE" ]]; then
  if [[ "$SCENARIO" != all || "$EVALUATE" == 1 ]]; then
    echo "--suite cannot be combined with a positional scenario or --evaluate" >&2; exit 2
  fi
  case "$PROVIDER" in codex-subscription|claude-subscription|openai|gemini) ;; *) echo "Suite needs one concrete provider" >&2; exit 2 ;; esac
  isolate_test_display ${RUN_ARGUMENTS[@]+"${RUN_ARGUMENTS[@]}"}
  RUN_DIR="$(create_live_run_directory)"
  export JARVIS_LIVE_E2E_RUN_DIR="$RUN_DIR"
  export JARVIS_LIVE_E2E_PROVIDER="$PROVIDER"
  export JARVIS_EVALUATION_SUITE="$SUITE"
  export JARVIS_EVALUATION_REPEAT="$REPEAT"
  export JARVIS_EVALUATION_SOURCE_REVISION="$(git rev-parse HEAD)"
  export JARVIS_EVALUATION_SOURCE_DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
  if [[ "$SUITE_EXECUTOR" == signedApp ]]; then
    ./scripts/build-app.sh debug
    export JARVIS_LIVE_E2E_APP="$PWD/Jarvis Dev.app"
    source scripts/lib/live-test-cancellation.sh
  fi
  if [[ "$SUITE_EXECUTOR" == coachingReplay && ( "$PROVIDER" == *-subscription || "${JARVIS_EVALUATION_JUDGE_PROVIDER:-codex-subscription}" == *-subscription ) ]]; then
    source scripts/lib/cliproxyapi.sh
    build_cliproxyapi
    export JARVIS_PROXY_EXECUTABLE="$CLIPROXYAPI_BUILT_DIRECTORY/cliproxyapi"
  fi
  source scripts/lib/swift-test-flags.sh
  run_swift_tests "$RUN_DIR/swift-test.log" --filter 'JarvisLiveTests\.EvaluationSuiteTests/'
  echo "Evaluation artifacts: $RUN_DIR"
  exit 0
fi
if [[ "$REPEAT" != 1 ]]; then echo "--repeat requires --suite" >&2; exit 2; fi
if [[ "$SCENARIO" =~ ^REF0[1-7]$ ]]; then
  isolate_test_display ${RUN_ARGUMENTS[@]+"${RUN_ARGUMENTS[@]}"}
  echo "$SCENARIO uses the deterministic signed References harness (synthetic tool traffic; no provider or capture)."
  python3 scripts/test-display/supervisor.py transition-reference "$SCENARIO"
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

isolate_test_display ${RUN_ARGUMENTS[@]+"${RUN_ARGUMENTS[@]}"}
echo "▶ building the signed development app"
./scripts/build-app.sh debug

RUN_DIR="$(create_live_run_directory)"

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
