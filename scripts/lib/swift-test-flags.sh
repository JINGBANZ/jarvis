#!/usr/bin/env bash
# Sourced by run-tests.sh and run-live-tests.sh.
#
# The CLT ships swift-testing off the default search path; full Xcode (CI) already finds it.
# Expand with ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"} so an empty array survives `set -u`.
SWIFT_TEST_FLAGS=()
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  IOP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  SWIFT_TEST_FLAGS=(
    -Xswiftc -F -Xswiftc "$FW"
    -Xlinker -F -Xlinker "$FW"
    -Xlinker -rpath -Xlinker "$FW"
    -Xlinker -rpath -Xlinker "$IOP"
  )
  # Swift 6.4's Swift Build backend no longer finds the CLT's swift-testing macro plugin on its own.
  PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  if [ -d "$PLUGINS" ]; then
    SWIFT_TEST_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
  fi
fi

run_swift_tests() {
  local log="$1"
  shift
  if swift test ${SWIFT_TEST_FLAGS[@]+"${SWIFT_TEST_FLAGS[@]}"} "$@" 2>&1 | tee "$log"; then
    # A stopped main run loop can exit 0 before the summary; an empty filter also exits 0.
    if ! /usr/bin/grep -Eq 'Test run with [1-9][0-9]* tests?.*passed after' "$log"; then
      echo "swift test did not report a completed, nonempty passing test run: $log" >&2
      return 1
    fi
  else
    return "$?"
  fi
}
