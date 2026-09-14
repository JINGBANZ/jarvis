# Sourced by run-tests.sh and run-live-tests.sh; defines SWIFT_TEST_FLAGS.
#
# On a Command-Line-Tools-only machine, swift-testing ships with the CLT but isn't on the default
# search path, so we point swift at it explicitly. With full Xcode active (e.g. CI runners) it's
# already on the toolchain path, so plain `swift test` works — detect which toolchain is active.
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
