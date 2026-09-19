#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/scripts/lib" "$TMP/bin"
cp "$ROOT/scripts/run-tests.sh" "$TMP/repo/scripts/"
cp "$ROOT/scripts/lib/swift-test-flags.sh" "$TMP/repo/scripts/lib/"
if [[ -f "$ROOT/scripts/lib/test-completion.sh" ]]; then
  cp "$ROOT/scripts/lib/test-completion.sh" "$TMP/repo/scripts/lib/"
fi
# Only the external runner and unrelated preflight checks are replaced.
for check in check-ghost-mode check-coaching-kernel check-audio-capture-config check-app-identities check-release-config; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/repo/scripts/$check.sh"
  chmod +x "$TMP/repo/scripts/$check.sh"
done
mkdir -p "$TMP/repo/scripts/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/repo/scripts/tests/test-test-completion.sh"
cat > "$TMP/bin/swift" <<'SWIFT'
#!/usr/bin/env bash
touch "$SYNTHETIC_SWIFT_CALLED"
cat "$SYNTHETIC_LOG"
if [[ -n "${SYNTHETIC_LIVE_RESULTS:-}" ]]; then
  cp -R "$SYNTHETIC_LIVE_RESULTS/." "$JARVIS_LIVE_E2E_RUN_DIR/"
fi
exit "$SYNTHETIC_STATUS"
SWIFT
chmod +x "$TMP/bin/swift"
export PATH="$TMP/bin:$PATH"
export SYNTHETIC_LOG="$TMP/swift.log" SYNTHETIC_STATUS=0 SYNTHETIC_SWIFT_CALLED="$TMP/swift-called"
passed=0
expect_status() {
  local expected="$1" description="$2" status=0
  shift 2
  "$@" > "$TMP/output" 2>&1 || status=$?
  if [[ "$status" != "$expected" ]]; then
    echo "FAIL: $description (expected $expected, got $status)" >&2
    cat "$TMP/output" >&2
    exit 1
  fi
  passed=$((passed + 1))
}
printf '◇ Test run started.\n◇ Test example() started.\n' > "$SYNTHETIC_LOG"
expect_status 1 'exit zero without final summary fails' bash "$TMP/repo/scripts/run-tests.sh"
printf '✔ Test run with 2 tests passed after 0.001 seconds.\n' > "$SYNTHETIC_LOG"
expect_status 0 'completed successful run passes' bash "$TMP/repo/scripts/run-tests.sh"
printf '✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n' > "$SYNTHETIC_LOG"
expect_status 0 'suite count is accepted' bash "$TMP/repo/scripts/run-tests.sh"
SYNTHETIC_STATUS=7
expect_status 7 'runner failure keeps its exit status' bash "$TMP/repo/scripts/run-tests.sh"
SYNTHETIC_STATUS=0
printf '✔ Test run with 0 tests passed after 0.001 seconds.\n' > "$SYNTHETIC_LOG"
expect_status 1 'zero executed tests fails' bash "$TMP/repo/scripts/run-tests.sh"
printf '✘ Test run with 2 tests failed after 0.001 seconds with 1 issue.\n' > "$SYNTHETIC_LOG"
expect_status 1 'failed summary fails even with exit zero' bash "$TMP/repo/scripts/run-tests.sh"
printf 'Executed 2 tests, with 0 failures in 0.01 seconds\n' > "$SYNTHETIC_LOG"
expect_status 1 'XCTest summary does not substitute for Swift Testing completion' bash "$TMP/repo/scripts/run-tests.sh"
source "$ROOT/scripts/lib/test-completion.sh"
RUN="$TMP/live"
mkdir "$RUN"
expect_status 1 'live run with no scenario evidence fails' check_live_test_completion "$RUN" C
for scenario in A B C R F01-system F01-microphone F02; do
  mkdir "$RUN/$scenario"
  printf '{}\n' > "$RUN/$scenario/scenario.json"
  printf 'G01 pass\n' > "$RUN/$scenario/results.txt"
  touch "$RUN/$scenario/live-e2e-finished"
