abort_run() {
  trap - HUP INT TERM
  # The running scenario's app polls for this marker and stops its session so the evidence seals.
  for scenario_dir in "$RUN_DIR"/*/; do
    if [[ -f "$scenario_dir/scenario.json" && ! -f "$scenario_dir/live-e2e-finished" ]]; then
      touch "$scenario_dir/abort"
    fi
  done
  # LaunchServices started the app outside this process group, so the signal never reached it.
  # Give it the launcher's 10s to seal its session, then kill it so capture cannot outlive the run.
  for _ in {1..50}; do
    /usr/bin/pgrep -f "$APP_PROCESS_PATTERN" >/dev/null || break
    sleep 0.2
  done
  /usr/bin/pkill -f "$APP_PROCESS_PATTERN" || true
  echo "Live e2e run aborted; partial results are in $RUN_DIR." >&2
  exit 130
}
trap abort_run HUP INT TERM
