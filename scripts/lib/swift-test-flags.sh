# Sourced by run-tests.sh and run-live-tests.sh; defines SWIFT_TEST_FLAGS.
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
fi