done
expect_status 0 'all expected live scenarios complete' check_live_test_completion "$RUN" all
expect_status 0 'selected C scenario complete' check_live_test_completion "$RUN" C
expect_status 0 'F01 requires both variants' check_live_test_completion "$RUN" F01
rm "$RUN/C/results.txt"
expect_status 1 'missing selected scenario results fails' check_live_test_completion "$RUN" C
expect_status 1 'all includes C' check_live_test_completion "$RUN" all
printf '\n' > "$RUN/C/results.txt"
expect_status 1 'blank results fail' check_live_test_completion "$RUN" C
printf 'G01 pass\n' > "$RUN/C/results.txt"
rm "$RUN/C/live-e2e-finished"
expect_status 1 'missing selected scenario finish marker fails' check_live_test_completion "$RUN" C
touch "$RUN/C/live-e2e-finished"
printf 'G01 fail incomplete\n' > "$RUN/C/results.txt"
expect_status 1 'failed scenario results fail' check_live_test_completion "$RUN" C
printf 'G01 pass\n' > "$RUN/C/results.txt"
rm -r "$RUN/F01-microphone"
expect_status 1 'missing F01 variant fails' check_live_test_completion "$RUN" F01
expect_status 0 'unselected missing scenario does not fail' check_live_test_completion "$RUN" C
cp "$ROOT/scripts/run-live-tests.sh" "$TMP/repo/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/repo/scripts/build-app.sh"
chmod +x "$TMP/repo/scripts/build-app.sh"
export JARVIS_LIVE_E2E_CAFFEINATED=1
export SYNTHETIC_LIVE_RESULTS="$RUN"
# Replace the external process probe; the synthetic build and Swift runner never launch an app.
run_live() {
  bash -c '/usr/bin/pgrep() { [[ "${SYNTHETIC_APP_PROCESS:-}" =~ $2 ]]; }; source "$0"' "$TMP/repo/scripts/run-live-tests.sh" "$@"
}
printf '✔ Test run with 1 test passed after 0.001 seconds.\n' > "$SYNTHETIC_LOG"
expect_status 0 'live wrapper accepts completed C' run_live C
expect_status 1 'live wrapper all requires absent F01 variant' run_live all
printf '◇ Test run started.\n' > "$SYNTHETIC_LOG"
expect_status 1 'live wrapper rejects exit zero without summary' run_live C
printf '✔ Test run with 1 test passed after 0.001 seconds.\n' > "$SYNTHETIC_LOG"
SYNTHETIC_STATUS=7
expect_status 1 'live wrapper rejects runner failure despite completion evidence' run_live C
SYNTHETIC_STATUS=0
rm "$RUN/C/live-e2e-finished"
expect_status 1 'live wrapper rejects missing finish marker' run_live C
touch "$RUN/C/live-e2e-finished"
rm "$RUN/C/results.txt"
expect_status 1 'live wrapper rejects missing results' run_live C
mkdir "$TMP/empty-live"
SYNTHETIC_LIVE_RESULTS="$TMP/empty-live"
expect_status 1 'live wrapper rejects empty run' run_live C
printf 'G01 pass\n' > "$RUN/C/results.txt"
SYNTHETIC_LIVE_RESULTS="$RUN"
export SYNTHETIC_APP_PROCESS='/workspace/Jarvis Dev.app/Contents/MacOS/JarvisApp'
rm -f "$SYNTHETIC_SWIFT_CALLED"
expect_status 1 'live wrapper rejects a running development app' run_live C
if [[ -e "$SYNTHETIC_SWIFT_CALLED" ]]; then
  echo 'FAIL: live runner started tests while a dev app was running' >&2
  exit 1
fi
SYNTHETIC_APP_PROCESS=''
echo "Test completion regression checks passed ($passed cases)."
