// SwiftPM requires a compilable source in a C target. The actual echo-canceller
// implementation is compiled from scripts/aec/jarvis_aec.cpp (which needs the
// webrtc/abseil headers) and merged into libjarvis-aec.a by scripts/build-aec.sh;
// the linker resolves the jarvis_aec_* symbols from that archive. This file just
// anchors the module and the public header — it deliberately defines nothing.
#include "jarvis_aec.h"
