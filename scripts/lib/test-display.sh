# Hosted CI has no developer desktop. Local runs re-enter under a temporary
# display owner, including the live runner's later caffeinate re-exec.
if [[ "${GITHUB_ACTIONS:-}" != true && -z "${JARVIS_TEST_DISPLAY_ID:-}" ]]; then
  display_source="$PWD/scripts/test-display"
  display_build="$PWD/.build/test-display"
  mkdir -p "$display_build"
  display_fingerprint="$(
    { swiftc --version 2>&1; cat "$display_source"/*.swift "$display_source/DeskPad/CGVirtualDisplayPrivate.h"; } \
      | shasum -a 256 | awk '{print $1}'
  )"
  display_runner="$display_build/test-display-$display_fingerprint"
  if [[ ! -x "$display_runner" ]]; then
    swiftc -swift-version 6 -parse-as-library \
      -import-objc-header "$display_source/DeskPad/CGVirtualDisplayPrivate.h" \
      "$display_source"/*.swift -o "$display_runner.$$"
    mv "$display_runner.$$" "$display_runner"
  fi
  exec "$display_runner" -- /bin/bash "$PWD/scripts/$(basename "$0")" "$@"
fi
