# Sourced by the offline and live test runners.
check_swift_test_completion() {
  local log="$1" status="$2"
  if (( status != 0 )); then
    echo "Swift test failed with exit $status." >&2
    return "$status"
  fi
  # SwiftPM can exit zero when a test exits the process before Swift Testing finishes.
  if ! grep -Eq 'Test run with [1-9][0-9]* tests?( in [1-9][0-9]* suites?)? passed after ' "$log"; then
    echo "Swift Testing did not report a completed, nonempty successful run." >&2
    return 1
  fi
}

check_live_test_completion() {
  local run_dir="$1" selection="$2" scenario_dir missing_markers=0 scenario
  local expected=()
  case "$selection" in
    all) expected=(A B C D R F01-system F01-microphone F02) ;;
    F01) expected=(F01-system F01-microphone) ;;
    A|B|C|D|R|F02) expected=("$selection") ;;
    *) echo "Unknown live scenario: $selection" >&2; return 1 ;;
  esac
  for scenario in "${expected[@]}"; do
    scenario_dir="$run_dir/$scenario"
    if [[ ! -f "$scenario_dir/live-e2e-finished" ]]; then
      echo "missing live-e2e-finished: $scenario_dir" >&2
      return 1
    fi
    if [[ ! -f "$scenario_dir/results.txt" ]] \
        || ! awk '$2 == "pass" || $2 == "fail" || $2 == "skipped" { found = 1 } END { exit !found }' "$scenario_dir/results.txt"; then
      echo "missing or empty scenario results: $scenario_dir" >&2
      return 1
    fi
    if awk '$2 == "fail" { found = 1 } END { exit !found }' "$scenario_dir/results.txt"; then
      echo "failed scenario results: $scenario_dir" >&2
      return 1
    fi
  done
  for scenario_dir in "$run_dir"/*/; do
    if [[ -f "$scenario_dir/scenario.json" && ! -f "$scenario_dir/live-e2e-finished" ]]; then
      echo "missing live-e2e-finished: $scenario_dir" >&2
      missing_markers=$((missing_markers + 1))
    fi
  done
  (( missing_markers == 0 ))
}
