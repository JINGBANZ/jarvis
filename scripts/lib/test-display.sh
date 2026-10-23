# Admission is a supervisor-validated process transition, never an environment flag.
isolate_test_display() {
  if [[ -n "${JARVIS_TEST_RUN_SOCKET:-}" || -n "${JARVIS_TEST_RUN_TOKEN:-}" ]]; then
    if [[ "$(basename "$0")" == build-app.sh ]]; then
      python3 scripts/test-display/supervisor.py build-guard "$@"
    else
      python3 scripts/test-display/supervisor.py admit
    fi
  else
    exec python3 scripts/test-display/supervisor.py run "$(basename "$0")" "$@"
  fi
}

launch_test_app() {
  python3 scripts/test-display/supervisor.py launch-app "$@"
}

wait_test_app() {
  python3 scripts/test-display/supervisor.py wait-app
}

stop_test_app() {
  python3 scripts/test-display/supervisor.py stop-app
}
