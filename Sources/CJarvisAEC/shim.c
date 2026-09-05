// Deliberately empty translation unit.
//
// This target exists to publish jarvis_aec.h and link the prebuilt libjarvis-aec.a; the AEC3 facade
// itself is compiled from scripts/aec/jarvis_aec.cpp straight into that archive by
// scripts/build-aec.sh, so there is nothing left for SwiftPM to build here. The file stays because a
// C target needs at least one source, and it is where any future dependency-free C facade would go.
//
// It previously carried forwarding functions for WebRTC's classic voice activity detector. Local
// turn detection now runs on Silero (see SileroVoiceActivityDetector), so those were removed.
#include "jarvis_aec.h"
