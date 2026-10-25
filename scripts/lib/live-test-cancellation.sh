abort_run() {
  trap - HUP INT TERM
  # The running scenario's app polls for this marker and stops its session so the evidence seals.
  for scenario_dir in "$RUN_DIR"/*/; do
    if [[ -f "$scenario_dir/scenario.json" && ! -f "$scenario_dir/live-e2e-finished" ]]; then
      touch "$scenario_dir/abort"
    fi
  done
  # Leave the supervisor free to serve helper receipts while the app drains its evidence.
  sleep 10
  stop_test_app
  echo "Live e2e run aborted; partial results are in $RUN_DIR." >&2
  exit 130
}
trap abort_run HUP INT TERM
