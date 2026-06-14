#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# swift-testing ships with the Command Line Tools but is not on the default search path.
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
IOP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$IOP" \
  "$@"
